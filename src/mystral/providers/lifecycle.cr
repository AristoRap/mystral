require "../server_context"

module Mystral
  # Lifecycle: the `initialize` response (capabilities + serverInfo) and the
  # document-buffer notifications (didOpen / didChange / didClose) that keep
  # the Documents store and the symbol Index in sync with the editor.
  #
  # Diagnostics publishing piggy-backs on these notifications in a later
  # increment; for now open/change just refresh the buffer + index.
  class LifecycleProvider
    def initialize(@context : ServerContext)
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
      @context.index.reindex(uri, text)
    end

    def did_change(params : JSON::Any?) : Nil
      return unless params
      uri = params["textDocument"]["uri"].as_s
      # With Full sync (TextDocumentSyncKind=1) the last change carries the
      # complete document text.
      changes = params["contentChanges"].as_a
      return if changes.empty?
      text = changes.last["text"].as_s
      @context.documents.set(uri, text)
      @context.index.reindex(uri, text)
    end

    def did_close(params : JSON::Any?) : Nil
      return unless params
      uri = params["textDocument"]["uri"].as_s
      # Drop the live buffer only — the index keeps the file's symbols (it's
      # still on disk; workspace knowledge outlives a tab). See Documents#close.
      @context.documents.close(uri)
    end
  end
end
