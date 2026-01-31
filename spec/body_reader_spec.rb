# frozen_string_literal: true

RSpec.describe ChConnect::BodyReader do
  let(:content) { "Hello, World!".b }
  let(:body) do
    io = StringIO.new(content)
    io.define_singleton_method(:bytesize) { string.bytesize }
    io
  end
  let(:reader) { described_class.new(body) }

  describe "#eof?" do
    it "returns false when data is available" do
      expect(reader.eof?).to be false
    end

    it "returns true after all data is consumed" do
      reader.read(content.bytesize)
      expect(reader.eof?).to be true
    end
  end

  describe "#read" do
    it "reads exact number of bytes" do
      expect(reader.read(5)).to eq("Hello")
    end

    it "advances position after each read" do
      reader.read(7)
      expect(reader.read(6)).to eq("World!")
    end

    it "returns binary encoded string" do
      expect(reader.read(5).encoding).to eq(Encoding::BINARY)
    end
  end

  describe "#close" do
    it "closes the underlying body" do
      expect(body).to receive(:close)
      reader.close
    end
  end
end
