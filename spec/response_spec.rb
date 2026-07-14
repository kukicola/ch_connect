# frozen_string_literal: true

RSpec.describe ChConnect::Response do
  describe "Enumerable" do
    let(:response) do
      described_class.new(
        columns: [:id, :name],
        types: [:UInt32, :String],
        rows: [[1, "Alice"], [2, "Bob"]],
        summary: {read_rows: 2}
      )
    end

    it "iterates over rows as hashes with symbol keys" do
      results = []
      response.each { |row| results << row }

      expect(results).to eq([
        {id: 1, name: "Alice"},
        {id: 2, name: "Bob"}
      ])
    end

    it "returns an enumerator when no block given" do
      expect(response.each).to be_a(Enumerator)
    end
  end
end
