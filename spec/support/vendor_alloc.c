/* Exercise ownership when decoding supported type names runs out of memory. */
#define CHC_IMPLEMENTATION
#include "clickhouse.h"
#include <stdio.h>
#include <stdlib.h>

typedef union {
    max_align_t alignment;
    size_t size;
} allocation_header;

typedef struct {
    size_t calls, fail_at, live, bytes;
} allocation_state;

static void *test_alloc(void *ud, size_t size)
{
    allocation_state *s = ud;
    if (s->calls++ == s->fail_at) return NULL;
    allocation_header *h = malloc(sizeof *h + size);
    if (!h) abort();
    h->size = size;
    s->live++;
    s->bytes += size;
    return h + 1;
}

static void *test_realloc(void *ud, void *ptr, size_t old_size, size_t size)
{
    if (!ptr) return test_alloc(ud, size);
    allocation_state *s = ud;
    allocation_header *h = (allocation_header *)ptr - 1;
    if (h->size != old_size) abort();
    if (s->calls++ == s->fail_at) return NULL;
    h = realloc(h, sizeof *h + size);
    if (!h) abort();
    h->size = size;
    s->bytes = s->bytes - old_size + size;
    return h + 1;
}

static void test_free(void *ud, void *ptr, size_t size)
{
    if (!ptr) return;
    allocation_state *s = ud;
    allocation_header *h = (allocation_header *)ptr - 1;
    if (h->size != size) abort();
    s->live--;
    s->bytes -= size;
    free(h);
}

int main(void)
{
    const char *types[] = {
        "Tuple(a Int32, b String)",
        "Tuple(`quoted field` Int32, String)",
        "Array(Tuple(a Int32, b Array(String)))",
        "Enum16('a' = 1, 'b' = 2)"
    };
    for (size_t i = 0; i < sizeof types / sizeof *types; i++) {
        for (size_t fail_at = 0; ; fail_at++) {
            allocation_state s = { .fail_at = fail_at };
            chc_alloc al = { &s, test_alloc, test_realloc, test_free };
            chc_type *type = NULL;
            chc_err err = {0};
            int rc = chc_type_parse(types[i], strlen(types[i]), &al, &type, &err);
            if (rc == CHC_OK) chc_type_destroy(type, &al);
            if ((rc != CHC_OK && (rc != CHC_ERR_OOM || type != NULL)) || s.live || s.bytes) {
                fprintf(stderr, "%s: fail_at=%zu rc=%d live=%zu bytes=%zu\n",
                        types[i], fail_at, rc, s.live, s.bytes);
                return 1;
            }
            if (fail_at >= s.calls) break;
        }
    }
    return 0;
}
