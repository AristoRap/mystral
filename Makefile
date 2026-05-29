SHELL := /bin/sh

# Mystral links no compiler module: the request path is parser-only
# (Crystal::Parser / Crystal::Formatter) and semantic diagnostics come from a
# `crystal build --no-codegen` SUBPROCESS, not an in-process compiler. So
# there's no LLVM build dependency and no compiler-gating flags — `shards
# build` is the whole story. (MT flags for the parallel-parse bench are
# bench-only, never here.)

.PHONY: help setup test test-integration test-all build release copy deploy bench footprint clean

help:
	@echo "  make setup            install Crystal deps (shards)"
	@echo "  make test             fast unit specs (spec/mystral + spec/mystral_cli)"
	@echo "  make test-integration end-to-end specs that shell out to crystal (spec/integration)"
	@echo "  make test-all         test + test-integration"
	@echo "  make build            test + build CLI binary (bin/mystral)"
	@echo "  make release          test + build CLI binary (--release)"
	@echo "  make copy             copy binary to /usr/local/bin (rm+cp, never cp -f)"
	@echo "  make deploy           release + copy  (the end-of-task command)"
	@echo "  make bench            release-mode reindex/query bench"
	@echo "  make footprint        memory footprint over a source tree (TARGET=…)"
	@echo "  make clean            remove build artifacts"

setup:
	shards install

# Fast unit specs. Mirrors the old split: integration (real subprocess) is
# separate so the common loop stays sub-second.
test:
	crystal spec spec/mystral spec/mystral_cli

# End-to-end specs that drive the production compile processor (shells out to
# `crystal build --no-codegen`; needs `crystal` on PATH). No compiler module is
# linked, so it's nearly as fast as the unit specs — kept separate only for the
# real subprocess.
test-integration:
	crystal spec spec/integration

test-all: test test-integration

build:
	$(MAKE) test && shards build

release:
	$(MAKE) test && shards build --release

# macOS: NEVER `cp -f` over the live binary — adhoc signatures are inode-cached
# and the kernel SIGKILLs the running process (exit 137, EPIPE, no logs). rm
# then cp gives a fresh inode.
copy:
	rm -f /usr/local/bin/mystral
	cp ./bin/mystral /usr/local/bin/mystral

# The end-of-task command (not `make build`, which is a debug binary the editor
# won't read): test + release build + install.
deploy:
	$(MAKE) release && $(MAKE) copy

bench:
	crystal run --release --no-debug bench/reindex_bench.cr

# make footprint TARGET=/path/to/crystal/src   (defaults to this repo)
footprint:
	crystal run --release --no-debug bench/footprint.cr -- $(or $(TARGET),$(CURDIR))

clean:
	rm -rf bin/mystral bin/mystral.dwarf
