# frozen_string_literal: true

RSpec.describe ChConnect::HttpTransport do
  let(:config) { ChConnect.config }
  let(:transport) { described_class.new(config) }

  describe "#query" do
    it "returns a parsed Response for valid query" do
      response = transport.query("SELECT 1 AS one")

      expect(response).to be_a(ChConnect::Response)
      expect(response.columns).to eq([:one])
      expect(response.rows).to eq([[1]])
      expect(response.summary).to be_a(Hash)
    end

    it "raises QueryError for invalid query" do
      expect {
        transport.query("INVALID SQL SYNTAX")
      }.to raise_error(ChConnect::QueryError, /Syntax error/)
    end

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
