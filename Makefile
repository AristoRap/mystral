.PHONY: test bench footprint build

# Full spec suite — the per-increment commit gate.
test:
	crystal spec

# Index throughput baselines. Release build; redirect to bench/baselines/
# before an experiment to A/B compare.
bench:
	crystal run --release bench/reindex_bench.cr

# Memory footprint. Pass a source tree as TARGET for a meaningful number;
# defaults to this repo's src/.
#   make footprint TARGET=/path/to/crystal/src
footprint:
	crystal run --release --no-debug bench/footprint.cr -- $(or $(TARGET),src)

# Debug build of the library (a smoke compile; the editor reads the release
# binary, wired in a later increment).
build:
	crystal build src/mystral.cr -o bin/mystral
