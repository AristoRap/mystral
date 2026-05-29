# Memory footprint profile — attributes RSS so we can SEE what costs memory.
# The dominant structure is the symbol Index (Array(Entry) per URI). This is
# where the struct-vs-class decision pays off: tens of thousands of entries
# packed inline in per-URI buffers, not that many separate heap objects.
#
#   crystal run --release --no-debug bench/footprint.cr -- /path/to/project
#
# Scans the target workspace AND CRYSTAL_PATH (stdlib + shards) — exactly what
# the LSP indexes on startup — so the symbol count + RSS are the real ones.
# Defaults to this repo. RSS via `ps`; GC-heap via GC.stats. GC.collect before
# each read to measure steady state.

require "../src/mystral"

def rss_mb : Float64
  `ps -o rss= -p #{Process.pid}`.strip.to_i64 / 1024.0
rescue
  0.0
end

def report(label : String) : Nil
  GC.collect
  heap = GC.stats.heap_size / 1024.0 / 1024.0
  printf "  %-46s RSS %7.1f MB   GC-heap %7.1f MB\n", label, rss_mb, heap
end

target = ARGV[0]? || Dir.current
puts "Footprint profile — #{Time.utc.to_s("%Y-%m-%d %H:%M UTC")}"
puts "Target: #{target}"
puts "Crystal #{Crystal::VERSION}, build: #{{{flag?(:release) ? "release" : "DEBUG"}}}"
puts "=" * 78

report("baseline (process boot)")
baseline = rss_mb

# Full workspace + CRYSTAL_PATH scan — exactly what lifecycle does on startup:
# the user's code PLUS stdlib + shards in lib/.
roots = [target]
crystal_paths = Mystral::CrystalPaths.resolve(Mystral::CrystalPaths.discover, roots)
target_dirs = Mystral::CrystalPaths.target_subdirs(crystal_paths)
all_roots = roots + crystal_paths + target_dirs

index = Mystral::Index.new
t = Time.instant
all_roots.each { |d| index.scan_directory(d) }
scan_ms = (Time.instant - t).total_milliseconds

syms = 0
index.each_symbol { syms += 1 }
report("after full index (#{syms} syms, #{scan_ms.round.to_i}ms)")
after = rss_mb

puts "=" * 78
if syms > 0
  bytes_per_sym = ((after - baseline) * 1024.0 * 1024.0) / syms
  printf "Index cost: +%.1f MB RSS for %d symbols  →  %.0f bytes/symbol\n",
    (after - baseline), syms, bytes_per_sym
  puts "(struct Entry: the #{syms} records live inline in per-URI buffers — no"
  puts " per-entry heap object or GC header; as a class this would be #{syms}"
  puts " separate allocations + headers.)"
end
