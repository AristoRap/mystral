module Mystral
  module LSP
    # LSP `SymbolKind` enum values — the subset we actually emit. The editor
    # uses these to pick the icon shown next to a symbol in the outline,
    # breadcrumbs, and workspace-symbol search.
    module SymbolKind
      MODULE   =  2
      CLASS    =  5
      METHOD   =  6
      ENUM     = 10
      FUNCTION = 12
      CONSTANT = 14
      STRUCT   = 23
    end

    # LSP `DiagnosticSeverity` enum values. Defined here for the diagnostics
    # increment; not yet consumed.
    module DiagnosticSeverity
      ERROR   = 1
      WARNING = 2
      INFO    = 3
      HINT    = 4
    end
  end
end
