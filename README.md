# Mystral

A blazing-fast language server for [Crystal](https://crystal-lang.org/), shipped as a
single binary that talks LSP over stdio.

The idea is simple: keep the editor responsive. Mystral answers hover, go-to-definition,
outline, and the rest straight from a parser and an in-memory symbol index, so they come
back in milliseconds instead of seconds. Anything that genuinely needs the Crystal
compiler (semantic diagnostics, type enrichment) runs on a background worker and never
blocks what you're typing.

It's an experiment in a different approach to Crystal tooling — not a replacement. Just trying out what "fast by default"
feels like.

## What you get

- **Hover** — signature, doc comment, and source location for the thing under your cursor
- **Go to Definition** — jump to where a name is defined
- **Diagnostics** — syntax errors as you type, plus real compiler errors once an edit settles
- **Outline & Workspace Symbols** — the document outline and fuzzy search across symbols
- **Completion, Signature Help, References, Document Highlight, Formatting**

## Try it

You'll need Crystal (`>= 1.20.2`) installed.

```sh
# build the binary
make release

# it just runs the language server on stdio
./bin/mystral

# or poke at a single file without an editor
./bin/mystral check path/to/file.cr
```

## Is it actually fast?

Speed is the whole point, so it gets measured, not hand-waved. Run them yourself with
`make bench` and `make footprint`, and save a baseline before any perf experiment.

The numbers below come from a **base M1 MacBook Air (8-core, 8 GB RAM), macOS 26.5,
Crystal 1.20.2** — deliberately a modest machine, not a maxed-out workstation. The M1 is
plenty quick, so if you're on anything at least that fast you should see the same
snappiness.

**Indexing a whole project** — your code _plus_ stdlib and every shard, i.e. everything
the server loads on startup:

| Project | Symbols | Index time | Memory (RSS) |
| ------- | ------: | ---------: | -----------: |
| lune    |  52,663 |     407 ms |       ~65 MB |
| mint    |  56,874 |     566 ms |       ~66 MB |
| mystral |  50,063 |     638 ms |       ~59 MB |

So ~50–57k symbols indexed in well under a second, landing around 1.2 KB/symbol (the
symbol records are packed inline as structs — no per-entry heap object).

**The hot path** — what runs between your cursor and an answer:

- symbol lookup (the side-index read): **~0.01 µs**, i.e. roughly 10ns — it's a plain
  in-RAM hash, not a database
- re-parsing a single file on edit: **~55 µs** small file, **~0.5 ms** for a 640-line one
- cold workspace scan: **~0.5 ms/file**

No compiler ever touches that path. The semantic stuff (real type errors, enrichment)
runs on a background worker and never blocks what you're typing.

## Editors

Setup notes for each editor live under [`editors/`](editors/):

- [VSCode](editors/vscode/) — a small dev extension you run via the Extension Development Host (F5)
- [Neovim](editors/neovim/)
- [Helix](editors/helix/)

## Development

```sh
make setup   # install dependencies
make test    # run the specs
make build   # debug build
make bench    # benchmarks
```

Run `make help` to see every target.

## License

MIT — see [LICENSE](LICENSE).
