# Mystral — VSCode dev extension

A tiny VSCode language-client extension that wires the local `mystral`
binary in as the Crystal language server. No marketplace install — you
run it via VSCode's Extension Development Host (the F5 workflow).

## What you'll see

Once it's running, opening any `.cr` file gives you:

- **Diagnostics** — red squiggles on every syntax error, cleared as soon
  as you fix them.
- **Hover** — cursor on a class/module/def name shows the signature in a
  fenced `crystal` code block, the doc comment (if any), and the source
  location.
- **Outline / Document Symbol** — VSCode's outline pane lists everything
  Mystral indexed.
- **Workspace Symbol** (`Ctrl/Cmd+T`) — fuzzy search across every symbol
  in every open file.
- **Go to Definition** (`F12`) — jumps to matching name(s).

## One-time setup

```sh
# Build the Mystral binary in the repo root
cd ../../
make release

# Install the extension's dependencies
cd editors/vscode
npm install
```

## Run it

1. Open this `editors/vscode/` folder in VSCode (`code editors/vscode`).
2. Press **`F5`** — a second VSCode window opens labeled
   "Extension Development Host" with the extension loaded.
3. In that window, open any `.cr` file (try this repo's own
   `src/mystral/index.cr`).
4. The "Mystral" output channel (`View → Output → Mystral`) shows server
   traffic. Set `mystral.trace.server` to `messages` or `verbose` in
   settings to see every LSP frame.

## Where the binary path comes from

The extension defaults to `<this-extension>/../../bin/mystral`, so it
finds the binary built by `make release` when the extension lives at
`editors/vscode/` inside the Mystral repo (the layout this README
assumes).

Override with the `mystral.binaryPath` setting (absolute path) if you've
installed Mystral somewhere else.

## Why the dev host disables other extensions

`.vscode/launch.json` passes `--disable-extensions` to the Extension
Development Host. That means: in that window, *only* Mystral is loaded
— no Crystal Lang Tools, no other LSP fighting ours for the same
`.cr` document. Pure signal while we test.

We bundle the Crystal TextMate grammar (MIT, from
crystal-lang-tools/vscode-crystal-lang — see
`syntaxes/LICENSE-vscode-crystal-lang.txt`) so you don't lose syntax
highlighting in the dev host. The bundled grammar is the only thing
about that other extension we use; the LSP server is 100% ours.

## Troubleshooting

- **"Mystral binary not found"** — `make release` in the repo root,
  or set `mystral.binaryPath` explicitly.
- **No diagnostics or hover** — check the "Mystral" output channel. If
  it's empty, the LSP handshake never happened; check that the file is
  recognized as `crystal` language (bottom-right of the VSCode status bar).
- **Stale results after edits** — `Developer: Reload Window` in the
  Extension Development Host applies any extension changes; the LSP
  server itself reindexes on every `didChange` so editor-side state
  shouldn't go stale.
