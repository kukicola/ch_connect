# frozen_string_literal: true

RSpec.describe ChConnect::HttpTransport do
  let(:config) { ChConnect.config }
  let(:transport) { described_class.new(config) }

  describe "#execute" do
    it "returns TransportResult for valid query" do
      result = transport.execute("SELECT 1")

      expect(result).to be_a(ChConnect::TransportResult)
      expect(result.summary).to be_a(Hash)
      expect(result.body).not_to be_nil
    end

    it "raises QueryError for invalid query" do
      expect {
        transport.execute("INVALID SQL SYNTAX")
      }.to raise_error(ChConnect::QueryError, /Syntax error/)
    end

    it "raises QueryError for auth failures (no summary header in response)" do
      bad_config = ChConnect::Config.new(
        host: config.host, port: config.port,
        username: "default", password: "definitely-wrong-password"
      )

      expect {
        described_class.new(bad_config).execute("SELECT 1")
      }.to raise_error(ChConnect::QueryError, /[Aa]uthentication|password/)
    end
  end
end
