# frozen_string_literal: true

require "bigdecimal"
require "ipaddr"

module ChConnect
  # Parser for ClickHouse Native binary format.
  # @api private
  class NativeFormatParser
    DATE_EPOCH = Date.new(1970, 1, 1)

    # Creates a new parser.
    #
    # @param body [#read] response body to parse
    def initialize(body)
      @reader = BodyReader.new(body)
      @columns = []
      @types = []
      @rows = []
    end

    # Parses the response body and returns a Response.
    #
    # @return [Response] parsed response with columns, types, and rows
    # @raise [UnsupportedTypeError] if an unsupported data type is encountered
    def parse
      parse_block until @reader.eof?
      Response.new(columns: @columns, types: @types, rows: @rows)
    ensure
      @reader.close
    end

    private

    def parse_block
      num_columns = read_varint
      num_rows = read_varint

      return if num_columns == 0 && num_rows == 0

      columns_data = []

      num_columns.times do
        col_name = read_string
        col_type = read_string

        if @columns.length < num_columns
          @columns << col_name.to_sym
          @types << col_type.to_sym
        end

        columns_data << read_column(col_type, num_rows)
      end

      @rows.concat(columns_data.transpose) if num_rows > 0
    end

    def read_column(type, num_rows)
      case type
      # Integers
      when "UInt8" then read_uint8_column(num_rows)
      when "UInt16" then read_uint16_column(num_rows)
      when "UInt32" then read_uint32_column(num_rows)
      when "UInt64" then read_uint64_column(num_rows)
      when "UInt128" then read_uint128_column(num_rows)
      when "UInt256" then read_uint256_column(num_rows)
      when "Int8" then read_int8_column(num_rows)
      when "Int16" then read_int16_column(num_rows)
      when "Int32" then read_int32_column(num_rows)
      when "Int64" then read_int64_column(num_rows)
      when "Int128" then read_int128_column(num_rows)
      when "Int256" then read_int256_column(num_rows)

      # Floats
      when "Float32" then read_float32_column(num_rows)
      when "Float64" then read_float64_column(num_rows)

      # Boolean
      when "Bool" then read_bool_column(num_rows)

      # Strings
      when "String" then read_string_column(num_rows)
      when /^FixedString\((\d+)\)$/ then read_fixed_string_column($1.to_i, num_rows)

      # Dates and Times
      when "Date" then read_date_column(num_rows)
      when "Date32" then read_date32_column(num_rows)
      when "DateTime", /^DateTime\(.+\)$/ then read_datetime_column(num_rows)
      when /^DateTime64\((\d+)(?:,.*)?\)$/ then read_datetime64_column($1.to_i, num_rows)

      # UUID
      when "UUID" then read_uuid_column(num_rows)

      # IP addresses
      when "IPv4" then read_ipv4_column(num_rows)
      when "IPv6" then read_ipv6_column(num_rows)

      # Decimals - ClickHouse always returns Decimal(precision, scale)
      when /^Decimal\((\d+),\s*(\d+)\)$/ then read_decimal_column($1.to_i, $2.to_i, num_rows)

      # Enums (stored as signed integers)
      when /^Enum8\(.+\)$/ then read_int8_column(num_rows)
      when /^Enum16\(.+\)$/ then read_int16_column(num_rows)

      # Nullable
      when /^Nullable\((.+)\)$/ then read_nullable_column($1, num_rows)

      # LowCardinality
      when /^LowCardinality\((.+)\)$/ then read_low_cardinality_column($1, num_rows)

      # Arrays
      when /^Array\((.+)\)$/ then read_array_column($1, num_rows)

      # Tuples
      when /^Tuple\((.*)\)$/ then read_tuple_column(parse_tuple_types($1), num_rows)

      # Maps
      when /^Map\((.+)\)$/
        types = parse_tuple_types($1)
        read_map_column(types[0], types[1], num_rows)

      else
        raise UnsupportedTypeError, "Unsupported column type: #{type}"
      end
    end

    # --- Bulk Column Readers ---

    def read_uint8_column(num_rows)
      @reader.read(num_rows).bytes
    end

    def read_uint16_column(num_rows)
      @reader.read(num_rows * 2).unpack("v*")
    end

    def read_uint32_column(num_rows)
      @reader.read(num_rows * 4).unpack("V*")
    end

    def read_uint64_column(num_rows)
      @reader.read(num_rows * 8).unpack("Q<*")
    end

    def read_uint128_column(num_rows)
      Array.new(num_rows) { read_le_bytes(16) }
    end

    def read_uint256_column(num_rows)
      Array.new(num_rows) { read_le_bytes(32) }
    end

    def read_int8_column(num_rows)
      @reader.read(num_rows).unpack("c*")
    end

    def read_int16_column(num_rows)
      @reader.read(num_rows * 2).unpack("s<*")
    end

    def read_int32_column(num_rows)
      @reader.read(num_rows * 4).unpack("l<*")
    end

    def read_int64_column(num_rows)
      @reader.read(num_rows * 8).unpack("q<*")
    end

    def read_int128_column(num_rows)
      Array.new(num_rows) { read_signed_le_bytes(16) }
    end

    def read_int256_column(num_rows)
      Array.new(num_rows) { read_signed_le_bytes(32) }
    end

    def read_float32_column(num_rows)
      @reader.read(num_rows * 4).unpack("e*")
    end

    def read_float64_column(num_rows)
      @reader.read(num_rows * 8).unpack("E*")
    end

    def read_bool_column(num_rows)
      @reader.read(num_rows).bytes.map { |b| b == 1 }
    end

    def read_string_column(num_rows)
      Array.new(num_rows) { read_string }
    end

    def read_fixed_string_column(length, num_rows)
      Array.new(num_rows) { @reader.read(length).force_encoding(Encoding::UTF_8) }
    end

    def read_date_column(num_rows)
      @reader.read(num_rows * 2).unpack("v*").map { |days| DATE_EPOCH + days }
    end

    def read_date32_column(num_rows)
      @reader.read(num_rows * 4).unpack("l<*").map { |days| DATE_EPOCH + days }
    end

    def read_datetime_column(num_rows)
      @reader.read(num_rows * 4).unpack("V*").map { |ts| Time.at(ts).utc }
    end

    def read_datetime64_column(precision, num_rows)
      scale = 10**(9 - precision)
      @reader.read(num_rows * 8).unpack("q<*").map do |ticks|
        nsec = ticks * scale
        Time.at(nsec / 1_000_000_000, nsec % 1_000_000_000, :nanosecond).utc
      end
    end

    def read_uuid_column(num_rows)
      Array.new(num_rows) { read_uuid }
    end

    def read_ipv4_column(num_rows)
      Array.new(num_rows) { read_ipv4 }
    end

    def read_ipv6_column(num_rows)
      Array.new(num_rows) { read_ipv6 }
    end

    def read_decimal_column(precision, scale, num_rows)
      divisor = 10**scale
      if precision <= 9
        @reader.read(num_rows * 4).unpack("l<*").map { |v| BigDecimal(v) / divisor }
      elsif precision <= 18
        @reader.read(num_rows * 8).unpack("q<*").map { |v| BigDecimal(v) / divisor }
      elsif precision <= 38
        Array.new(num_rows) { BigDecimal(read_signed_le_bytes(16)) / divisor }
      else
        Array.new(num_rows) { BigDecimal(read_signed_le_bytes(32)) / divisor }
      end
    end

    # --- Single Value Readers ---

    def read_varint
      result = 0
      shift = 0
      loop do
        byte = @reader.getbyte
        return result if byte.nil?
        result |= (byte & 0x7F) << shift
        break if (byte & 0x80) == 0
        shift += 7
      end
      result
    end

    def read_string
      @reader.read(read_varint).force_encoding(Encoding::UTF_8)
    end

    def read_uint64 = @reader.read(8).unpack1("Q<")

    def read_uuid
      first_half = @reader.read(8).bytes.reverse
      second_half = @reader.read(8).bytes.reverse
      hex = (first_half + second_half).pack("C*").unpack1("H*")
      "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end

    def read_ipv4
      bytes = @reader.read(4).unpack("C4").reverse
      IPAddr.new(bytes.join("."))
    end

    def read_ipv6
      bytes = @reader.read(16)
      IPAddr.new(bytes.unpack1("H*").scan(/.{4}/).join(":"), Socket::AF_INET6)
    end

    # --- Container Type Readers ---

    # Nullable: nulls mask (uint8 per row, 1=null), then all values
    def read_nullable_column(inner_type, num_rows)
      nulls = @reader.read(num_rows).bytes
      values = read_column(inner_type, num_rows)
      num_rows.times { |i| values[i] = nil if nulls[i] == 1 }
      values
    end

    # Array: cumulative offsets (uint64 per row), then all elements
    def read_array_column(inner_type, num_rows)
      offsets = read_uint64_column(num_rows)
      total_elements = offsets.last || 0

      return Array.new(num_rows) { [] } if total_elements == 0

      elements = read_column(inner_type, total_elements)

      arrays = Array.new(num_rows)
      prev_offset = 0
      offsets.each_with_index do |offset, i|
        arrays[i] = elements.slice(prev_offset, offset - prev_offset)
        prev_offset = offset
      end
      arrays
    end

    # Map: cumulative offsets (uint64 per row), then all keys, then all values
    def read_map_column(key_type, value_type, num_rows)
      offsets = read_uint64_column(num_rows)
      total_pairs = offsets.last || 0

      return Array.new(num_rows) { {} } if total_pairs == 0

      keys = read_column(key_type, total_pairs)
      values = read_column(value_type, total_pairs)

      maps = Array.new(num_rows)
      prev_offset = 0
      offsets.each_with_index do |offset, i|
        len = offset - prev_offset
        maps[i] = keys.slice(prev_offset, len).zip(values.slice(prev_offset, len)).to_h
        prev_offset = offset
      end
      maps
    end

    # Tuple: all values of element 0, then element 1, etc. (column-major)
    # Empty tuples send 1 byte per row.
    def read_tuple_column(element_types, num_rows)
      if element_types.empty?
        @reader.read(num_rows)
        return Array.new(num_rows) { [] }
      end

      element_columns = element_types.map { |type| read_column(type, num_rows) }

      Array.new(num_rows) { |i| element_columns.map { |col| col[i] } }
    end

    # LowCardinality: version, meta, dictionary, keys
    def read_low_cardinality_column(inner_type, num_rows)
      _version = read_uint64
      meta = read_uint64
      key_type = meta & 0xFF

      dict_size = read_uint64
      dictionary = read_column(inner_type, dict_size)

      _num_keys = read_uint64
      keys = case key_type
      when 0 then read_uint8_column(num_rows)
      when 1 then read_uint16_column(num_rows)
      when 2 then read_uint32_column(num_rows)
      else read_uint64_column(num_rows)
      end

      keys.map { |k| dictionary[k] }
    end

    # --- Helpers ---

    def read_le_bytes(num_bytes)
      bytes = @reader.read(num_bytes).bytes
      result = 0
      bytes.each_with_index { |b, i| result |= b << (8 * i) }
      result
    end

    def read_signed_le_bytes(num_bytes)
      value = read_le_bytes(num_bytes)
      max_positive = 1 << (num_bytes * 8 - 1)
      (value >= max_positive) ? value - (1 << (num_bytes * 8)) : value
    end

    def parse_tuple_types(types_str)
      types = []
      depth = 0
      current = +""

      types_str.each_char do |c|
        case c
        when "("
          depth += 1
          current << c
        when ")"
          depth -= 1
          current << c
        when ","
          if depth == 0
            types << current.strip
            current = +""
          else
            current << c
          end
        else
          current << c
        end
      end

      types << current.strip unless current.empty?
      types
    end
  end
end
