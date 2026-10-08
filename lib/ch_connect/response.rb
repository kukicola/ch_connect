# frozen_string_literal: true

module ChConnect
  # Immutable response object containing query results.
  #
  # @example
  #   response = conn.query("SELECT id, name FROM users")
  #   response.columns   # => [:id, :name]
  #   response.rows      # => [[1, "Alice"], [2, "Bob"]]
  #   response.each { |row| puts row[:name] }
  Response = Data.define(:columns, :types, :rows, :summary) do
    include Enumerable

    # Iterates over rows as hashes with symbol keys.
    # @yield [Hash] each row as a hash
    # @return [Enumerator] if no block given
    def each
      return to_enum(:each) unless block_given?

      # An index loop avoids zip's per-row pair arrays (~3x faster under YJIT).
      names = columns
      count = names.size
      rows.each do |row|
        hash = {}
        index = 0
        while index < count
          hash[names[index]] = row[index]
          index += 1
        end
        yield hash
      end
    end
  end
end
