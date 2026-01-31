# frozen_string_literal: true

RSpec.describe ChConnect::Response do
  describe "#initialize" do
    it "has default empty values" do
      response = described_class.new

      expect(response.columns).to eq([])
      expect(response.types).to eq([])
      expect(response.rows).to eq([])
      expect(response.summary).to be_nil
    end

    it "accepts custom values" do
      response = described_class.new(
        columns: [:id, :name],
        types: [:UInt32, :String],
        rows: [[1, "Alice"], [2, "Bob"]],
        summary: {read_rows: "2"}
      )

      expect(response.columns).to eq([:id, :name])
      expect(response.types).to eq([:UInt32, :String])
      expect(response.rows).to eq([[1, "Alice"], [2, "Bob"]])
      expect(response.summary).to eq({read_rows: "2"})
    end
  end

  describe "Enumerable" do
    let(:response) do
      described_class.new(
        columns: [:id, :name],
        rows: [[1, "Alice"], [2, "Bob"]]
      )
    end

    it "includes Enumerable" do
      expect(described_class).to include(Enumerable)
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

    it "supports Enumerable methods like map" do
      names = response.map { |row| row[:name] }

      expect(names).to eq(["Alice", "Bob"])
    end

    it "supports Enumerable methods like select" do
      filtered = response.select { |row| row[:id] > 1 }

      expect(filtered).to eq([{id: 2, name: "Bob"}])
    end

    it "supports first" do
      expect(response.first).to eq({id: 1, name: "Alice"})
    end

    it "returns empty enumeration for empty response" do
      empty_response = described_class.new

      expect(empty_response.to_a).to eq([])
    end
  end
end
