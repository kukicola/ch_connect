# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  enable_coverage :branch

  add_filter "/spec/"
end

require "ch_connect"

Dir[File.join(__dir__, "support", "*.rb")].sort.each { |f| require f }

ChConnect.configure do |config|
  config.url = ENV.fetch("CLICKHOUSE_URL", "http://localhost:8123/default")

  if ENV["CH_TRANSPORT"] == "native"
    config.transport = :native
    config.port = Integer(ENV.fetch("CLICKHOUSE_TCP_PORT", "9000"))
  end
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
