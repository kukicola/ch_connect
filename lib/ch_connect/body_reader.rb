# frozen_string_literal: true

module ChConnect
  # Wrapper for HTTP response body providing position tracking and EOF detection.
  # @api private
  class BodyReader
    # Creates a new body reader.
    #
    # @param body [#read, #bytesize, #close] HTTP response body
    def initialize(body)
      @body = body
      @pos = 0
      @size = body.bytesize
    end

    # Closes the underlying body.
    #
    # @return [void]
    def close
      @body.close
    end

    # Returns true if at end of stream.
    #
    # @return [Boolean]
    def eof?
      @pos >= @size
    end

    # Reads exactly n bytes from the body.
    #
    # @param n [Integer] number of bytes to read
    # @return [String] binary string of n bytes
    def read(n)
      result = @body.read(n)
      @pos += n
      result
    end
  end
end
