# Mystral — Neovim

Wire the `mystral` binary in as the Crystal language server. The
snippet in [mystral.lua](mystral.lua) covers both Neovim 0.11+
(native `vim.lsp.config`) and older Neovim with `nvim-lspconfig`.

## Install

1. Build + install the binary so `mystral` is on your PATH:
   ```sh
   make deploy   # builds release + copies to /usr/local/bin/mystral
   ```

2. Copy the relevant block from [mystral.lua](mystral.lua) into your
   Neovim config (e.g. `~/.config/nvim/init.lua`, or a separate
   `lua/plugins/mystral.lua`).

3. Make sure Crystal filetype detection is on — most Neovim setups
   recognise `.cr` files out of the box. If yours doesn't:
   ```lua
   vim.filetype.add({ extension = { cr = "crystal" } })
   ```

4. Restart Neovim, open a `.cr` file. `:LspInfo` should list `mystral`
   as attached. Use `K` for hover, `gd` for definition, `:Telescope
   lsp_document_symbols` (or your equivalent) for outline.

## What works

Everything the LSP advertises in `initialize` — hover, definition,
references, document highlight, document/workspace symbol, completion,
signature help, formatting. Diagnostics flow through Neovim's default
diagnostic UI (`:lua vim.diagnostic.config()` to tune).

## Troubleshooting

- **`:LspInfo` shows nothing attached**: filetype probably isn't
  `crystal`. Run `:set ft?` in a `.cr` buffer.
- **`mystral` not found**: confirm `which mystral` resolves; if not,
  edit `cmd = { "mystral" }` to an absolute path.
- **No completions / formatting**: confirm the server logged the
  `initialize` request (check `/tmp/mystral.log`). Some Neovim setups
  default `single_file_support = false`; with the snippet's
  `root_markers`/`root_dir`, Mystral indexes the whole workspace once
  it sees a `shard.yml` or `.git` parent.
