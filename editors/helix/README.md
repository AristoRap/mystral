# Mystral — Helix

Helix ships with built-in Crystal syntax + tree-sitter support; this
just points its LSP at the `mystral` binary.

## Install

1. Build + install the binary so `mystral` is on your PATH:
   ```sh
   make deploy   # builds release + copies to /usr/local/bin/mystral
   ```
   Or skip `make deploy` and point Helix at an explicit path via
   `command = "/full/path/to/mystral"` below.

2. Merge [languages.toml](languages.toml) into
   `~/.config/helix/languages.toml`. If the file already has a
   `[[language]]` block for Crystal, just append the `language-servers`
   key — don't duplicate the block.

3. Restart Helix. Open a `.cr` file; hover with `K`, go-to-definition
   with `gd`, document-symbol with `<space>s`, workspace-symbol with
   `<space>S`.

## What works

Everything the LSP advertises in `initialize` — hover, definition,
references, document highlight, document/workspace symbol, completion,
signature help, formatting. Diagnostics show on the line gutter.

## Troubleshooting

- **No server logs**: run `hx --health crystal`; the "Language Servers"
  row should list `mystral`. If it doesn't, the toml didn't load —
  check `~/.config/helix/languages.toml`'s path and syntax.
- **`mystral` not found**: confirm `which mystral` resolves; if not,
  set an absolute `command =` in the language-server block.
- **Stale results**: Helix sends `didChange` on every edit; if you're
  not seeing them reflected, check Mystral's log at `/tmp/mystral.log`.
