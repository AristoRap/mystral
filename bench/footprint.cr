# Memory footprint profile — attributes RSS so we can SEE what costs memory.
# Right now the only populated structure is the symbol Index (Array(Entry)
# per URI). This answers the struct-vs-class question with numbers: how many
# bytes of resident memory each indexed Entry actually costs.
#
#   crystal run --release --no-debug bench/footprint.cr -- /path/to/crystal/src
#
# Defaults to this repo's src/. RSS via `ps` (the Activity-Monitor number);
# GC-heap via GC.stats. GC.collect before each read so we measure steady
# state, not transient parse garbage.
#
# Sections for the side-index (hierarchy ancestry + position facts) land with
# the InferenceIndex increment; the full workspace+CRYSTAL_PATH scan lands
# with the workspace-scan increment. Until then this measures the workspace
# slice only — point it at a large source tree for a meaningful number.

require "../src/mystral"

def rss_mb : Float64
  `ps -o rss= -p #{Process.pid}`.strip.to_i64 / 1024.0
rescue
  0.0
end

def report(label : String) : Nil
  GC.collect
  heap = GC.stats.heap_size / 1024.0 / 1024.0
  printf "  %-44s RSS %7.1f MB   GC-heap %7.1f MB\n", label, rss_mb, heap
end

# Recursive .cr collector (a stand-in for Index#scan_directory, which lands
# with the workspace-scan increment). Skips dependency/artifact dirs.
SKIP_DIRS = {"lib", "bin", ".git", ".shards", "node_modules"}

def collect_cr(dir : String, into : Array(String)) : Nil
  Dir.each_child(dir) do |child|
    next if SKIP_DIRS.includes?(child)
    full = File.join(dir, child)
    if File.directory?(full)
      collect_cr(full, into)
    elsif child.ends_with?(".cr")
      into << full
    end
  end
rescue
end

target = ARGV[0]? || File.join(Dir.current, "src")
puts "Footprint profile — #{Time.utc.to_s("%Y-%m-%d %H:%M UTC")}"
puts "Target: #{target}"
puts "Crystal #{Crystal::VERSION}, build: #{{{flag?(:release) ? "release" : "DEBUG"}}}"
puts "=" * 78

report("baseline (process boot)")
baseline = rss_mb

files = [] of String
collect_cr(target, files)

index = Mystral::Index.new
t = Time.instant
files.each do |path|
  source = File.read(path) rescue next
  index.reindex("file://#{path}", source)
end
scan_ms = (Time.instant - t).total_milliseconds

syms = 0
index.each_symbol { syms += 1 }
report("after indexing #{files.size} files (#{syms} syms, #{scan_ms.round.to_i}ms)")
after = rss_mb

puts "=" * 78
if syms > 0
  bytes_per_sym = ((after - baseline) * 1024.0 * 1024.0) / syms
  printf "Index cost: +%.1f MB RSS for %d symbols  →  %.0f bytes/symbol\n",
    (after - baseline), syms, bytes_per_sym
  puts "(Entry is a struct: the #{syms} records live inline in per-URI buffers —"
  puts " no per-entry heap object or GC header. As a class this would be #{syms}"
  puts " separate allocations.)"
else
  puts "No symbols indexed — point the bench at a Crystal source tree:"
  puts "  crystal run --release bench/footprint.cr -- /path/to/src"
end
