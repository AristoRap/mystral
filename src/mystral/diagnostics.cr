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
  # This holds both halves keyed by URI. With clean syntax it publishes the
  # compile half; with a LIVE syntax error it publishes the parse half ALONE.
  # The parser owns syntax-error location: a file that won't parse can't have
  # trustworthy semantics (the background compile bailed at parse), so the
  # compiler only ever offers a duplicate of the parser's squiggle or a
  # macro-laundered pointer at the wrong site — the parser's precise, instant
  # location is the truth. The two halves never coexist on the wire, because
  # the parse half is non-empty iff there is a syntax error.
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
    # set and republishes. A non-empty set (a live syntax error) also drops the
    # compile half: those semantics were computed against now-unparseable source
    # and must not re-surface when the syntax is fixed before the next compile.
    def set_parse(uri : String, diagnostics : Array(LSP::Diagnostic)) : Nil
      @parse[uri] = diagnostics
      @compile[uri] = EMPTY unless diagnostics.empty?
      publish(uri)
    end

    # Semantic half (subprocess compile, after settle). While the parser reports
    # a syntax error for this URI the compile saw un-parseable source, so its
    # verdict is ignored outright — the parse half is authoritative and the
    # displayed set hasn't changed, so there's nothing to republish.
    def set_compile(uri : String, diagnostics : Array(LSP::Diagnostic)) : Nil
      return unless (@parse[uri]? || EMPTY).empty?
      @compile[uri] = diagnostics
      publish(uri)
    end

    private def publish(uri : String) : Nil
      parse = @parse[uri]? || EMPTY
      shown = parse.empty? ? (@compile[uri]? || EMPTY) : parse
      @transport.write({
        jsonrpc: "2.0",
        method:  "textDocument/publishDiagnostics",
        params:  {uri: uri, diagnostics: shown},
      })
    end
  end
end
