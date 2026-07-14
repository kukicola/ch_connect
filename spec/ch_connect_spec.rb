# frozen_string_literal: true

RSpec.describe ChConnect do
  describe ".config" do
    it "returns a Config instance" do
      expect(described_class.config).to be_a(ChConnect::Config)
    end
  end

  describe ".configure" do
    it "yields the config" do
      described_class.configure do |config|
        expect(config).to be_a(ChConnect::Config)
      end
    end

    it "does nothing without a block" do
      expect { described_class.configure }.not_to raise_error
    end
  end

  describe "querying" do
    let(:connection) { ChConnect::Connection.new }

    describe "integer types" do
      it "parses UInt8" do
        response = connection.query("SELECT toUInt8(0), toUInt8(127), toUInt8(255)")

        expect(response.rows).to eq([[0, 127, 255]])
      end

      it "parses UInt16" do
        response = connection.query("SELECT toUInt16(0), toUInt16(65535)")

        expect(response.rows).to eq([[0, 65535]])
      end

      it "parses UInt32" do
        response = connection.query("SELECT toUInt32(0), toUInt32(4294967295)")

        expect(response.rows).to eq([[0, 4294967295]])
      end

      it "parses UInt64" do
        response = connection.query("SELECT toUInt64(0), toUInt64(18446744073709551615)")

        expect(response.rows).to eq([[0, 18446744073709551615]])
      end

      it "parses UInt128" do
        response = connection.query("SELECT toUInt128(0), toUInt128(18446744073709551616)")

        expect(response.rows).to eq([[0, 18446744073709551616]])
      end

      it "parses UInt256" do
        response = connection.query("SELECT toUInt256(0), toUInt256(12345678901234567890)")

        expect(response.rows).to eq([[0, 12345678901234567890]])
      end

      it "parses Int8" do
        response = connection.query("SELECT toInt8(-128), toInt8(0), toInt8(127)")

        expect(response.rows).to eq([[-128, 0, 127]])
      end

      it "parses Int16" do
        response = connection.query("SELECT toInt16(-32768), toInt16(0), toInt16(32767)")

        expect(response.rows).to eq([[-32768, 0, 32767]])
      end

      it "parses Int32" do
        response = connection.query("SELECT toInt32(-2147483648), toInt32(0), toInt32(2147483647)")

        expect(response.rows).to eq([[-2147483648, 0, 2147483647]])
      end

      it "parses Int64" do
        response = connection.query("SELECT toInt64(-9223372036854775808), toInt64(0), toInt64(9223372036854775807)")

        expect(response.rows).to eq([[-9223372036854775808, 0, 9223372036854775807]])
      end

      it "parses Int128" do
        response = connection.query("SELECT toInt128('-9223372036854775809'), toInt128(0), toInt128('9223372036854775808')")

        expect(response.rows).to eq([[-9223372036854775809, 0, 9223372036854775808]])
      end

      it "parses Int256" do
        response = connection.query("SELECT toInt256('-9223372036854775809'), toInt256(0), toInt256('9223372036854775808')")

        expect(response.rows).to eq([[-9223372036854775809, 0, 9223372036854775808]])
      end
    end

    describe "float types" do
      it "parses Float32" do
        response = connection.query("SELECT toFloat32(1.5), toFloat32(-2.25)")

        expect(response.rows).to eq([[1.5, -2.25]])
      end

      it "parses Float64" do
        response = connection.query("SELECT toFloat64(1.5), toFloat64(-2.25)")

        expect(response.rows).to eq([[1.5, -2.25]])
      end
    end

    describe "boolean type" do
      it "parses Bool" do
        response = connection.query("SELECT true, false")

        expect(response.rows).to eq([[true, false]])
      end
    end

    describe "string types" do
      it "parses String" do
        response = connection.query("SELECT 'hello', 'world'")

        expect(response.rows).to eq([%w[hello world]])
      end

      it "parses empty strings" do
        response = connection.query("SELECT '', 'test'")

        expect(response.rows).to eq([["", "test"]])
      end

      it "parses unicode strings" do
        response = connection.query("SELECT 'привет', '世界'")

        expect(response.rows).to eq([%w[привет 世界]])
      end

      it "parses FixedString" do
        response = connection.query("SELECT toFixedString('abc', 3), toFixedString('de', 3)")

        expect(response.rows).to eq([["abc", "de\x00"]])
      end
    end

    describe "date and time types" do
      it "parses Date" do
        response = connection.query("SELECT toDate('1970-01-01'), toDate('2024-01-01')")

        expect(response.rows).to eq([[Date.new(1970, 1, 1), Date.new(2024, 1, 1)]])
      end

      it "parses Date32" do
        response = connection.query("SELECT toDate32('1900-01-01'), toDate32('2024-01-01')")

        expect(response.rows).to eq([[Date.new(1900, 1, 1), Date.new(2024, 1, 1)]])
      end

      it "parses DateTime" do
        response = connection.query("SELECT toDateTime('2024-01-01 12:30:45', 'UTC')")

        expect(response.rows).to eq([[Time.utc(2024, 1, 1, 12, 30, 45)]])
      end

      it "parses DateTime64" do
        response = connection.query(<<~SQL)
          SELECT
            toDateTime64('2024-01-01 12:30:45.123', 3, 'UTC'),
            toDateTime64('1969-12-31 23:59:59.123456789', 9, 'UTC')
        SQL

        expect(response.rows).to eq([[
          Time.utc(2024, 1, 1, 12, 30, 45, 123_000),
          Time.utc(1969, 12, 31, 23, 59, 59, Rational(123_456_789, 1_000))
        ]])
      end
    end

    describe "decimal types" do
      it "parses Decimal32" do
        response = connection.query("SELECT toDecimal32(123.45, 2)")

        expect(response.rows).to eq([[BigDecimal("123.45")]])
      end

      it "parses Decimal64" do
        response = connection.query("SELECT toDecimal64(123456789.123456, 6)")

        expect(response.rows).to eq([[BigDecimal("123456789.123456")]])
      end

      it "parses Decimal128" do
        response = connection.query("SELECT CAST('12345678901234567890.12' AS Decimal128(2))")

        expect(response.rows).to eq([[BigDecimal("12345678901234567890.12")]])
      end

      it "parses Decimal256" do
        response = connection.query("SELECT CAST('12345678901234567890.123456' AS Decimal256(6))")

        expect(response.rows).to eq([[BigDecimal("12345678901234567890.123456")]])
      end
    end

    describe "UUID type" do
      it "parses UUID" do
        response = connection.query("SELECT toUUID('550e8400-e29b-41d4-a716-446655440000')")

        expect(response.rows).to eq([["550e8400-e29b-41d4-a716-446655440000"]])
      end
    end

    describe "IP address types" do
      it "parses IPv4" do
        response = connection.query("SELECT toIPv4('192.168.1.1')")

        expect(response.rows).to eq([[IPAddr.new("192.168.1.1")]])
      end

      it "parses IPv6" do
        response = connection.query("SELECT toIPv6('2001:0db8:85a3:0000:0000:8a2e:0370:7334')")

        expect(response.rows).to eq([[IPAddr.new("2001:db8:85a3::8a2e:370:7334")]])
      end
    end

    describe "enum types" do
      it "parses Enum8" do
        response = connection.query("SELECT CAST('a', 'Enum8(\\'a\\' = 1, \\'b\\' = 2)')")

        expect(response.rows).to eq([[1]])
      end

      it "parses Enum16" do
        response = connection.query("SELECT CAST('b', 'Enum16(\\'a\\' = 1000, \\'b\\' = 2000)')")

        expect(response.rows).to eq([[2000]])
      end
    end

    describe "array type" do
      it "parses Array of integers" do
        response = connection.query("SELECT [1, 2, 3]")

        expect(response.rows).to eq([[[1, 2, 3]]])
      end

      it "parses Array of strings" do
        response = connection.query("SELECT ['a', 'b', 'c']")

        expect(response.rows).to eq([[%w[a b c]]])
      end

      it "parses empty Array" do
        response = connection.query("SELECT []::Array(UInt8)")

        expect(response.rows).to eq([[[]]])
      end

      it "parses nested Array" do
        response = connection.query("SELECT [[1, 2], [3, 4, 5]]")

        expect(response.rows).to eq([[[[1, 2], [3, 4, 5]]]])
      end
    end

    describe "tuple type" do
      it "parses Tuple" do
        response = connection.query("SELECT tuple(1, 'hello', 3.14)")

        expect(response.rows).to eq([[[1, "hello", 3.14]]])
      end

      it "parses empty Tuple" do
        response = connection.query("SELECT tuple()")

        expect(response.rows).to eq([[[]]])
      end
    end

    describe "map type" do
      it "parses Map" do
        response = connection.query("SELECT map('a', 1, 'b', 2)")

        expect(response.rows).to eq([[{"a" => 1, "b" => 2}]])
      end

      it "parses empty Map" do
        response = connection.query("SELECT map()::Map(String, UInt8)")

        expect(response.rows).to eq([[{}]])
      end

      it "parses Map with Array values" do
        response = connection.query("SELECT map('a', [1, 2], 'b', [3, 4, 5])")

        expect(response.rows).to eq([[{"a" => [1, 2], "b" => [3, 4, 5]}]])
      end

      it "parses Map with Tuple values" do
        response = connection.query("SELECT map('x', (1, 2), 'y', (3, 4))::Map(String, Tuple(UInt8, UInt8))")

        expect(response.rows).to eq([[{"x" => [1, 2], "y" => [3, 4]}]])
      end
    end

    describe "LowCardinality type" do
      it "parses LowCardinality(String)" do
        response = connection.query("SELECT CAST('hello', 'LowCardinality(String)')")

        expect(response.rows).to eq([["hello"]])
      end

      it "parses LowCardinality with repeated values" do
        response = connection.query("SELECT CAST(toString(number % 3), 'LowCardinality(String)') FROM system.numbers LIMIT 9")

        expect(response.rows.flatten).to eq(%w[0 1 2 0 1 2 0 1 2])
      end

      it "parses LowCardinality with large dictionary (UInt16 keys)" do
        response = connection.query("SELECT CAST(toString(number), 'LowCardinality(String)') FROM system.numbers LIMIT 300")

        expect(response.rows.length).to eq(300)
        expect(response.rows.first).to eq(["0"])
        expect(response.rows.last).to eq(["299"])
      end

      it "parses LowCardinality with very large dictionary (UInt32 keys)" do
        response = connection.query("SELECT CAST(toString(number), 'LowCardinality(String)') FROM system.numbers LIMIT 70000 SETTINGS max_block_size=100000")

        expect(response.rows.length).to eq(70_000)
        expect(response.rows.first).to eq(["0"])
        expect(response.rows.last).to eq(["69999"])
      end
    end

    describe "nullable type" do
      it "parses non-null values" do
        response = connection.query("SELECT CAST(1 AS Nullable(UInt8)), CAST(2 AS Nullable(UInt8))")

        expect(response.rows).to eq([[1, 2]])
      end

      it "parses null values" do
        response = connection.query("SELECT NULL::Nullable(UInt8) AS a")

        expect(response.rows).to eq([[nil]])
      end

      it "parses nullable strings" do
        response = connection.query("SELECT CAST('hello' AS Nullable(String)), CAST(NULL AS Nullable(String))")

        expect(response.rows).to eq([["hello", nil]])
      end
    end

    describe "multiple rows" do
      it "parses multiple rows" do
        response = connection.query("SELECT number FROM system.numbers LIMIT 5")

        expect(response.rows).to eq([[0], [1], [2], [3], [4]])
      end

      it "parses multiple data blocks" do
        response = connection.query("SELECT number FROM system.numbers LIMIT 100000")

        expect(response.rows.size).to eq(100_000)
        expect(response.rows.first).to eq([0])
        expect(response.rows.last).to eq([99999])
        expect(response.columns).to eq([:number])
        expect(response.types).to eq([:UInt64])
      end

      it "returns ordinary rows consistently for WITH TOTALS" do
        response = connection.query(<<~SQL)
          SELECT number % 2 AS bucket, count() AS count
          FROM numbers(4)
          GROUP BY bucket WITH TOTALS
          ORDER BY bucket
        SQL

        expect(response.rows).to eq([[0, 2], [1, 2]])
      end

      it "returns ordinary rows consistently when extremes are enabled" do
        response = connection.query(
          "SELECT number FROM numbers(3) ORDER BY number",
          settings: {extremes: 1}
        )

        expect(response.rows).to eq([[0], [1], [2]])
      end
    end

    describe "column metadata" do
      it "returns column names" do
        response = connection.query("SELECT 1 as id, 'test' as name")

        expect(response.columns).to eq(%i[id name])
      end

      it "returns column types" do
        response = connection.query("SELECT toUInt8(1) as id, 'test' as name")

        expect(response.types).to eq(%i[UInt8 String])
      end
    end

    describe "summary" do
      it "returns query metrics" do
        response = connection.query("SELECT 1")

        expect(response.summary).to be_a(Hash)
        expect(response.summary).to have_key(:read_rows)
        expect(response.summary).to have_key(:read_bytes)
        expect(response.summary).to have_key(:result_rows)
        expect(response.summary).to have_key(:result_bytes)
        expect(response.summary).to have_key(:client_elapsed_ns)
        expect(response.summary).not_to have_key(:elapsed_ns)
        expect(response.summary.values_at(:read_rows, :read_bytes)).to all(be_a(String))
      end
    end

    describe "error handling" do
      it "raises QueryError for invalid query" do
        expect {
          connection.query("INVALID SQL")
        }.to raise_error(ChConnect::QueryError, /Syntax error/)
      end

      it "raises QueryError for non-existent table" do
        expect {
          connection.query("SELECT * FROM non_existent_table_12345")
        }.to raise_error(ChConnect::QueryError, /non_existent_table_12345/)
      end

      it "raises UnsupportedTypeError for JSON type" do
        expect {
          connection.query("SELECT '{\"a\": 1}'::JSON")
        }.to raise_error(ChConnect::UnsupportedTypeError, /Unsupported column type: JSON/)
      end
    end

    describe "#to_a" do
      it "returns rows as hashes" do
        response = connection.query("SELECT 1 as id, 'alice' as name")

        expect(response.to_a).to eq([{id: 1, name: "alice"}])
      end
    end

    describe "query parameters" do
      it "passes parameters to query" do
        response = connection.query(
          "SELECT {id:UInt32} as id, {name:String} as name",
          params: {id: 42, name: "alice"}
        )

        expect(response.rows).to eq([[42, "alice"]])
      end

      it "passes typed parameters (integers, arrays, dates, floats)" do
        response = connection.query(
          "SELECT {id:UInt64} AS id, {ids:Array(UInt32)} AS ids, {d:Date} AS d, {f:Float64} AS f",
          params: {id: 123, ids: "[1,2,3]", d: "2024-01-01", f: 1.5}
        )

        expect(response.rows).to eq([[123, [1, 2, 3], Date.new(2024, 1, 1), 1.5]])
      end
    end

    describe "query settings" do
      it "applies per-query settings" do
        expect {
          connection.query(
            "SELECT number FROM system.numbers LIMIT 10",
            settings: {max_result_rows: 5, result_overflow_mode: "throw"}
          )
        }.to raise_error(ChConnect::QueryError, /Limit for result/)
      end

      it "combines settings with parameters" do
        response = connection.query(
          "SELECT {id:UInt32} AS id",
          params: {id: 7},
          settings: {max_threads: 1}
        )

        expect(response.rows).to eq([[7]])
      end

      it "passes nil as SQL NULL" do
        response = connection.query(
          "SELECT {value:Nullable(String)} AS value",
          params: {value: nil}
        )

        expect(response.rows).to eq([[nil]])
      end
    end
  end

  describe "instrumentation" do
    let(:fake_instrumenter) do
      Class.new do
        attr_reader :events

        def instrument(name, payload, &block)
          @events ||= []
          @events << {name: name, payload: payload}
          block.call
        end
      end
    end

    let(:instrumenter_instance) { fake_instrumenter.new }
    let(:config) { ChConnect.config.dup.tap { |c| c.instrumenter = instrumenter_instance } }
    let(:connection) { ChConnect::Connection.new(config) }

    it "calls instrumenter on query" do
      connection.query("SELECT 1")

      expect(instrumenter_instance.events.size).to eq(1)
      expect(instrumenter_instance.events.first[:name]).to eq("query.clickhouse")
      expect(instrumenter_instance.events.first[:payload][:sql]).to eq("SELECT 1")
    end
  end
end
