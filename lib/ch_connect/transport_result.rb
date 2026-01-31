# frozen_string_literal: true

module ChConnect
  # Immutable result from transport layer.
  # @api private
  #
  # @!attribute [r] body
  #   @return [HTTP::Response::Body] response body
  # @!attribute [r] summary
  #   @return [Hash] ClickHouse query summary
  TransportResult = Data.define(:body, :summary)
end
