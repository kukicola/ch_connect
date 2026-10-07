# frozen_string_literal: true

require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"

RSpec.describe "vendored type parser allocation failures" do
  it "releases every allocation when parsing Tuple and Enum types fails" do
    root = File.expand_path("..", __dir__)
    Dir.mktmpdir("ch-connect-alloc") do |dir|
      executable = File.join(dir, "vendor_alloc")
      command = Shellwords.split(RbConfig::CONFIG.fetch("CC")) + [
        "-std=c11", "-I#{root}/vendor/clickhouse-c",
        "#{__dir__}/support/vendor_alloc.c", "-o", executable
      ]
      output, status = Open3.capture2e(*command)
      expect(status.success?).to be(true), output
      output, status = Open3.capture2e(executable)
      expect(status.success?).to be(true), output
    end
  end
end
