# Mystral perf baselines — the index hot paths that exist today.
#
#   crystal run --release bench/reindex_bench.cr
#
# Save output under bench/baselines/<date>-<label>.txt before any experiment
# so we can A/B compare. No "should be faster" without numbers.
#
# Manual iteration counts with Benchmark.measure (not Benchmark.ips): the IPS
# warmup loop hammers GC hard enough to segfault inside Crystal::Parser on the
# large fixture. Manual measurement gives the same throughput without that.
#
# Sections that arrive with later increments:
#   - reindex_many (parallel scan)   → workspace-scan increment
#   - side-index read (fact_at)      → InferenceIndex increment
#   - hover end-to-end               → hover increment

require "benchmark"
require "../src/mystral"

private def gen_file(n_classes : Int32, methods_per_class : Int32) : String
  String.build do |io|
    n_classes.times do |i|
      io << "class Class" << i << "\n"
      methods_per_class.times do |j|
        io << "  def method_" << j << "(x : Int32, y : String = \"\") : Int32\n"
        io << "    x + " << j << "\n"
        io << "  end\n"
      end
      io << "end\n"
    end
  end
end

private def throughput(label : String, iterations : Int32, & : -> _) : Nil
  elapsed = Benchmark.measure { iterations.times { yield } }
  per_sec = iterations / elapsed.real
  us_each = (elapsed.real * 1_000_000.0) / iterations
  printf "  %-38s %12.0f ops/sec  %10.2f µs/op\n", label, per_sec, us_each
end

small  = gen_file(2, 5)    # ~40 LOC,   ~12 symbols
medium = gen_file(20, 10)  # ~620 LOC,  ~220 symbols
large  = gen_file(100, 20) # ~2200 LOC, ~2100 symbols

puts "Mystral benchmarks — #{Time.utc.to_s("%Y-%m-%d %H:%M UTC")}"
puts "Crystal #{Crystal::VERSION}, build: #{{{flag?(:release) ? "release" : "DEBUG"}}}"
puts "=" * 72
puts

puts "[1] Index#reindex — single-file throughput"
idx = Mystral::Index.new
throughput("small  (#{small.lines.size} LOC, ~12 syms)",   1000) { idx.reindex("file:///s.cr", small) }
throughput("medium (#{medium.lines.size} LOC, ~220 syms)", 1000) { idx.reindex("file:///m.cr", medium) }
throughput("large  (#{large.lines.size} LOC, ~2100 syms)", 200)  { idx.reindex("file:///l.cr", large) }
puts

puts "[2] Cold workspace indexing — sequential, single fiber"
{10, 50, 200, 500}.each do |n|
  elapsed = Benchmark.measure do
    fresh = Mystral::Index.new
    n.times { |i| fresh.reindex("file:///gen#{i}.cr", medium) }
  end
  per_file_ms = (elapsed.real * 1000.0) / n
  printf "  %4d medium files: %7.3fs total   %8.2f ms/file\n", n, elapsed.real, per_file_ms
end
puts

puts "[3] Query path (index pre-loaded with 500 medium files)"
warm = Mystral::Index.new
500.times { |i| warm.reindex("file:///gen#{i}.cr", medium) }
total_syms = 0
warm.each_symbol { total_syms += 1 }
puts "  Loaded: #{total_syms} symbols across 500 files"
# find_by_name is a @by_name hash lookup → O(1) + |matches|; hit and miss
# differ only by the matches returned.
throughput("each_symbol traversal",           5_000) { c = 0; warm.each_symbol { c += 1 } }
throughput("find_by_name (hit, 500 matches)", 50_000) { warm.find_by_name("method_5") }
throughput("find_by_name (miss)",             50_000) { warm.find_by_name("Sprocket") }
