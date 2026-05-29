[![Version](https://img.shields.io/github/v/tag/AristoRap/mystral?label=version)](https://github.com/AristoRap/mystral/tags)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Crystal](https://img.shields.io/badge/crystal-%3E%3D%201.20.2-black?logo=crystal)](https://crystal-lang.org)

# Mystral

A blazing-fast, index-based Crystal language server, single binary over stdio.

Answers from the parsed AST + an in-memory index. Compiler-derived facts (type errors,
deeper inference) run in the background, cached and hash-keyed to the buffer.

## No guessing

Sure or nothing — no plausible lies. A cached fact is dropped the moment it might be stale.

Hover returns the first thing it can stand behind, in order:

1. cached compiler fact (only if it still matches the buffer)
2. `@ivar` / `@@cvar` declared type (exclusive)
3. parameter
4. block parameter (`|x|`)
5. local, typed from its assignment
6. `getter?` / `getter!` accessor
7. shared resolver: receiver-aware name lookup (scope, inheritance, includes)
8. unprovable but looks like a local → background compile, brief `resolving…`
9. nothing

(2–6 are the bare-identifier path; a receiver jumps to 7.)

## Gaps

AST-first, so coverage is incomplete (never wrong, just partial): inference covers
literals / `.new` / typed params / explicit returns — flow, generics, macros wait on a
background fact. Completion only after `.` / `::`. Type errors lag a debounced compile.
Type-definition and implementation are name + ancestry based.

## Speed

Base M1 Air (8 GB), Crystal 1.20.2.

| Project |    LOC | Own symbols | Total indexed | Index time |   RSS |
| ------- | -----: | ----------: | ------------: | ---------: | ----: |
| mystral |  9,257 |         876 |        50,063 |     638 ms | 62 MB |
| lune    | 19,485 |       2,486 |        52,663 |     407 ms | 69 MB |
| mint    | 33,760 |       5,099 |        56,874 |     566 ms | 69 MB |

Total indexed / index time / RSS include the Crystal stdlib + shards loaded on startup
(~49k symbols, the same for every project), so they barely move with project size — the
"own symbols" column is the project's actual contribution. Hot path: symbol lookup ~10 ns,
single-file reparse ~55 µs–0.5 ms. `make bench` / `make footprint` to reproduce.

## Run

```sh
make release
./bin/mystral             # LSP on stdio
./bin/mystral check f.cr  # inspect one file
```

Editor config: [editors/](editors/) — [VSCode](editors/vscode/),
[Neovim](editors/neovim/), [Helix](editors/helix/).

## Dev

`make setup` / `test` / `build` / `bench`; `make help` for the rest.

MIT — see [LICENSE](LICENSE).
