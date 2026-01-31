# frozen_string_literal: true

module ChConnect
  # Null instrumenter that does nothing.
  # This is the default instrumenter used when no custom instrumenter is configured.
  class NullInstrumenter
    # Executes block without any instrumentation.
    #
    # @param _name [String] event name (ignored)
    # @param _payload [Hash] event payload (ignored)
    # @yield block to execute
    # @return [Object] result of the block
    def instrument(_name, _payload = {})
      yield
    end
  end
end
