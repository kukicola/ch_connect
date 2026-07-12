# frozen_string_literal: true

# Shared contract for transports: expects a `transport` let responding to
# #query and returning a fully parsed Response.
RSpec.shared_examples "a ClickHouse transport" do
  it "returns a parsed Response for valid query" do
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
end
