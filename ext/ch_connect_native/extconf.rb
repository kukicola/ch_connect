# frozen_string_literal: true

abort "ch_connect requires MRI Ruby" unless RUBY_ENGINE == "ruby"

require "mkmf"

vendor_dir = File.expand_path("../../vendor/clickhouse-c", __dir__)
$INCFLAGS << " -I#{vendor_dir}"

append_cflags("-O2")
append_cflags("-std=c11")

# Help mkmf find Homebrew-installed libraries on macOS.
if RUBY_PLATFORM.include?("darwin")
  %w[lz4 zstd].each do |pkg|
    prefix = `brew --prefix #{pkg} 2>/dev/null`.strip
    next if prefix.empty? || !File.directory?(prefix)

    $INCFLAGS << " -I#{prefix}/include"
    $LDFLAGS << " -L#{prefix}/lib"
  end
end

have_lz4 = have_header("lz4.h") && have_library("lz4", "LZ4_decompress_safe")
have_zstd = have_header("zstd.h") && have_library("zstd", "ZSTD_decompress")

$defs << (have_lz4 ? "-DCHC_EXT_HAVE_LZ4=1" : "-DCHC_NO_LZ4")
$defs << (have_zstd ? "-DCHC_EXT_HAVE_ZSTD=1" : "-DCHC_NO_ZSTD")

message "ch_connect_native: lz4=#{have_lz4} zstd=#{have_zstd} (TLS is handled in Ruby via openssl stdlib)\n"

create_makefile("ch_connect/ch_connect_native")
