# frozen_string_literal: true

RSpec.describe ChConnect::Connection do
  let(:config) do
    ChConnect.config.dup
  end
  let(:connection) { @connection = described_class.new(config) }

  after { @connection&.close }

  describe "#query" do
    it "recovers the pooled connection after a server error" do
      native_client = nil
      allow(described_class::Slot).to receive(:new).and_call_original
      allow(ChConnect::NativeClient).to receive(:new).and_wrap_original do |method, *args|
        native_client = method.call(*args)
      end

      expect { connection.query("SELECT bad_column FROM system.one") }
        .to raise_error(ChConnect::QueryError)
      expect(native_client.instance_variables.to_h { |ivar| [ivar, native_client.instance_variable_get(ivar)] })
        .to include(:@columns => nil, :@types => nil, :@rows => nil)

      expect(connection.query("SELECT 2 AS two").rows).to eq([[2]])
      expect(ChConnect::NativeClient).to have_received(:new).once
      expect(described_class::Slot).to have_received(:new).once
    end

    it "rejects unsupported fixed types and recovers" do
      allow(described_class::Slot).to receive(:new).and_call_original

      expect { connection.query("SELECT toBFloat16(1)") }
        .to raise_error(ChConnect::UnsupportedTypeError, /BFloat16/)

      expect(connection.query("SELECT 42 AS answer").rows).to eq([[42]])
      expect(described_class::Slot).to have_received(:new).twice
    end

    it "rejects unsupported types in empty result sets" do
      expect { connection.query("SELECT toBFloat16(number) FROM numbers(0)") }
        .to raise_error(ChConnect::UnsupportedTypeError, /BFloat16/)
    end

    it "rejects Nothing and Interval values" do
      expect { connection.query("SELECT NULL AS value") }
        .to raise_error(ChConnect::UnsupportedTypeError, /Nothing/)
      expect { connection.query("SELECT INTERVAL 1 DAY AS value") }
        .to raise_error(ChConnect::UnsupportedTypeError, /Interval/)
    end

    it "survives compacting GC while serializing query parameters" do
      skip "GC compaction is unavailable" unless GC.respond_to?(:auto_compact=)

      params = 16.times.to_h { |i| ["unused_#{i}", "value-#{i}"] }
      params[:target] = "safe"
      previous_stress = GC.stress
      previous_auto_compact = GC.auto_compact
      GC.auto_compact = true
      GC.stress = true

      expect(connection.query("SELECT {target:String} AS target", params: params).rows)
        .to eq([["safe"]])
    ensure
      GC.stress = previous_stress unless previous_stress.nil?
      GC.auto_compact = previous_auto_compact unless previous_auto_compact.nil?
    end

    it "serializes large parameter maps without exhausting a Ruby thread stack" do
      worker = Thread.new do
        params = 40_000.times.to_h { |i| ["unused_#{i}", i] }
        params["target"] = "safe"
        connection.query("SELECT {target:String} AS target", params: params)
      end

      expect(worker.value.rows).to eq([["safe"]])
    end

    it "serves concurrent queries correctly" do
      results = Array.new(8)
      threads = 8.times.map do |i|
        Thread.new do
          results[i] = connection.query("SELECT #{i} AS n, sum(number) AS s FROM numbers(#{10 + i})").rows
        end
      end
      threads.each(&:join)

      8.times do |i|
        expected_sum = (9 + i) * (10 + i) / 2
        expect(results[i]).to eq([[i, expected_sum]])
      end
    end

    it "reopens inherited native connections after fork" do
      skip "fork is unavailable" unless Process.respond_to?(:fork)

      connection.query("SELECT 1")
      pool = connection.instance_variable_get(:@pool)
      parent_port = pool.with { |slot| slot.instance_variable_get(:@socket).local_address.ip_port }
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        begin
          connection.query("SELECT 1")
          child_port = pool.with { |slot| slot.instance_variable_get(:@socket).local_address.ip_port }
          Marshal.dump([:ok, child_port], writer)
        rescue => e
          Marshal.dump([:error, "#{e.class}: #{e.message}"], writer)
        ensure
          writer.close
        end
        exit! 0
      end
      writer.close
      status, payload = Marshal.load(reader)
      Process.wait(pid)

      expect(status).to eq(:ok), "child query failed: #{payload}"
      expect(payload).not_to eq(parent_port)
      expect(connection.query("SELECT 1").rows).to eq([[1]])
    ensure
      reader&.close
      writer&.close
    end
  end

  describe "compression" do
    let(:typed_query) { "SELECT number, toString(number) AS s, toDate('2024-01-01') + number AS d, [number, number + 1] AS a FROM system.numbers LIMIT 1000" }

    def rows_with(compression)
      alt = described_class.new(config.dup.tap { |c| c.compression = compression })
      alt.query(typed_query).rows
    ensure
      alt&.close
    end

    it "returns identical rows with lz4, zstd and no compression" do
      plain = rows_with(nil)

      expect(rows_with(:lz4)).to eq(plain)
      expect(rows_with(:zstd)).to eq(plain) if ChConnect::NativeClient::ZSTD_AVAILABLE
    end

    it "keeps compression configuration authoritative" do
      expect {
        connection.query("SELECT 1", settings: {network_compression_method: "zstd"})
      }.to raise_error(ArgumentError, /config\.compression/)
    end
  end

  describe "summary" do
    it "uses string values" do
      client = ChConnect::NativeClient.new("default", "default", "", 0)
      client.instance_variable_set(:@columns, [])
      client.instance_variable_set(:@types, [])
      client.instance_variable_set(:@rows, [])

      summary = client.take_result.last

      expect(summary.values).to all(be_a(String))
      expect { client.take_result }
        .to raise_error(ChConnect::ConnectionError, /no completed native result/)
    ensure
      client&.close
    end
  end

  describe "timeouts" do
    it "recycles pooled connections after keep_alive_timeout" do
      idle_config = config.dup.tap do |c|
        c.keep_alive_timeout = 0
        c.pool_size = 1
      end
      idle_connection = described_class.new(idle_config)
      allow(described_class::Slot).to receive(:new).and_call_original

      idle_connection.query("SELECT 1")
      idle_connection.query("SELECT 2")

      expect(described_class::Slot).to have_received(:new).twice
    ensure
      idle_connection&.close
    end

    it "writes all output through partial nonblocking writes" do
      slot = described_class::Slot.allocate
      client = double("NativeClient")
      socket = double("Socket")
      config = double("Config", write_timeout: 5.0)

      slot.instance_variable_set(:@client, client)
      slot.instance_variable_set(:@socket, socket)
      slot.instance_variable_set(:@config, config)
      allow(client).to receive(:take_output).and_return("abc", nil)
      allow(slot).to receive(:monotonic_now).and_return(10.0)
      expect(socket).to receive(:write_nonblock).with("abc", exception: false).and_return(1)
      expect(socket).to receive(:write_nonblock).with("bc", exception: false).and_return(2)

      slot.send(:flush_output)
    end

    it "bounds native writes by write_timeout" do
      slot = described_class::Slot.allocate
      client = double("NativeClient", take_output: "blocked")
      socket = double("Socket", write_nonblock: :wait_writable)
      config = double("Config", write_timeout: 5.0)

      slot.instance_variable_set(:@client, client)
      slot.instance_variable_set(:@socket, socket)
      slot.instance_variable_set(:@config, config)
      allow(slot).to receive(:monotonic_now).and_return(10.0, 15.0)

      expect { slot.send(:flush_output) }
        .to raise_error(ChConnect::ConnectionError, "write timeout")
    end

    it "uses one connection timeout budget for the full native handshake" do
      slot = described_class::Slot.allocate
      client = double("NativeClient", handshake_step: nil, feed: nil)
      config = double("Config", connection_timeout: 5.0)

      slot.instance_variable_set(:@client, client)
      slot.instance_variable_set(:@config, config)
      allow(client).to receive(:handshake_step).and_return(:want_read, :want_read, :done)
      allow(slot).to receive(:flush_output)
      allow(slot).to receive(:monotonic_now).and_return(10.0, 11.0, 13.0)
      expect(slot).to receive(:read_chunk).with(4.0).ordered.and_return("first")
      expect(slot).to receive(:read_chunk).with(2.0).ordered.and_return("second")

      slot.send(:handshake)

      expect(client).to have_received(:feed).with("first")
      expect(client).to have_received(:feed).with("second")
    end

    it "stops the native handshake once its connection timeout is exhausted" do
      slot = described_class::Slot.allocate
      client = double("NativeClient", handshake_step: :want_read)
      config = double("Config", connection_timeout: 5.0)

      slot.instance_variable_set(:@client, client)
      slot.instance_variable_set(:@config, config)
      allow(slot).to receive(:flush_output)
      allow(slot).to receive(:monotonic_now).and_return(10.0, 15.0)

      expect { slot.send(:handshake) }
        .to raise_error(ChConnect::ConnectionError, "native handshake timeout")
    end

    it "times out when the server accepts but never responds" do
      silent_server = TCPServer.new("127.0.0.1", 0)
      port = silent_server.addr[1]
      accepter = Thread.new { silent_server.accept }

      silent_config = ChConnect::Config.new(
        host: "127.0.0.1", port: port,
        connection_timeout: 0.5, max_retries: 0
      )
      silent_connection = described_class.new(silent_config)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { silent_connection.query("SELECT 1") }
        .to raise_error(ChConnect::ConnectionError, /read timeout/)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    ensure
      silent_connection&.close
      accepter&.kill
      silent_server&.close
    end

    it "times out connecting to an unroutable address" do
      dead_config = ChConnect::Config.new(
        host: "10.255.255.1", port: 9000,
        connection_timeout: 0.5, max_retries: 0
      )
      dead_connection = described_class.new(dead_config)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { dead_connection.query("SELECT 1") }.to raise_error(ChConnect::ConnectionError)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    ensure
      dead_connection&.close
    end
  end

  describe "retries" do
    let(:retry_config) { config.dup.tap { |c| c.max_retries = 3 } }

    it "retries connection establishment failures" do
      retrying = described_class.new(retry_config)
      pool = double("ConnectionPool")
      slot = double("Slot")
      error = described_class.const_get(:EstablishmentError, false)
      allow(pool).to receive(:with) { |&block| block.call(slot) }
      allow(pool).to receive(:reap)
      allow(pool).to receive(:discard_current_connection)
      allow(slot).to receive(:broken?).and_return(true, true, false)
      attempts = 0
      allow(slot).to receive(:query) do
        attempts += 1
        raise error, "connect failed" if attempts < 3

        [[:one], [:UInt8], [[1]], {}]
      end
      retrying.instance_variable_set(:@pool, pool)

      expect(retrying.query("SELECT 1").rows).to eq([[1]])
      expect(slot).to have_received(:query).exactly(3).times
      expect(pool).to have_received(:discard_current_connection).twice
      expect(pool).to have_received(:reap).with(idle_seconds: 60).once
    end

    it "never retries a query after execution may have started" do
      retrying = described_class.new(retry_config)
      pool = double("ConnectionPool")
      slot = double("Slot")
      allow(pool).to receive(:with) { |&block| block.call(slot) }
      allow(pool).to receive(:reap)
      allow(pool).to receive(:discard_current_connection)
      allow(slot).to receive(:query).and_raise(ChConnect::ConnectionError, "response lost")
      allow(slot).to receive(:broken?).and_return(true)
      retrying.instance_variable_set(:@pool, pool)

      expect { retrying.query("INSERT INTO t VALUES (1)") }
        .to raise_error(ChConnect::ConnectionError, "response lost")
      expect(slot).to have_received(:query).once
      expect(pool).to have_received(:discard_current_connection).once
    end
  end

  describe "interrupt handling" do
    it "recovers after a query thread is killed mid-query" do
      # note: the query must actually use the sleep column — the optimizer
      # prunes unused sleepEachRow calls and the query returns instantly
      worker = Thread.new do
        connection.query("SELECT sleep(3)")
      end
      sleep 0.5 # let the query get in flight
      worker.kill
      worker.join

      expect(connection.query("SELECT 41 + 1 AS x").rows).to eq([[42]])
    end

    it "does not hold the GVL while waiting on the server" do
      ticks = 0
      ticker = Thread.new do
        loop do
          ticks += 1
          sleep 0.01
        end
      end

      connection.query("SELECT sleep(1)")
      ticker.kill
      ticker.join

      # ~100 expected with the GVL released; near zero if the C call held it
      expect(ticks).to be > 30
    end
  end

  describe "TLS", if: ENV["CH_TLS_PORT"] do
    it "queries over TLS with CA verification" do
      tls_config = config.dup.tap do |c|
        c.port = Integer(ENV["CH_TLS_PORT"])
        c.ssl = true
        c.ssl_verify = true
        c.ssl_ca = ENV.fetch("CH_TLS_CA")
      end
      tls_connection = described_class.new(tls_config)

      expect(tls_connection.query("SELECT 1 AS one").rows).to eq([[1]])
    ensure
      tls_connection&.close
    end

    it "reopens inherited TLS connections without shutting down the parent's session" do
      skip "fork is unavailable" unless Process.respond_to?(:fork)

      tls_config = config.dup.tap do |c|
        c.port = Integer(ENV["CH_TLS_PORT"])
        c.ssl = true
        c.ssl_verify = true
        c.ssl_ca = ENV.fetch("CH_TLS_CA")
        c.pool_size = 1
        c.max_retries = 0
      end
      tls_connection = described_class.new(tls_config)
      tls_connection.query("SELECT 1")
      pool = tls_connection.instance_variable_get(:@pool)
      parent_port = pool.with { |slot| slot.instance_variable_get(:@socket).to_io.local_address.ip_port }
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        begin
          tls_connection.query("SELECT 1")
          child_port = pool.with { |slot| slot.instance_variable_get(:@socket).to_io.local_address.ip_port }
          Marshal.dump([:ok, child_port], writer)
        rescue => e
          Marshal.dump([:error, "#{e.class}: #{e.message}"], writer)
        ensure
          writer.close
        end
        exit! 0
      end
      writer.close
      status, child_port = Marshal.load(reader)
      Process.wait(pid)

      expect(status).to eq(:ok), "child query failed: #{child_port}"
      expect(child_port).not_to eq(parent_port)
      expect(tls_connection.query("SELECT 2").rows).to eq([[2]])
      expect(pool.with { |slot| slot.instance_variable_get(:@socket).to_io.local_address.ip_port })
        .to eq(parent_port)
    ensure
      reader&.close
      writer&.close
      tls_connection&.close
    end

    it "rejects an unverifiable certificate against the system store" do
      tls_config = config.dup.tap do |c|
        c.port = Integer(ENV["CH_TLS_PORT"])
        c.ssl = true
        c.ssl_verify = true
        c.max_retries = 0
      end
      tls_connection = described_class.new(tls_config)

      expect { tls_connection.query("SELECT 1") }
        .to raise_error(ChConnect::ConnectionError, /certificate verify/)
    ensure
      tls_connection&.close
    end
  end

  describe "URL-based configuration" do
    it "handles a URL without credentials" do
      url_config = ChConnect::Config.new
      url_config.url = "clickhouse://#{config.host}:#{config.port}/default"
      url_connection = described_class.new(url_config)

      # must not crash on nil credentials; auth outcome depends on the server
      expect {
        begin
          url_connection.query("SELECT 1")
        rescue ChConnect::Error
          nil
        end
      }.not_to raise_error
    ensure
      url_connection&.close
    end
  end

  describe "parameter formatting" do
    it "quotes string values" do
      expect(connection.send(:format_params, {name: "al'ice"})).to eq([["name", "'al\\\\\\'ice'"]])
    end

    it "quotes numeric values as strings" do
      expect(connection.send(:format_params, {id: 42})).to eq([["id", "'42'"]])
    end

    it "converts nil to the native nullable dump marker" do
      expect(connection.send(:format_params, {x: nil})).to eq([["x", "'\\\\N'"]])
    end

    it "escapes binary and control bytes for Field dump strings" do
      value = "nul:\0 bell:\a back:\b esc:\e form:\f line:\n return:\r tab:\t vert:\v quote:' slash:\\"
      response = connection.query(
        "SELECT {value:String} AS value",
        params: {value: value}
      )

      expect(response.rows).to eq([[value]])
      expect(connection.send(:format_params, {value: "a\0b"}).dig(0, 1)).to eq("'a\\\\0b'")
    end

    it "returns nil for empty params" do
      expect(connection.send(:format_params, nil)).to be_nil
      expect(connection.send(:format_params, {})).to be_nil
    end

    it "protects native decoder settings" do
      expect {
        connection.query("SELECT 1", settings: {output_format_native_encode_types_in_binary_format: true})
      }.to raise_error(ArgumentError, /managed by ch_connect/)
    end
  end
end
