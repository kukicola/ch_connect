# frozen_string_literal: true

RSpec.describe ChConnect::HttpTransport do
  let(:config) do
    ChConnect::Config.new.tap do |http_config|
      http_config.url = ENV.fetch("CLICKHOUSE_URL", "http://localhost:8123/default")
    end
  end
  let(:transport) { described_class.new(config) }

  describe "#query" do
    it_behaves_like "a ClickHouse transport"

    it "raises QueryError for auth failures (no summary header in response)" do
      bad_config = ChConnect::Config.new(
        host: config.host, port: config.port,
        username: "default", password: "definitely-wrong-password"
      )

      expect {
        described_class.new(bad_config).query("SELECT 1")
      }.to raise_error(ChConnect::QueryError, /[Aa]uthentication|password/)
    end
  end

  describe "parameter formatting" do
    it "encodes nil as ClickHouse's HTTP NULL marker" do
      expect(transport.send(:format_params, {param_value: nil, param_name: "alice"}))
        .to eq({param_value: "\\N", param_name: "alice"})
    end
  end
end
