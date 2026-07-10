# frozen_string_literal: true

RSpec.describe ChConnect::TcpTransport do
  let(:config) do
    ChConnect::Config.new(
      host: ChConnect.config.host,
      tcp_port: ChConnect.config.tcp_port,
      database: ChConnect.config.database,
      username: ChConnect.config.username,
      password: ChConnect.config.password,
      transport: :native
    )
  end
  let(:transport) { @transport = described_class.new(config) }

  after { @transport&.close }

  describe "#query" do
    it "returns a Response for valid query" do
      response = transport.query("SELECT 1 AS one")

      expect(response).to be_a(ChConnect::Response)
      expect(response.columns).to eq([:one])
      expect(response.rows).to eq([[1]])
      expect(response.summary).to be_a(Hash)
      expect(response.summary).to include(:result_rows, :result_bytes, :elapsed_ns)
    end

    it "raises QueryError for invalid query" do
      expect {
        transport.query("INVALID SQL SYNTAX")
      }.to raise_error(ChConnect::QueryError, /Syntax error/)
    end

    it "recovers the pooled connection after a server error" do
      transport # load the extension before installing the constructor spy
      allow(ChConnect::NativeClient).to receive(:new).and_call_original

      expect { transport.query("SELECT bad_column FROM system.one") }
        .to raise_error(ChConnect::QueryError)

      expect(transport.query("SELECT 2 AS two").rows).to eq([[2]])
      expect(ChConnect::NativeClient).to have_received(:new).once
    end

    it "rejects unsupported fixed types before Ruby decoding and recovers" do
      expect { transport.query("SELECT toBFloat16(1)") }
        .to raise_error(ChConnect::UnsupportedTypeError, /BFloat16/)

      expect(transport.query("SELECT 42 AS answer").rows).to eq([[42]])
    end

    it "survives compacting GC while serializing query parameters" do
      skip "GC compaction is unavailable" unless GC.respond_to?(:auto_compact=)

      params = 16.times.to_h { |i| ["param_unused_#{i}", "value-#{i}"] }
      params[:param_target] = "safe"
      previous_stress = GC.stress
      previous_auto_compact = GC.auto_compact
      GC.auto_compact = true
      GC.stress = true

      expect(transport.query("SELECT {target:String} AS target", params: params).rows)
        .to eq([["safe"]])
    ensure
      GC.stress = previous_stress unless previous_stress.nil?
      GC.auto_compact = previous_auto_compact unless previous_auto_compact.nil?
    end

    it "serves concurrent queries correctly" do
      results = Array.new(8)
      threads = 8.times.map do |i|
        Thread.new do
          results[i] = transport.query("SELECT #{i} AS n, sum(number) AS s FROM numbers(#{10 + i})").rows
        end
      end
      threads.each(&:join)

      8.times do |i|
        expected_sum = (9 + i) * (10 + i) / 2
        expect(results[i]).to eq([[i, expected_sum]])
      end
    end
  end

  describe "compression" do
    let(:typed_query) { "SELECT number, toString(number) AS s, toDate('2024-01-01') + number AS d, [number, number + 1] AS a FROM system.numbers LIMIT 1000" }

    def rows_with(compression)
      alt_config = ChConnect::Config.new(
        host: config.host, tcp_port: config.tcp_port,
        username: config.username, password: config.password,
        transport: :native, compression: compression
      )
      alt = described_class.new(alt_config)
      alt.query(typed_query).rows
    ensure
      alt&.close
    end

    it "returns identical rows with lz4, zstd and no compression" do
      plain = rows_with(nil)

      expect(rows_with(:lz4)).to eq(plain)
      expect(rows_with(:zstd)).to eq(plain) if ChConnect::NativeClient::ZSTD_AVAILABLE
    end

    it "allows overriding network_compression_method to an available codec" do
      skip "zstd not built" unless ChConnect::NativeClient::ZSTD_AVAILABLE

      response = transport.query("SELECT 1 AS one", settings: {network_compression_method: "zstd"})
      expect(response.rows).to eq([[1]])
    end

    it "rejects a network_compression_method override this build cannot decode" do
      stub_const("ChConnect::NativeClient::ZSTD_AVAILABLE", false)

      expect {
        transport.query("SELECT 1", settings: {network_compression_method: "zstd"})
      }.to raise_error(ChConnect::Error, /not decodable by this build/)
    end
  end

  describe "summary" do
    it "uses the same string value types as the HTTP transport" do
      transport # load the native extension without opening a socket
      client = ChConnect::NativeClient.new("default", "default", "", 0)
      client.instance_variable_set(:@columns, [])
      client.instance_variable_set(:@types, [])
      client.instance_variable_set(:@rows, [])

      summary = client.take_result.last

      expect(summary.values).to all(be_a(String))
    ensure
      client&.close
    end
  end

  describe "timeouts" do
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
        host: "127.0.0.1", tcp_port: port, transport: :native,
        connection_timeout: 0.5, max_retries: 0
      )
      silent_transport = described_class.new(silent_config)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { silent_transport.query("SELECT 1") }
        .to raise_error(ChConnect::ConnectionError, /read timeout/)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    ensure
      silent_transport&.close
      accepter&.kill
      silent_server&.close
    end

    it "times out connecting to an unroutable address" do
      dead_config = ChConnect::Config.new(
        host: "10.255.255.1", tcp_port: 9000, transport: :native,
        connection_timeout: 0.5, max_retries: 0
      )
      dead_transport = described_class.new(dead_config)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { dead_transport.query("SELECT 1") }.to raise_error(ChConnect::ConnectionError)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    ensure
      dead_transport&.close
    end
  end

  describe "retries" do
    let(:retry_config) do
      ChConnect::Config.new(
        host: config.host, tcp_port: config.tcp_port,
        username: config.username, password: config.password,
        transport: :native, max_retries: 3
      )
    end

    before do
      # ensure the extension (and thus the NativeClient constant) is loaded
      # through the public path before stubbing it
      described_class.new(retry_config).close
    end

    def fake_client
      double("NativeClient", close: nil, broken?: false,
        handshake_step: :done, take_output: nil, feed: nil, recv_step: :done)
    end

    it "retries on ConnectionError and succeeds" do
      calls = 0
      fake = fake_client
      allow(fake).to receive(:send_query) do
        calls += 1
        raise ChConnect::ConnectionError, "boom" if calls < 3
      end
      allow(fake).to receive(:take_result).and_return([[:one], [:UInt8], [[1]], {}])
      allow(ChConnect::NativeClient).to receive(:new).and_return(fake)

      expect(described_class.new(retry_config).query("SELECT 1").rows).to eq([[1]])
      expect(calls).to eq(3)
    end

    it "gives up after max_retries" do
      fake = fake_client
      allow(fake).to receive(:send_query).and_raise(ChConnect::ConnectionError, "down")
      allow(ChConnect::NativeClient).to receive(:new).and_return(fake)

      expect { described_class.new(retry_config).query("SELECT 1") }
        .to raise_error(ChConnect::ConnectionError, "down")
      expect(fake).to have_received(:send_query).exactly(4).times # initial + 3 retries
    end
  end

  describe "interrupt handling" do
    it "recovers after a query thread is killed mid-query" do
      # note: the query must actually use the sleep column — the optimizer
      # prunes unused sleepEachRow calls and the query returns instantly
      worker = Thread.new do
        transport.query("SELECT sleep(3)")
      end
      sleep 0.5 # let the query get in flight
      worker.kill
      worker.join

      expect(transport.query("SELECT 41 + 1 AS x").rows).to eq([[42]])
    end

    it "does not hold the GVL while waiting on the server" do
      ticks = 0
      ticker = Thread.new do
        loop do
          ticks += 1
          sleep 0.01
        end
      end

      transport.query("SELECT sleep(1)")
      ticker.kill
      ticker.join

      # ~100 expected with the GVL released; near zero if the C call held it
      expect(ticks).to be > 30
    end
  end

  describe "TLS", if: ENV["CH_TLS_PORT"] do
    it "queries over TLS with CA verification" do
      tls_config = ChConnect::Config.new(
        host: config.host, tcp_port: Integer(ENV["CH_TLS_PORT"]),
        username: config.username, password: config.password,
        transport: :native, ssl: true, ssl_verify: true, ssl_ca: ENV.fetch("CH_TLS_CA")
      )
      tls_transport = described_class.new(tls_config)

      expect(tls_transport.query("SELECT 1 AS one").rows).to eq([[1]])
    ensure
      tls_transport&.close
    end

    it "rejects an unverifiable certificate against the system store" do
      tls_config = ChConnect::Config.new(
        host: config.host, tcp_port: Integer(ENV["CH_TLS_PORT"]),
        username: config.username, password: config.password,
        transport: :native, ssl: true, ssl_verify: true, max_retries: 0
      )
      tls_transport = described_class.new(tls_config)

      expect { tls_transport.query("SELECT 1") }
        .to raise_error(ChConnect::ConnectionError, /certificate verify/)
    ensure
      tls_transport&.close
    end
  end

  describe "URL-based configuration" do
    it "handles a URL without credentials" do
      url_config = ChConnect::Config.new(transport: :native, tcp_port: config.tcp_port)
      url_config.url = "clickhouse://#{config.host}:#{config.tcp_port}/default"
      url_transport = described_class.new(url_config)

      # must not crash on nil credentials; auth outcome depends on the server
      expect {
        begin
          url_transport.query("SELECT 1")
        rescue ChConnect::Error
          nil
        end
      }.not_to raise_error
    ensure
      url_transport&.close
    end
  end

  describe "parameter formatting" do
    it "quotes string values and strips the param_ prefix" do
      expect(transport.send(:format_params, {param_name: "al'ice"})).to eq([["name", "'al\\'ice'"]])
    end

    it "quotes numeric values as strings" do
      expect(transport.send(:format_params, {param_id: 42})).to eq([["id", "'42'"]])
    end

    it "converts nil to the native nullable dump marker" do
      expect(transport.send(:format_params, {param_x: nil})).to eq([["x", "'\\\\N'"]])
    end

    it "returns nil for empty params" do
      expect(transport.send(:format_params, nil)).to be_nil
      expect(transport.send(:format_params, {})).to be_nil
    end
  end
end
