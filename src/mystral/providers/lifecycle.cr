module Mystral
  # Produces the `initialize` response — the capability set the editor reads
  # to decide which requests to send us, plus serverInfo.
  #
  # We advertise a capability ONLY once the provider backing it lands
  # (hard constraint: advertise a capability only when our output is a strict
  # superset of the editor's built-in), so this set grows per increment.
  # `foldingRangeProvider` is deliberately never advertised — def/class folds
  # would replace and degrade VSCode's richer do/end + if/else + arg-list
  # indentation folds.
  class LifecycleProvider
    def initialize_result
      {
        capabilities: {
          textDocumentSync: 1, # Full document sync (TextDocumentSyncKind.Full)
        },
        serverInfo: {
          name:    "mystral",
          version: Mystral::VERSION,
        },
      }
    end
  end
end
