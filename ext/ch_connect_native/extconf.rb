# frozen_string_literal: true

# The native extension is MRI-only. On other engines (JRuby, TruffleRuby)
# write a no-op Makefile so the gem still installs; transport :http works
# everywhere and transport :native raises a descriptive error at runtime.
unless RUBY_ENGINE == "ruby"
  File.write("Makefile", "all:\ninstall:\nclean:\n")
  puts "ch_connect_native is MRI-only; skipping build (transport :native will be unavailable)"
  exit 0
end

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
