/*
 * ChConnect::NativeClient — ioless ClickHouse native-protocol state machine
 * backed by the vendored clickhouse-c header-only library.
 *
 * This extension performs NO I/O: Ruby owns the socket (and TLS) and pumps
 * bytes through the state machine:
 *   take_output -> bytes to write to the socket
 *   feed(bytes) -> submit bytes read from the socket
 *   handshake_step / recv_step -> :done | :want_read
 * All calls are short and non-blocking, so the GVL is never released and
 * interrupts can only fire between calls. Result blocks are decoded in C
 * into Ruby objects used by ChConnect::Response.
 */

#include <ruby.h>
#include <ruby/encoding.h>
#include <ruby/intern.h>

#include <limits.h>
#include <string.h>
#include <time.h>

/* CHC_NO_LZ4 / CHC_NO_ZSTD / CHC_EXT_HAVE_* are set by extconf.rb based on
 * which libraries are available at build time. */
#define CHC_IMPLEMENTATION
#define CHC_PROVIDE_STDLIB_ALLOC
#include "clickhouse.h"
#include "clickhouse-compression.h"
#include "clickhouse-client.h"
#include "clickhouse-async.h"

static VALUE cNativeClient;
static VALUE eQueryError;
static VALUE eConnectionError;
static VALUE eUnsupportedTypeError;
static VALUE cIPAddr;
static VALUE cDate;
static VALUE vAF_INET;
static VALUE vAF_INET6;

static ID id_jd;
static ID id_new;
static ID id_pow;
static ID id_div;
static ID id_BigDecimal;

static VALUE sym_read_rows;
static VALUE sym_read_bytes;
static VALUE sym_written_rows;
static VALUE sym_written_bytes;
static VALUE sym_total_rows_to_read;
static VALUE sym_result_rows;
static VALUE sym_result_bytes;
static VALUE sym_done;
static VALUE sym_want_read;

/* Julian day number of 1970-01-01 (Date.jd(2440588) == Date.new(1970, 1, 1)) */
#define UNIX_EPOCH_JD 2440588

/* One immutable codec shared by all connections and threads: the built-in
 * adapters are stateless wrappers over the one-shot lz4/zstd functions. Both
 * slot pairs are filled (when available) so decode survives a server-side
 * `SET network_compression_method` different from ours. */
static chc_codec g_codec;

typedef enum {
    NATIVE_READY = 0,
    NATIVE_ACTIVE,
    NATIVE_BROKEN,
} native_state;

/* --- column decoding ---------------------------------------------------- */

static VALUE decode_column(const chc_column *col, const chc_type *t, long n_rows, native_state *state);

NORETURN(static void raise_unsupported_type(const chc_type *t, native_state *state));

static void
raise_unsupported_type(const chc_type *t, native_state *state)
{
    size_t len = 0;
    const char *name = chc_type_name(t, &len);
    *state = NATIVE_BROKEN;
    rb_raise(eUnsupportedTypeError, "Unsupported column type: %.*s", (int)len, name);
}

/* Native-format fixed-width values are always little-endian. Decode them
 * explicitly instead of relying on the host's byte order. */
static inline uint16_t
load_u16le(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static inline uint32_t
load_u32le(const uint8_t *p)
{
    return (uint32_t)p[0]
        | ((uint32_t)p[1] << 8)
        | ((uint32_t)p[2] << 16)
        | ((uint32_t)p[3] << 24);
}

static inline uint64_t
load_u64le(const uint8_t *p)
{
    return (uint64_t)load_u32le(p) | ((uint64_t)load_u32le(p + 4) << 32);
}

static inline int16_t
load_i16le(const uint8_t *p)
{
    uint16_t u = load_u16le(p);
    int16_t v;
    memcpy(&v, &u, sizeof v);
    return v;
}

static inline int32_t
load_i32le(const uint8_t *p)
{
    uint32_t u = load_u32le(p);
    int32_t v;
    memcpy(&v, &u, sizeof v);
    return v;
}

static inline int64_t
load_i64le(const uint8_t *p)
{
    uint64_t u = load_u64le(p);
    int64_t v;
    memcpy(&v, &u, sizeof v);
    return v;
}

static inline float
load_f32le(const uint8_t *p)
{
    uint32_t bits = load_u32le(p);
    float v;
    memcpy(&v, &bits, sizeof v);
    return v;
}

static inline double
load_f64le(const uint8_t *p)
{
    uint64_t bits = load_u64le(p);
    double v;
    memcpy(&v, &bits, sizeof v);
    return v;
}

/* FIXED-layout leaf decoding, dispatched on logical kind */
static VALUE
decode_fixed(const chc_column *col, const chc_type *t, long n_rows, native_state *state)
{
    size_t es = 0;
    const uint8_t *data = n_rows > 0
        ? (const uint8_t *)chc_column_fixed_data(col, &es)
        : NULL;
    VALUE ary = rb_ary_new_capa(n_rows);
    chc_kind kind = chc_type_kind(t);

    switch (kind) {
    case CHC_UINT8: {
        for (long i = 0; i < n_rows; i++) rb_ary_push(ary, INT2FIX(data[i]));
        break;
    }
    case CHC_BOOL: {
        for (long i = 0; i < n_rows; i++) rb_ary_push(ary, data[i] == 1 ? Qtrue : Qfalse);
        break;
    }
    case CHC_INT8:
    case CHC_ENUM8: {
        for (long i = 0; i < n_rows; i++) rb_ary_push(ary, INT2FIX((int8_t)data[i]));
        break;
    }
    case CHC_UINT16: {
        for (long i = 0; i < n_rows; i++) {
            uint16_t v = load_u16le(data + i * 2);
            rb_ary_push(ary, INT2FIX(v));
        }
        break;
    }
    case CHC_INT16:
    case CHC_ENUM16: {
        for (long i = 0; i < n_rows; i++) {
            int16_t v = load_i16le(data + i * 2);
            rb_ary_push(ary, INT2FIX(v));
        }
        break;
    }
    case CHC_UINT32: {
        for (long i = 0; i < n_rows; i++) {
            uint32_t v = load_u32le(data + i * 4);
            rb_ary_push(ary, UINT2NUM(v));
        }
        break;
    }
    case CHC_INT32: {
        for (long i = 0; i < n_rows; i++) {
            int32_t v = load_i32le(data + i * 4);
            rb_ary_push(ary, INT2NUM(v));
        }
        break;
    }
    case CHC_UINT64: {
        for (long i = 0; i < n_rows; i++) rb_ary_push(ary, ULL2NUM(load_u64le(data + i * 8)));
        break;
    }
    case CHC_INT64:
    {
        for (long i = 0; i < n_rows; i++) {
            int64_t v = load_i64le(data + i * 8);
            rb_ary_push(ary, LL2NUM(v));
        }
        break;
    }
    case CHC_UINT128:
    case CHC_UINT256: {
        size_t nbytes = (kind == CHC_UINT128) ? 16 : 32;
        for (long i = 0; i < n_rows; i++) {
            rb_ary_push(ary, rb_integer_unpack(data + i * nbytes, nbytes, 1, 0,
                                               INTEGER_PACK_LITTLE_ENDIAN));
        }
        break;
    }
    case CHC_INT128:
    case CHC_INT256: {
        size_t nbytes = (kind == CHC_INT128) ? 16 : 32;
        for (long i = 0; i < n_rows; i++) {
            rb_ary_push(ary, rb_integer_unpack(data + i * nbytes, nbytes, 1, 0,
                                               INTEGER_PACK_LITTLE_ENDIAN |
                                               INTEGER_PACK_2COMP));
        }
        break;
    }
    case CHC_FLOAT32: {
        for (long i = 0; i < n_rows; i++) {
            float v = load_f32le(data + i * 4);
            rb_ary_push(ary, DBL2NUM((double)v));
        }
        break;
    }
    case CHC_FLOAT64: {
        for (long i = 0; i < n_rows; i++) {
            double v = load_f64le(data + i * 8);
            rb_ary_push(ary, DBL2NUM(v));
        }
        break;
    }
    case CHC_FIXED_STRING: {
        for (long i = 0; i < n_rows; i++) {
            rb_ary_push(ary, rb_utf8_str_new((const char *)data + i * es, (long)es));
        }
        break;
    }
    case CHC_DATE: {
        for (long i = 0; i < n_rows; i++) {
            uint16_t days = load_u16le(data + i * 2);
            rb_ary_push(ary, rb_funcall(cDate, id_jd, 1, LONG2NUM(UNIX_EPOCH_JD + (long)days)));
        }
        break;
    }
    case CHC_DATE32: {
        for (long i = 0; i < n_rows; i++) {
            int32_t days = load_i32le(data + i * 4);
            rb_ary_push(ary, rb_funcall(cDate, id_jd, 1, LONG2NUM(UNIX_EPOCH_JD + (long)days)));
        }
        break;
    }
    case CHC_DATETIME: {
        for (long i = 0; i < n_rows; i++) {
            uint32_t ts = load_u32le(data + i * 4);
            struct timespec tsp = { .tv_sec = (time_t)ts, .tv_nsec = 0 };
            rb_ary_push(ary, rb_time_timespec_new(&tsp, INT_MAX - 1)); /* UTC */
        }
        break;
    }
    case CHC_DATETIME64: {
        int scale = chc_type_datetime64_scale(t);
        int64_t mult = 1;
        for (int s = 0; s < 9 - scale; s++) mult *= 10;
        for (long i = 0; i < n_rows; i++) {
            int64_t ticks = load_i64le(data + i * 8);
            __int128 tns = (__int128)ticks * mult;
            int64_t sec = (int64_t)(tns / 1000000000);
            int64_t nsec = (int64_t)(tns % 1000000000);
            if (nsec < 0) { nsec += 1000000000; sec -= 1; }
            struct timespec tsp = { .tv_sec = (time_t)sec, .tv_nsec = (long)nsec };
            rb_ary_push(ary, rb_time_timespec_new(&tsp, INT_MAX - 1)); /* UTC */
        }
        break;
    }
    case CHC_UUID: {
        char buf[37];
        for (long i = 0; i < n_rows; i++) {
            const uint8_t *p = data + i * 16;
            uint64_t hi = load_u64le(p);
            uint64_t lo = load_u64le(p + 8);
            snprintf(buf, sizeof(buf), "%08llx-%04llx-%04llx-%04llx-%012llx",
                     (unsigned long long)(hi >> 32),
                     (unsigned long long)((hi >> 16) & 0xFFFF),
                     (unsigned long long)(hi & 0xFFFF),
                     (unsigned long long)(lo >> 48),
                     (unsigned long long)(lo & 0xFFFFFFFFFFFFULL));
            rb_ary_push(ary, rb_utf8_str_new(buf, 36));
        }
        break;
    }
    case CHC_IPV4: {
        for (long i = 0; i < n_rows; i++) {
            uint32_t v = load_u32le(data + i * 4);
            rb_ary_push(ary, rb_funcall(cIPAddr, id_new, 2, UINT2NUM(v), vAF_INET));
        }
        break;
    }
    case CHC_IPV6: {
        for (long i = 0; i < n_rows; i++) {
            const uint8_t *p = data + i * 16;
            VALUE value = rb_integer_unpack(p, 16, 1, 0, INTEGER_PACK_BIG_ENDIAN);
            rb_ary_push(ary, rb_funcall(cIPAddr, id_new, 2, value, vAF_INET6));
        }
        break;
    }
    case CHC_DECIMAL32:
    case CHC_DECIMAL64:
    case CHC_DECIMAL128:
    case CHC_DECIMAL256: {
        int scale = chc_type_decimal_scale(t);
        VALUE divisor = rb_funcall(INT2FIX(10), id_pow, 1, INT2FIX(scale));
        for (long i = 0; i < n_rows; i++) {
            VALUE unscaled;
            if (kind == CHC_DECIMAL32) {
                int32_t v = load_i32le(data + i * 4);
                unscaled = INT2NUM(v);
            } else if (kind == CHC_DECIMAL64) {
                int64_t v = load_i64le(data + i * 8);
                unscaled = LL2NUM(v);
            } else {
                size_t nbytes = (kind == CHC_DECIMAL128) ? 16 : 32;
                unscaled = rb_integer_unpack(data + i * nbytes, nbytes, 1, 0,
                                             INTEGER_PACK_LITTLE_ENDIAN |
                                             INTEGER_PACK_2COMP);
            }
            VALUE bd = rb_funcall(rb_mKernel, id_BigDecimal, 1, unscaled);
            rb_ary_push(ary, rb_funcall(bd, id_div, 1, divisor));
        }
        break;
    }
    default:
        raise_unsupported_type(t, state);
    }

    return ary;
}

static VALUE
decode_string_column(const chc_column *col, long n_rows)
{
    const uint8_t *data = chc_column_string_data(col);
    const uint64_t *offsets = chc_column_string_offsets(col);
    VALUE ary = rb_ary_new_capa(n_rows);

    uint64_t start = 0;
    for (long i = 0; i < n_rows; i++) {
        uint64_t end = offsets[i];
        rb_ary_push(ary, rb_utf8_str_new((const char *)data + start, (long)(end - start)));
        start = end;
    }
    return ary;
}

static VALUE
decode_column(const chc_column *col, const chc_type *t, long n_rows, native_state *state)
{
    if (n_rows == 0) {
        chc_kind kind = chc_type_kind(t);
        if (kind == CHC_STRING) return rb_ary_new();
        if (kind == CHC_NULLABLE || kind == CHC_ARRAY ||
            kind == CHC_TUPLE || kind == CHC_MAP ||
            kind == CHC_LOW_CARDINALITY) {
            for (size_t i = 0; i < chc_type_n_children(t); i++)
                decode_column(NULL, chc_type_child(t, i), 0, state);
            return rb_ary_new();
        }
        return decode_fixed(NULL, t, 0, state);
    }

    switch (chc_column_layout(col)) {
    case CHC_COL_FIXED:
        return decode_fixed(col, t, n_rows, state);

    case CHC_COL_STRING:
        return decode_string_column(col, n_rows);

    case CHC_COL_NULLABLE: {
        const uint8_t *null_map = chc_column_null_map(col);
        const chc_column *inner = chc_column_nullable_inner(col);
        const chc_type *inner_t = chc_type_child(t, 0);
        VALUE vals = decode_column(inner, inner_t, n_rows, state);
        for (long i = 0; i < n_rows; i++) {
            if (null_map[i] == 1) rb_ary_store(vals, i, Qnil);
        }
        return vals;
    }

    case CHC_COL_ARRAY: {
        const uint64_t *offsets = chc_column_array_offsets(col);
        const chc_column *values_col = chc_column_array_values(col);

        if (chc_type_kind(t) == CHC_MAP) {
            /* Map is an Array of Tuple(K, V) on the wire */
            const chc_type *kt = chc_type_child(t, 0);
            const chc_type *vt = chc_type_child(t, 1);
            long total = (long)chc_column_n_rows(values_col);
            const chc_column *keys_col = chc_column_tuple_child(values_col, 0);
            const chc_column *vals_col = chc_column_tuple_child(values_col, 1);
            VALUE keys = decode_column(keys_col, kt, total, state);
            VALUE vals = decode_column(vals_col, vt, total, state);

            VALUE ary = rb_ary_new_capa(n_rows);
            uint64_t start = 0;
            for (long i = 0; i < n_rows; i++) {
                uint64_t end = offsets[i];
                if (end > (uint64_t)RARRAY_LEN(keys) || end > (uint64_t)RARRAY_LEN(vals)) {
                    *state = NATIVE_BROKEN;
                    rb_raise(eConnectionError,
                             "Map offset out of bounds at row %ld: %llu", i,
                             (unsigned long long)end);
                }
                VALUE hash = rb_hash_new();
                for (uint64_t j = start; j < end; j++) {
                    rb_hash_aset(hash, RARRAY_AREF(keys, (long)j), RARRAY_AREF(vals, (long)j));
                }
                rb_ary_push(ary, hash);
                start = end;
            }
            return ary;
        }

        const chc_type *elem_t = chc_type_child(t, 0);
        long total = (long)chc_column_n_rows(values_col);
        VALUE elements = decode_column(values_col, elem_t, total, state);

        VALUE ary = rb_ary_new_capa(n_rows);
        uint64_t start = 0;
        for (long i = 0; i < n_rows; i++) {
            uint64_t end = offsets[i];
            rb_ary_push(ary, rb_ary_subseq(elements, (long)start, (long)(end - start)));
            start = end;
        }
        return ary;
    }

    case CHC_COL_TUPLE: {
        size_t arity = chc_column_tuple_arity(col);
        VALUE children = rb_ary_new_capa((long)arity);
        for (size_t k = 0; k < arity; k++) {
            rb_ary_push(children, decode_column(chc_column_tuple_child(col, k),
                                                chc_type_child(t, k), n_rows, state));
        }
        VALUE ary = rb_ary_new_capa(n_rows);
        for (long i = 0; i < n_rows; i++) {
            VALUE row = rb_ary_new_capa((long)arity);
            for (size_t k = 0; k < arity; k++) {
                rb_ary_push(row, RARRAY_AREF(RARRAY_AREF(children, (long)k), i));
            }
            rb_ary_push(ary, row);
        }
        return ary;
    }

    case CHC_COL_LOW_CARDINALITY: {
        const chc_column *dict = chc_column_lc_dict(col);
        const chc_type *inner_t = chc_type_child(t, 0);
        long dict_size = (long)chc_column_n_rows(dict);
        VALUE dict_vals = decode_column(dict, inner_t, dict_size, state);

        int key_size = chc_column_lc_key_size(col);
        const void *keys = chc_column_lc_keys(col);
        VALUE ary = rb_ary_new_capa(n_rows);
        for (long i = 0; i < n_rows; i++) {
            uint64_t idx;
            switch (key_size) {
            case 1: idx = ((const uint8_t *)keys)[i]; break;
            case 2: idx = ((const uint16_t *)keys)[i]; break;
            case 4: idx = ((const uint32_t *)keys)[i]; break;
            default: idx = ((const uint64_t *)keys)[i]; break;
            }
            rb_ary_push(ary, RARRAY_AREF(dict_vals, (long)idx));
        }
        return ary;
    }

    default:
        raise_unsupported_type(t, state);
    }
}

/* --- ioless client ------------------------------------------------------ */

typedef struct {
    chc_async_client *ac;
    chc_alloc alloc;
    /* ACTIVE at checkout means the pump was abandoned mid-stream (for
     * example by Thread#kill), so the slot discards the connection. */
    native_state state;
    int have_header;
    /* parked across calls so a raise mid-decode can't leak the block */
    chc_packet pending_pkt;
    uint64_t read_rows, read_bytes, total_rows, written_rows, written_bytes;
    uint64_t result_bytes;
} native_client_t;

static void
clear_pending(native_client_t *nc)
{
    if (nc->ac) chc_async_packet_clear(nc->ac, &nc->pending_pkt);
    memset(&nc->pending_pkt, 0, sizeof(nc->pending_pkt));
}

static void
native_client_dfree(void *ptr)
{
    native_client_t *nc = (native_client_t *)ptr;
    clear_pending(nc);
    if (nc->ac) chc_async_client_free(nc->ac);
    xfree(nc);
}

static const rb_data_type_t native_client_type = {
    .wrap_struct_name = "ChConnect::NativeClient",
    .function = { .dfree = native_client_dfree },
    .flags = RUBY_TYPED_FREE_IMMEDIATELY,
};

static native_client_t *
get_client(VALUE self)
{
    native_client_t *nc;
    TypedData_Get_Struct(self, native_client_t, &native_client_type, nc);
    return nc;
}

static VALUE
native_client_alloc(VALUE klass)
{
    native_client_t *nc = ZALLOC(native_client_t);
    return TypedData_Wrap_Struct(klass, &native_client_type, nc);
}

static native_client_t *
get_live_client(VALUE self)
{
    native_client_t *nc = get_client(self);
    if (!nc->ac || nc->state == NATIVE_BROKEN) {
        rb_raise(eConnectionError, "connection is closed or in a broken state");
    }
    return nc;
}

static VALUE
native_client_initialize(VALUE self, VALUE database, VALUE username, VALUE password, VALUE compression)
{
    native_client_t *nc = get_client(self);

    Check_Type(database, T_STRING);
    Check_Type(username, T_STRING);
    Check_Type(password, T_STRING);

    nc->alloc = chc_alloc_stdlib();
    /* init copies the strings and performs no I/O */
    chc_client_opts opts = {
        .client_name = "ch_connect",
        .database = StringValueCStr(database),
        .user = StringValueCStr(username),
        .password = StringValueCStr(password),
        .codec = &g_codec,
        .compression = (chc_compression)NUM2INT(compression),
    };

    chc_err err = {0};
    if (chc_async_client_init(&nc->ac, &opts, &nc->alloc, &err) != CHC_OK) {
        rb_raise(eConnectionError, "%s", err.msg);
    }
    nc->state = NATIVE_ACTIVE;  /* handshake has not completed yet */
    return self;
}

/* Returns buffered protocol bytes to write to the socket, or nil. */
static VALUE
native_client_take_output(VALUE self)
{
    native_client_t *nc = get_live_client(self);

    const uint8_t *buf = NULL;
    size_t len = 0;
    chc_async_pending_out(nc->ac, &buf, &len);
    if (len == 0) return Qnil;

    VALUE out = rb_str_new((const char *)buf, (long)len);
    chc_async_consume_out(nc->ac, len);
    return out;
}

/* Feeds bytes read from the socket into the state machine (copied). */
static VALUE
native_client_feed(VALUE self, VALUE bytes)
{
    native_client_t *nc = get_live_client(self);
    Check_Type(bytes, T_STRING);

    chc_err err = {0};
    if (chc_async_submit(nc->ac, RSTRING_PTR(bytes), (size_t)RSTRING_LEN(bytes), &err) != CHC_OK) {
        nc->state = NATIVE_BROKEN;
        rb_raise(eConnectionError, "%s", err.msg);
    }
    return Qnil;
}

static VALUE
native_client_handshake_step(VALUE self)
{
    native_client_t *nc = get_live_client(self);

    nc->state = NATIVE_ACTIVE;
    chc_err err = {0};
    int rc = chc_async_handshake(nc->ac, &err);
    if (rc == CHC_OK) {
        nc->state = NATIVE_READY;
        return sym_done;
    }
    if (rc == CHC_WOULD_BLOCK) return sym_want_read;

    nc->state = NATIVE_BROKEN;
    if (err.server_code) rb_raise(eQueryError, "%s", err.msg);
    rb_raise(eConnectionError, "%s", err.msg);
}

/* Normalize Ruby pairs while allocation is still safe. The caller builds C
 * pointers only after both settings and parameters have passed through here. */
static void
append_string_pairs(VALUE pairs, long count, VALUE flat)
{
    for (long i = 0; i < count; i++) {
        VALUE pair = RARRAY_AREF(pairs, i);
        Check_Type(pair, T_ARRAY);
        VALUE name = rb_ary_entry(pair, 0);
        VALUE value = rb_ary_entry(pair, 1);
        StringValue(name);
        StringValue(value);
        (void)StringValueCStr(name);  /* reject embedded NUL */
        (void)StringValueCStr(value);
        rb_ary_push(flat, name);
        rb_ary_push(flat, value);
    }
}

static VALUE
native_client_send_query(VALUE self, VALUE sql, VALUE params, VALUE settings)
{
    native_client_t *nc = get_live_client(self);
    if (nc->state != NATIVE_READY)
        rb_raise(eConnectionError, "native connection is not ready for a query");
    Check_Type(sql, T_STRING);

    /* reset per-query state */
    clear_pending(nc);
    nc->state = NATIVE_ACTIVE;
    nc->have_header = 0;
    nc->read_rows = nc->read_bytes = nc->total_rows = 0;
    nc->written_rows = nc->written_bytes = 0;
    nc->result_bytes = 0;
    rb_iv_set(self, "@columns", rb_ary_new());
    rb_iv_set(self, "@types", rb_ary_new());
    rb_iv_set(self, "@rows", rb_ary_new());

    if (!NIL_P(settings)) Check_Type(settings, T_ARRAY);
    long n_settings = NIL_P(settings) ? 0 : RARRAY_LEN(settings);
    if (!NIL_P(params)) Check_Type(params, T_ARRAY);
    long n_params = NIL_P(params) ? 0 : RARRAY_LEN(params);

    /* Coerce and validate every Ruby string before retaining any RSTRING_PTR.
     * String coercion and rb_ary_push can allocate and trigger compacting GC;
     * once this pass finishes, the pointer-building pass performs no Ruby
     * allocation before chc_client_send_query_ex consumes the bytes. */
    VALUE flat = rb_ary_new_capa(2 * (n_settings + n_params));
    append_string_pairs(settings, n_settings, flat);
    append_string_pairs(params, n_params, flat);

    chc_query_setting *csettings = ALLOCA_N(chc_query_setting, n_settings + 1);
    long n_total = 0;
    /* decoder invariant: the wire must carry printable type names */
    csettings[n_total++] = (chc_query_setting){
        .name = "output_format_native_encode_types_in_binary_format", .value = "0"
    };
    for (long i = 0; i < n_settings; i++) {
        VALUE sname = RARRAY_AREF(flat, 2 * i);
        VALUE sval = RARRAY_AREF(flat, 2 * i + 1);
        csettings[n_total++] = (chc_query_setting){
            .name = RSTRING_PTR(sname), .value = RSTRING_PTR(sval)
        };
    }

    chc_query_opts qopts = { .settings = csettings, .n_settings = (size_t)n_total };

    chc_query_param *cparams = NULL;
    if (n_params > 0) {
        cparams = ALLOCA_N(chc_query_param, n_params);
        long base = 2 * n_settings;
        for (long i = 0; i < n_params; i++) {
            VALUE pname = RARRAY_AREF(flat, base + 2 * i);
            VALUE pval = RARRAY_AREF(flat, base + 2 * i + 1);
            cparams[i].name = RSTRING_PTR(pname);
            cparams[i].value = RSTRING_PTR(pval);
        }
        qopts.params = cparams;
        qopts.n_params = (size_t)n_params;
    }

    chc_err err = {0};
    /* the async wrapper has no send_query_ex; call it on the embedded client
     * (same out-sink io) so settings and params are included */
    int rc = chc_client_send_query_ex(&nc->ac->cli, RSTRING_PTR(sql), (size_t)RSTRING_LEN(sql),
                                      &qopts, &err);
    RB_GC_GUARD(flat);
    RB_GC_GUARD(sql);
    if (rc != CHC_OK) {
        nc->state = NATIVE_BROKEN;
        rb_raise(eConnectionError, "%s", err.msg);
    }
    return Qnil;
}

static void
native_client_decode_block(VALUE self, native_client_t *nc, chc_block *block)
{
    size_t n_rows = chc_block_n_rows(block);
    size_t n_cols = chc_block_n_columns(block);

    for (size_t i = 0; i < n_cols; i++) {
        chc_err err = {0};
        if (chc_column_validate(chc_block_column(block, i), &err) != CHC_OK) {
            VALUE msg = rb_sprintf("Invalid native column: %s",
                                   err.msg[0] ? err.msg : "column validation failed");
            clear_pending(nc);
            nc->state = NATIVE_BROKEN;
            rb_exc_raise(rb_exc_new_str(eConnectionError, msg));
        }
    }

    if (!nc->have_header && n_cols > 0) {
        nc->have_header = 1;
        VALUE columns = rb_iv_get(self, "@columns");
        VALUE types = rb_iv_get(self, "@types");
        for (size_t i = 0; i < n_cols; i++) {
            size_t len = 0;
            const char *name = chc_block_column_name(block, i, &len);
            rb_ary_push(columns, rb_str_intern(rb_utf8_str_new(name, (long)len)));

            const chc_type *t = chc_block_column_type(block, i);
            size_t tlen = 0;
            const char *tname = chc_type_name(t, &tlen);
            rb_ary_push(types, rb_str_intern(rb_utf8_str_new(tname, (long)tlen)));

        }
    }

    VALUE rows = rb_iv_get(self, "@rows");
    /* Decode all columns of this block, then append transposed rows. col_vals
     * anchors the decoded arrays for GC; cols makes the transpose O(1). */
    VALUE col_vals = rb_ary_new_capa((long)n_cols);
    VALUE cols_buf;
    VALUE *cols = ALLOCV_N(VALUE, cols_buf, n_cols);
    for (size_t i = 0; i < n_cols; i++) {
        cols[i] = decode_column(chc_block_column(block, i),
                                chc_block_column_type(block, i),
                                (long)n_rows, &nc->state);
        rb_ary_push(col_vals, cols[i]);
    }
    for (size_t r = 0; r < n_rows; r++) {
        VALUE row = rb_ary_new_capa((long)n_cols);
        for (size_t c = 0; c < n_cols; c++) {
            rb_ary_push(row, RARRAY_AREF(cols[c], (long)r));
        }
        rb_ary_push(rows, row);
    }
    ALLOCV_END(cols_buf);
    RB_GC_GUARD(col_vals);
}

/* Drives the receive state machine over already-fed bytes.
 * Returns :want_read when more socket data is needed, :done at end of
 * stream. Raises QueryError / UnsupportedTypeError / ConnectionError. */
static VALUE
native_client_recv_step(VALUE self)
{
    native_client_t *nc = get_live_client(self);

    for (;;) {
        clear_pending(nc);

        chc_err err = {0};
        int rc = chc_async_recv_packet(nc->ac, &nc->pending_pkt, &err);
        if (rc == CHC_WOULD_BLOCK) return sym_want_read;
        if (rc == CHC_ERR_TYPE) {
            nc->state = NATIVE_BROKEN;
            rb_raise(eUnsupportedTypeError, "Unsupported column type: %s", err.msg);
        }
        if (rc != CHC_OK) {
            nc->state = NATIVE_BROKEN;
            rb_raise(eConnectionError, "%s",
                     err.msg[0] ? err.msg : "connection lost while reading response");
        }

        chc_packet pkt = nc->pending_pkt; /* value alias; freed via clear */

        if (pkt.kind == CHC_PKT_EXCEPTION) {
            VALUE msg = rb_utf8_str_new(pkt.exception->display_text,
                                        (long)pkt.exception->display_text_len);
            clear_pending(nc);
            rb_iv_set(self, "@columns", Qnil);
            rb_iv_set(self, "@types", Qnil);
            rb_iv_set(self, "@rows", Qnil);
            /* A complete server exception terminates this query but leaves the
             * native protocol synchronized and ready for the next query. */
            nc->state = NATIVE_READY;
            rb_exc_raise(rb_exc_new_str(eQueryError, msg));
        }

        if (pkt.kind == CHC_PKT_PROGRESS) {
            nc->read_rows += pkt.progress.rows;
            nc->read_bytes += pkt.progress.bytes;
            if (pkt.progress.total_rows > nc->total_rows) nc->total_rows = pkt.progress.total_rows;
            nc->written_rows += pkt.progress.written_rows;
            nc->written_bytes += pkt.progress.written_bytes;
            continue;
        }

        if (pkt.kind == CHC_PKT_PROFILE_INFO) {
            nc->result_bytes = pkt.profile.bytes;
            continue;
        }

        if (pkt.kind == CHC_PKT_DATA) {
            native_client_decode_block(self, nc, pkt.block);
            continue;
        }

        if (pkt.kind == CHC_PKT_END_OF_STREAM) {
            clear_pending(nc);
            nc->state = NATIVE_READY;
            return sym_done;
        }
        /* PONG / TOTALS / EXTREMES / LOG / PROFILE_EVENTS — skip. */
    }
}

static VALUE
native_client_take_result(VALUE self)
{
    native_client_t *nc = get_client(self);

    VALUE rows = rb_iv_get(self, "@rows");
    if (NIL_P(rows))
        rb_raise(eConnectionError, "no completed native result is available");

    VALUE summary = rb_hash_new();
    rb_hash_aset(summary, sym_read_rows, rb_obj_as_string(ULL2NUM(nc->read_rows)));
    rb_hash_aset(summary, sym_read_bytes, rb_obj_as_string(ULL2NUM(nc->read_bytes)));
    rb_hash_aset(summary, sym_written_rows, rb_obj_as_string(ULL2NUM(nc->written_rows)));
    rb_hash_aset(summary, sym_written_bytes, rb_obj_as_string(ULL2NUM(nc->written_bytes)));
    rb_hash_aset(summary, sym_total_rows_to_read, rb_obj_as_string(ULL2NUM(nc->total_rows)));
    rb_hash_aset(summary, sym_result_rows,
                 rb_obj_as_string(ULL2NUM((uint64_t)RARRAY_LEN(rows))));
    rb_hash_aset(summary, sym_result_bytes, rb_obj_as_string(ULL2NUM(nc->result_bytes)));

    VALUE result = rb_ary_new_from_args(4, rb_iv_get(self, "@columns"), rb_iv_get(self, "@types"),
                                        rows, summary);
    /* drop the references so a pooled idle connection doesn't pin the last
     * result set until its next query */
    rb_iv_set(self, "@columns", Qnil);
    rb_iv_set(self, "@types", Qnil);
    rb_iv_set(self, "@rows", Qnil);
    return result;
}

static VALUE
native_client_broken_p(VALUE self)
{
    native_client_t *nc = get_client(self);
    return (!nc->ac || nc->state != NATIVE_READY) ? Qtrue : Qfalse;
}

static VALUE
native_client_close(VALUE self)
{
    native_client_t *nc = get_client(self);
    clear_pending(nc);
    if (nc->ac) {
        chc_async_client_free(nc->ac);
        nc->ac = NULL;
    }
    return Qnil;
}

void
Init_ch_connect_native(void)
{
    rb_require("date");
    rb_require("ipaddr");
    rb_require("bigdecimal");
    rb_require("socket");

    VALUE mChConnect = rb_define_module("ChConnect");
    cNativeClient = rb_define_class_under(mChConnect, "NativeClient", rb_cObject);
    rb_define_alloc_func(cNativeClient, native_client_alloc);
    rb_define_method(cNativeClient, "initialize", native_client_initialize, 4);
    rb_define_method(cNativeClient, "take_output", native_client_take_output, 0);
    rb_define_method(cNativeClient, "feed", native_client_feed, 1);
    rb_define_method(cNativeClient, "handshake_step", native_client_handshake_step, 0);
    rb_define_method(cNativeClient, "send_query", native_client_send_query, 3);
    rb_define_method(cNativeClient, "recv_step", native_client_recv_step, 0);
    rb_define_method(cNativeClient, "take_result", native_client_take_result, 0);
    rb_define_method(cNativeClient, "broken?", native_client_broken_p, 0);
    rb_define_method(cNativeClient, "close", native_client_close, 0);

    eQueryError = rb_path2class("ChConnect::QueryError");
    eConnectionError = rb_path2class("ChConnect::ConnectionError");
    eUnsupportedTypeError = rb_path2class("ChConnect::UnsupportedTypeError");
    cIPAddr = rb_path2class("IPAddr");
    cDate = rb_path2class("Date");
    VALUE cSocket = rb_path2class("Socket");
    vAF_INET = rb_const_get(cSocket, rb_intern("AF_INET"));
    vAF_INET6 = rb_const_get(cSocket, rb_intern("AF_INET6"));

    rb_gc_register_address(&eQueryError);
    rb_gc_register_address(&eConnectionError);
    rb_gc_register_address(&eUnsupportedTypeError);
    rb_gc_register_address(&cIPAddr);
    rb_gc_register_address(&cDate);
    rb_gc_register_address(&vAF_INET);
    rb_gc_register_address(&vAF_INET6);

    id_jd = rb_intern("jd");
    id_new = rb_intern("new");
    id_pow = rb_intern("**");
    id_div = rb_intern("/");
    id_BigDecimal = rb_intern("BigDecimal");

    sym_read_rows = ID2SYM(rb_intern("read_rows"));
    sym_read_bytes = ID2SYM(rb_intern("read_bytes"));
    sym_written_rows = ID2SYM(rb_intern("written_rows"));
    sym_written_bytes = ID2SYM(rb_intern("written_bytes"));
    sym_total_rows_to_read = ID2SYM(rb_intern("total_rows_to_read"));
    sym_result_rows = ID2SYM(rb_intern("result_rows"));
    sym_result_bytes = ID2SYM(rb_intern("result_bytes"));
    sym_done = ID2SYM(rb_intern("done"));
    sym_want_read = ID2SYM(rb_intern("want_read"));

    memset(&g_codec, 0, sizeof(g_codec));
#ifdef CHC_EXT_HAVE_LZ4
    chc_lz4_codec_init(&g_codec);
    rb_define_const(cNativeClient, "LZ4_AVAILABLE", Qtrue);
#else
    rb_define_const(cNativeClient, "LZ4_AVAILABLE", Qfalse);
#endif
#ifdef CHC_EXT_HAVE_ZSTD
    chc_zstd_codec_init(&g_codec);
    rb_define_const(cNativeClient, "ZSTD_AVAILABLE", Qtrue);
#else
    rb_define_const(cNativeClient, "ZSTD_AVAILABLE", Qfalse);
#endif
}
