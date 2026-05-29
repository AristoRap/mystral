-- Mystral — Neovim LSP config snippet.
--
-- Two variants below. Pick the one matching your Neovim setup:
--   * Neovim 0.11+ (recommended): native vim.lsp.config + vim.lsp.enable.
--   * Older Neovim with nvim-lspconfig: the lspconfig path.

-- ── Native (Neovim 0.11+) ────────────────────────────────────────────
-- Drop this in your init.lua (or any file loaded at startup).
vim.lsp.config("mystral", {
  cmd = { "mystral" },
  filetypes = { "crystal" },
  root_markers = { "shard.yml", ".git" },
})
vim.lsp.enable("mystral")

-- ── nvim-lspconfig (older Neovim) ────────────────────────────────────
-- Uncomment if you're on a Neovim version that doesn't ship native
-- vim.lsp.config:
--
-- local lspconfig = require("lspconfig")
-- local configs   = require("lspconfig.configs")
--
-- if not configs.mystral then
--   configs.mystral = {
--     default_config = {
--       cmd       = { "mystral" },
--       filetypes = { "crystal" },
--       root_dir  = lspconfig.util.root_pattern("shard.yml", ".git"),
--       settings  = {},
--     },
--   }
-- end
--
-- lspconfig.mystral.setup({})
