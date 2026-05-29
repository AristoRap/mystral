import path from "node:path";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import * as vscode from "vscode";
import { LanguageClient } from "vscode-languageclient/node.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let client;

function resolveBinaryPath() {
  const configured = vscode.workspace
    .getConfiguration("mystral")
    .get("binaryPath");
  if (configured && configured.length > 0) {
    return configured;
  }
  // Dev path: <repo>/bin/mystral when the extension lives at
  // <repo>/editors/vscode (F5 / Extension Development Host).
  const dev = path.resolve(__dirname, "..", "..", "bin", "mystral");
  if (fs.existsSync(dev)) return dev;
  // Installed path: prefer the canonical install location (`make
  // deploy` writes here) over a $PATH scan, since user dirs like
  // ~/.local/bin sit ahead of /usr/local/bin and a stale copy there
  // would silently shadow every subsequent rebuild. The setting still
  // wins above for anything bespoke.
  if (fs.existsSync("/usr/local/bin/mystral")) return "/usr/local/bin/mystral";
  const onPath = findOnPath("mystral");
  if (onPath) return onPath;
  return "/usr/local/bin/mystral";
}

function findOnPath(name) {
  const dirs = (process.env.PATH || "").split(path.delimiter);
  for (const dir of dirs) {
    if (!dir) continue;
    const candidate = path.join(dir, name);
    try {
      if (fs.existsSync(candidate)) return candidate;
    } catch {}
  }
  return null;
}

export function activate(context) {
  const binaryPath = resolveBinaryPath();

  // Dedicated channel for our own lifecycle logging, separate from the
  // LSP client's "Mystral" channel — survives even if the LSP never starts.
  const log = vscode.window.createOutputChannel("Mystral (extension)");
  context.subscriptions.push(log);

  log.appendLine(`[activate] resolving binary: ${binaryPath}`);

  if (!fs.existsSync(binaryPath)) {
    const msg = `Mystral binary not found at ${binaryPath}. Build it with \`make release\` in the repo root, or set the \`mystral.binaryPath\` setting.`;
    log.appendLine(`[activate] ABORT: ${msg}`);
    log.show(true);
    vscode.window.showErrorMessage(msg);
    return;
  }

  const debug = vscode.workspace.getConfiguration("mystral").get("debug") === true;
  log.appendLine(`[activate] mystral.debug = ${debug}`);

  // Dir names to leave out of the symbol index, forwarded to the server as
  // an initializationOption. Coerce to an array of non-empty strings so a
  // malformed setting can't break the handshake.
  const excludeDirs = (
    vscode.workspace.getConfiguration("mystral").get("excludeDirs") || []
  ).filter((d) => typeof d === "string" && d.length > 0);
  log.appendLine(`[activate] mystral.excludeDirs = ${JSON.stringify(excludeDirs)}`);

  // For command-based servers, vscode-languageclient defaults to stdio
  // transport (see node/main.js ~L425). Explicit `transport` is only
  // needed for runtime/module-based servers.
  const serverOptions = {
    command: binaryPath,
    options: {
      env: { ...process.env, ...(debug ? { MYSTRAL_DEBUG: "1" } : {}) },
    },
  };

  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "crystal" }],
    outputChannelName: "Mystral",
    // Always reveal the LSP channel so you can see the handshake.
    revealOutputChannelOn: 0, // RevealOutputChannelOn.Info
    initializationOptions: { excludeDirs },
  };

  client = new LanguageClient(
    "mystral",
    "Mystral (Crystal LSP)",
    serverOptions,
    clientOptions,
  );

  client
    .start()
    .then(() => {
      log.appendLine(`[activate] LanguageClient started — server is live.`);
      vscode.window.showInformationMessage(
        `Mystral connected (binary: ${binaryPath}). Open a .cr file to see it work.`,
      );
    })
    .catch((err) => {
      log.appendLine(
        `[activate] start() FAILED: ${err && err.stack ? err.stack : err}`,
      );
      log.show(true);
      vscode.window.showErrorMessage(
        `Mystral failed to start: ${err && err.message ? err.message : err}`,
      );
    });

  context.subscriptions.push({ dispose: () => client && client.stop() });
}

export function deactivate() {
  return client ? client.stop() : undefined;
}
