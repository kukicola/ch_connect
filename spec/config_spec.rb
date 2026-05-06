# frozen_string_literal: true

RSpec.describe ChConnect::Config do
  describe "#initialize" do
    it "has default values" do
      config = described_class.new

      expect(config.scheme).to eq("http")
      expect(config.host).to eq("localhost")
      expect(config.port).to eq(8123)
      expect(config.database).to eq("default")
      expect(config.username).to eq("")
      expect(config.password).to eq("")
      expect(config.connection_timeout).to eq(5)
      expect(config.read_timeout).to eq(60)
      expect(config.write_timeout).to eq(60)
      expect(config.keep_alive_timeout).to eq(8)
    end

    it "accepts custom values" do
      config = described_class.new(
        scheme: "https",
        host: "clickhouse.example.com",
        port: 8443,
        database: "analytics",
        username: "admin",
        password: "secret",
        connection_timeout: 10,
        read_timeout: 120,
        write_timeout: 30
      )

      expect(config.scheme).to eq("https")
      expect(config.host).to eq("clickhouse.example.com")
      expect(config.port).to eq(8443)
      expect(config.database).to eq("analytics")
      expect(config.username).to eq("admin")
      expect(config.password).to eq("secret")
      expect(config.connection_timeout).to eq(10)
      expect(config.read_timeout).to eq(120)
      expect(config.write_timeout).to eq(30)
    end

    it "merges custom values with defaults" do
      config = described_class.new(host: "remote.example.com", port: 9000)

      expect(config.host).to eq("remote.example.com")
      expect(config.port).to eq(9000)
      expect(config.scheme).to eq("http")
      expect(config.database).to eq("default")
    end
  end

  describe "#url=" do
    it "parses full URL" do
      config = described_class.new
      config.url = "https://user:pass@clickhouse.example.com:8443/mydb"

      expect(config.scheme).to eq("https")
      expect(config.host).to eq("clickhouse.example.com")
      expect(config.port).to eq(8443)
      expect(config.database).to eq("mydb")
      expect(config.username).to eq("user")
      expect(config.password).to eq("pass")
    end

    it "parses URL without credentials" do
      config = described_class.new
      config.url = "http://localhost:8123/default"

      expect(config.scheme).to eq("http")
      expect(config.host).to eq("localhost")
      expect(config.port).to eq(8123)
      expect(config.database).to eq("default")
      expect(config.username).to be_nil
      expect(config.password).to be_nil
    end

    it "parses URL with empty database path" do
      config = described_class.new
      config.url = "http://localhost:8123/"

      expect(config.database).to eq("")
    end

    it "handles URL without trailing slash" do
      config = described_class.new
      config.url = "http://localhost:8123"

      expect(config.host).to eq("localhost")
      expect(config.port).to eq(8123)
      expect(config.database).to eq("")
    end
  end

  describe "attribute accessors" do
    it "allows setting values after initialization" do
      config = described_class.new

      config.host = "new-host.example.com"
      config.port = 9999

      expect(config.host).to eq("new-host.example.com")
      expect(config.port).to eq(9999)
    end
  end
end
