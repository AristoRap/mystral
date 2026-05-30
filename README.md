[![Version](https://img.shields.io/github/v/tag/AristoRap/mystral?label=version)](https://github.com/AristoRap/mystral/tags)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Crystal](https://img.shields.io/badge/crystal-%3E%3D%201.20.2-black?logo=crystal)](https://crystal-lang.org)

# Mystral

A blazing-fast, index-based Crystal language server, single binary over stdio.

Mystral is an experiment in how far the parser alone can take an editor. Hover, go-to,
completion and friends answer from a parser-built index — no compiler on the request
path, so they're instant (sub-millisecond). Types are AST-shaped: exact where the syntax
spells them out (`x = Foo.new`, a param's `: T`, a declared ivar), best-effort otherwise,
and **nothing rather than a guess**. The compiler runs only in the background — for
diagnostics and richer facts — never on a keystroke.

## How fast

Measured on real projects (base M1 MacBook Air, 8 GB, Crystal 1.20.2; `make bench` to
reproduce — see [bench/baselines/](bench/baselines/)):

| Project |    LOC | Own symbols | Total indexed | Index time |   RSS |
| ------- | -----: | ----------: | ------------: | ---------: | ----: |
| mystral |  9,257 |         876 |        50,063 |     638 ms | 62 MB |
| lune    | 19,485 |       2,486 |        52,663 |     407 ms | 69 MB |
| mint    | 33,760 |       5,099 |        56,874 |     566 ms | 69 MB |

Total indexed / time / RSS include the stdlib + shards loaded at startup (~49k symbols,
the same for every project), so they barely move with project size. On the hot path a
symbol lookup is ~10 ns and a single-file reparse ~55 µs–0.5 ms — a hover lands in well
under a millisecond. The one slow thing, a full `crystal build --no-codegen` (~3 s), runs
debounced in a subprocess and is skipped when reachable content hasn't changed.

## What works

- Hover, go-to-definition / type-definition / implementation, completion, references,
  signature help, document/workspace symbols, document highlight, formatting.
- Hover shows doc comments, param types, instance/class vars, block args, locals,
  `getter?`/`getter!`, and annotations (`@[JSON::Field]`, …).
- Indexes your workspace plus everything on `crystal env CRYSTAL_PATH` (stdlib, `lib/`
  shards) at startup — hovering into a dependency is as fast as your own code.

Type-definition and implementation are name- and ancestry-based. Not yet: rename, inlay
hints, code actions.

## Diagnostics

- **Syntax** — instant, every keystroke, no shellout.
- **Semantic** — on a settled edit (and at startup), a debounced `crystal build
--no-codegen` catches undefined methods, type mismatches, wrong arity. Content-hash
  cached; one compile refreshes every open file. Never a stale or false squiggle. If
  requires don't resolve, you get a red line on the offending `shard.yml` dependency and a
  "run shards install?" toast, not noise on require lines.
- **Reachability** — Crystal only type-checks code it instantiates, so a method in a class
  nothing constructs (or any uncalled method) is never analyzed — a typo there raises no
  squiggle until something exercises it. This is the compiler's model, shared by every
  compiler-backed Crystal tool, not a Mystral limit; we surface the compiler's truth rather
  than guess one from the index.

## A different bet

The established tools — [crystalline](https://github.com/elbywan/crystalline) and
[vscode-crystal-lang](https://github.com/crystal-lang-tools/vscode-crystal-lang) — drive
navigation through the real compiler. That's the exact, correct path; Mystral isn't trying
to replace it. It bets that most editing doesn't need type inference, and keeps the
compiler off the request path for parser-speed answers. What genuinely needs the type
system — generic instantiation, `is_a?` narrowing, cross-module dispatch, macro expansion
across files — Mystral approximates or sits out. Shrinking that list is the work: a
background side-index reaps `crystal tool` output off the hot path, content-hash keyed and
served on the next hover at parser speed.

## Install

```sh
make deploy   # specs + release build + install to /usr/local/bin/mystral
```

(macOS: the Makefile `rm -f`s before `cp` — adhoc-signed binaries get SIGKILLed if
overwritten in place; don't swap it for a plain `cp`.)

- **VSCode** — `cd editors/vscode && npm install && npx vsce package && code
--install-extension mystral-vscode-*.vsix`. Logs at `/tmp/mystral.log`
  (`MYSTRAL_DEBUG=1` for verbose).
- **Helix / Neovim** — merge [editors/helix/languages.toml](editors/helix/languages.toml)
  or drop in [editors/neovim/mystral.lua](editors/neovim/mystral.lua). Any generic LSP
  client works — `mystral` with no subcommand serves over stdio.
- **CLI** — `mystral check FILE.cr` prints every symbol the indexer sees.

Tests: `make test` (unit), `make test-integration` (shells out to `crystal`); `make help`
for the rest.

## Acknowledgements

The VSCode extension ships the Crystal TextMate grammar from
[vscode-crystal-lang](https://github.com/crystal-lang-tools/vscode-crystal-lang). Thanks to
it and [crystalline](https://github.com/elbywan/crystalline) for charting the
compiler-backed path.

## License

MIT — see [LICENSE](LICENSE).
