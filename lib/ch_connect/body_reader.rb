# frozen_string_literal: true

module ChConnect
  # Wrapper for HTTP response body providing buffered reads.
  # Reads data in chunks for efficient small reads.
  # @api private
  class BodyReader
    CHUNK_SIZE = 64 * 1024 # 64KB chunks

    # Creates a new body reader.
    #
    # @param body [#read, #bytesize, #close] HTTP response body
    def initialize(body)
      @body = body
      @size = body.bytesize
      @buffer = "".b
      @buffer_pos = 0
      @eof = false
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
      fill_buffer(1) if @buffer_pos >= @buffer.bytesize && !@eof
      @eof && @buffer_pos >= @buffer.bytesize
    end

    # Reads exactly n bytes from the body.
    #
    # @param n [Integer] number of bytes to read
    # @return [String] binary string of n bytes
    def read(n)
      fill_buffer(n)
      result = @buffer.byteslice(@buffer_pos, n)
      @buffer_pos += n
      compact_buffer if @buffer_pos > CHUNK_SIZE
      result
    end

    # Reads a single byte as integer, returns nil at EOF.
    #
    # @return [Integer, nil] byte value or nil at EOF
    def getbyte
      fill_buffer(1)
      return nil if @buffer_pos >= @buffer.bytesize

      byte = @buffer.getbyte(@buffer_pos)
      @buffer_pos += 1
      compact_buffer if @buffer_pos > CHUNK_SIZE
      byte
    end

    private

    def fill_buffer(needed)
      while !@eof && (@buffer.bytesize - @buffer_pos) < needed
        chunk = @body.read(CHUNK_SIZE)
        if chunk.nil? || chunk.empty?
          @eof = true
        else
          @buffer << chunk
        end
      end
    end

    def compact_buffer
      @buffer = @buffer.byteslice(@buffer_pos..-1) || "".b
      @buffer_pos = 0
    end
  end
end
