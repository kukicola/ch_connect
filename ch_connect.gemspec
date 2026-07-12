# frozen_string_literal: true

require_relative "lib/ch_connect/version"

Gem::Specification.new do |spec|
  spec.name = "ch_connect"
  spec.version = ChConnect::VERSION
  spec.authors = ["Karol Bąk"]
  spec.email = ["kukicola@gmail.com"]

  spec.summary = "Ruby client for ClickHouse's native TCP protocol"
  spec.description = "Fast Ruby client for ClickHouse using its native TCP protocol and binary format"
  spec.homepage = "https://github.com/kukicola/ch_connect"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      !File.file?(File.join(__dir__, f)) ||
        (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ benchmark/ .git .github appveyor Gemfile])
    end
  end
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/ch_connect_native/extconf.rb"]

  spec.add_dependency "bigdecimal", "~> 3.1"
  spec.add_dependency "connection_pool", "~> 2.4"
end
