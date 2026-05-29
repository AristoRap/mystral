require "./lsp/types"
require "./transport"

module Mystral
  # Per-URI merge of the two diagnostic sources that target the same file. LSP
  # defines publishDiagnostics as REPLACING the URI's set (not appending), so
  # the two producers clobber each other if each writes the wire directly:
  #   - the parser runs on every didOpen/didChange (main fiber) → syntax errors
  #   - the subprocess compiler runs after the edit settles → semantic errors
  # A valid-syntax keystroke makes the parser emit [], erasing a still-true
  # compile squiggle until the next compile — the editor lying about state.
  #
  # This holds both halves keyed by URI and always publishes their union, so
  # updating one source preserves the other.
  #
  # Concurrency: set_parse runs on the main fiber, set_compile on the worker
  # fiber (which only yields at the child compile's Process.run, never mid-
  # method here). Single-fiber-at-a-time map access — no lock.
  class Diagnostics
    EMPTY = [] of LSP::Diagnostic

    def initialize(@transport : Transport)
      @parse = {} of String => Array(LSP::Diagnostic)
      @compile = {} of String => Array(LSP::Diagnostic)
    end

    # Syntax half (parser, every didOpen/didChange). Replaces this URI's parse
    # set and republishes the union with the compile half.
    def set_parse(uri : String, diagnostics : Array(LSP::Diagnostic)) : Nil
      @parse[uri] = diagnostics
      publish(uri)
    end

    # Semantic half (subprocess compile, after settle). Replaces this URI's
    # compile set and republishes the union with the parse half — a didChange
    # in between can't have erased it, and this won't erase the parser's.
    def set_compile(uri : String, diagnostics : Array(LSP::Diagnostic)) : Nil
      @compile[uri] = diagnostics
      publish(uri)
    end

    private def publish(uri : String) : Nil
      merged = (@parse[uri]? || EMPTY) + (@compile[uri]? || EMPTY)
      @transport.write({
        jsonrpc: "2.0",
        method:  "textDocument/publishDiagnostics",
        params:  {uri: uri, diagnostics: merged},
      })
    end
  end
end
