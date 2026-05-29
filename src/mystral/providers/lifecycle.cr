require "compiler/crystal/syntax"
require "../server_context"
require "../lsp/types"
require "../lsp/protocol"
require "./enrichment_requester"

module Mystral
  # Lifecycle: the `initialize` response (capabilities + serverInfo) and the
  # document-buffer notifications (didOpen / didChange / didClose) that keep
  # the Documents store and the symbol Index in sync with the editor.
  #
  # Diagnostics publishing piggy-backs on these notifications in a later
  # increment; for now open/change just refresh the buffer + index.
  class LifecycleProvider
    def initialize(@context : ServerContext, @enrichment : EnrichmentRequester)
    end

    # The capability set the editor reads to decide which requests to send us,
    # plus serverInfo. We advertise a capability ONLY once the provider backing
    # it lands (advertise only when our output is a strict superset of the
    # editor's built-in), so this grows per increment. `foldingRangeProvider`
    # is deliberately never advertised — def/class folds would replace and
    # degrade VSCode's richer do/end + if/else + arg-list indentation folds.
    def initialize_result
      {
        capabilities: {
          textDocumentSync:        1, # Full document sync (TextDocumentSyncKind.Full)
          documentSymbolProvider:    true,
          workspaceSymbolProvider:   true,
          documentHighlightProvider: true,
          referencesProvider:        true,
          definitionProvider:        true,
          hoverProvider:             true,
          completionProvider:         {triggerCharacters: [".", ":"]},
          signatureHelpProvider:      {triggerCharacters: ["(", ","]},
          documentFormattingProvider: true,
        },
        serverInfo: {
          name:    "mystral",
          version: Mystral::VERSION,
        },
      }
    end

    def did_open(params : JSON::Any?) : Nil
      return unless params
      doc = params["textDocument"]
      uri = doc["uri"].as_s
      text = doc["text"].as_s
      @context.documents.set(uri, text)
      publish_parse(uri, text, @context.index.reindex(uri, text))
    end

    def did_change(params : JSON::Any?) : Nil
      return unless params
      uri = params["textDocument"]["uri"].as_s
      # With Full sync (TextDocumentSyncKind=1) the last change carries the
      # complete document text.
      changes = params["contentChanges"].as_a
      return if changes.empty?
      text = changes.last["text"].as_s
      old_version = @context.documents.version(uri)
      @context.documents.set(uri, text)
      # A content change invalidates this buffer's enriched facts (version-
      # gated reads evict them); drop the enrichment dedup keys too so the next
      # thin hover re-fires rather than staying stuck at "resolving…".
      @enrichment.forget(uri) if @context.documents.version(uri) != old_version
      publish_parse(uri, text, @context.index.reindex(uri, text))
      # Debounced background semantic check. Fast path: records last-changed
      # time + adds to a Set, no I/O.
      @context.compile_worker.enqueue(uri, text)
    end

    def did_close(params : JSON::Any?) : Nil
      return unless params
      uri = params["textDocument"]["uri"].as_s
      # Drop the live buffer only — the index keeps the file's symbols (it's
      # still on disk; workspace knowledge outlives a tab). See Documents#close.
      @context.documents.close(uri)
      # Release the closed buffer's compile-reaped facts + enrichment keys
      # (buffer-scoped, bounded RAM).
      @context.inference.forget(uri)
      @enrichment.forget(uri)
    end

    # Feed the parse half of the per-URI diagnostic merge — NOT the wire
    # directly. An empty list clears the parser's prior syntax error but leaves
    # the compile half intact, so a valid-syntax edit no longer erases a live
    # semantic squiggle (see Diagnostics).
    private def publish_parse(uri : String, text : String, error : ::Crystal::SyntaxException?) : Nil
      parse = error ? [diagnostic_for(text, error)] : [] of LSP::Diagnostic
      @context.diagnostics.set_parse(uri, parse)
    end

    private def diagnostic_for(text : String, error : ::Crystal::SyntaxException) : LSP::Diagnostic
      # Crystal reports 1-indexed line/column; LSP is 0-indexed. Clamp at 0 for
      # the rare pre-source position the parser reports as 0.
      line = (error.line_number - 1).clamp(0, Int32::MAX)
      col = (error.column_number - 1).clamp(0, Int32::MAX)
      end_col = col + (error.size || 1)
      LSP::Diagnostic.new(
        LSP::Range.new(LSP::Position.new(line, col), LSP::Position.new(line, end_col)),
        LSP::DiagnosticSeverity::ERROR,
        "mystral",
        error.message || "syntax error",
      )
    end
  end
end
