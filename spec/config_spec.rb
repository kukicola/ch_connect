# frozen_string_literal: true

RSpec.describe ChConnect::Config do
  describe "#initialize" do
    it "has native TCP defaults" do
      config = described_class.new

      expect(config.host).to eq("localhost")
      expect(config.port).to eq(9000)
      expect(config.ssl).to be(false)
      expect(config.compression).to eq(:lz4)
      expect(config.database).to eq("default")
      expect(config.username).to eq("default")
      expect(config.password).to eq("")
      expect(config.connection_timeout).to eq(5)
      expect(config.read_timeout).to eq(60)
      expect(config.write_timeout).to eq(60)
      expect(config.keep_alive_timeout).to eq(60)
    end

    it "accepts custom values" do
      config = described_class.new(
        host: "clickhouse.example.com",
        port: 9440,
        ssl: true,
        database: "analytics",
        username: "admin",
        password: "secret",
        connection_timeout: 10,
        read_timeout: 120,
        write_timeout: 30
      )

      expect(config.host).to eq("clickhouse.example.com")
      expect(config.port).to eq(9440)
      expect(config.ssl).to be(true)
      expect(config.database).to eq("analytics")
      expect(config.username).to eq("admin")
      expect(config.password).to eq("secret")
      expect(config.connection_timeout).to eq(10)
      expect(config.read_timeout).to eq(120)
      expect(config.write_timeout).to eq(30)
    end

    it "derives the default port from TLS mode" do
      expect(described_class.new.port).to eq(9000)
      expect(described_class.new(ssl: true).port).to eq(9440)
    end
  end

  describe "#url=" do
    it "parses a native URL" do
      config = described_class.new
      config.url = "clickhouse://user:pass@clickhouse.example.com:9010/mydb"

      expect(config.host).to eq("clickhouse.example.com")
      expect(config.port).to eq(9010)
      expect(config.ssl).to be(false)
      expect(config.database).to eq("mydb")
      expect(config.username).to eq("user")
      expect(config.password).to eq("pass")
    end

    it "uses native defaults for portless URLs" do
      config = described_class.new
      config.url = "clickhouse://clickhouse.example.com/analytics"
      expect(config.port).to eq(9000)
      expect(config.ssl).to be(false)

      config.url = "clickhouses://clickhouse.example.com/analytics"
      expect(config.port).to eq(9440)
      expect(config.ssl).to be(true)
    end

    it "accepts tcp aliases" do
      config = described_class.new
      config.url = "tcps://clickhouse.example.com/data"

      expect(config.port).to eq(9440)
      expect(config.ssl).to be(true)
    end

    it "handles URLs without credentials or a database path" do
      config = described_class.new
      config.url = "clickhouse://localhost:9000"

      expect(config.host).to eq("localhost")
      expect(config.database).to eq("default")
      expect(config.username).to eq("default")
      expect(config.password).to eq("")
    end

    it "rejects non-native schemes" do
      expect { described_class.new.url = "https://clickhouse.example.com/data" }
        .to raise_error(ArgumentError, /unsupported ClickHouse URL scheme/)
    end
  end
end
