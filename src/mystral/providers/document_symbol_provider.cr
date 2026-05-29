require "../server_context"
require "../lsp/types"
require "../lsp/protocol"
require "../index/entry"

module Mystral
  # textDocument/documentSymbol (and, from a later increment, workspace/symbol)
  # — the flat symbol list the editor renders in the outline, breadcrumbs,
  # sticky scroll, and Ctrl-Shift-O navigation.
  class DocumentSymbolProvider
    def initialize(@context : ServerContext)
    end

    def document_symbol(params : JSON::Any?) : Array(LSP::SymbolInformation)
      return [] of LSP::SymbolInformation unless params
      uri = params["textDocument"]["uri"].as_s
      @context.index.symbols_in(uri).map { |s| symbol_information_scoped(s) }
    end

    # workspace/symbol — a name-substring search across the whole index. The
    # empty query returns everything (clients fetch all, then filter locally).
    def workspace_symbol(params : JSON::Any?) : Array(LSP::SymbolInformation)
      results = [] of LSP::SymbolInformation
      return results unless params
      query = params["query"]?.try(&.as_s) || ""
      @context.index.each_symbol do |s|
        # `proc` kind: anonymous `->(x : T) {}` literals, indexed so parameter
        # hover can see them — but a symbol search shouldn't surface them.
        next if s.kind == "proc"
        next unless query.empty? || s.name.includes?(query)
        results << LSP::SymbolInformation.new(s.name, symbol_kind(s.kind), location_for(s))
      end
      results
    end

    # documentSymbol wants location.range to span the symbol's FULL body —
    # outline, breadcrumbs, and sticky scroll use it to decide which symbol
    # the cursor is inside. A point-sized range left VSCode thinking the
    # cursor was never "in" any symbol, thrashing decorations. Use end_line
    # when the visitor captured it; fall back to the name range otherwise.
    private def symbol_information_scoped(s : ::Mystral::Entry) : LSP::SymbolInformation
      LSP::SymbolInformation.new(s.name, symbol_kind(s.kind), scope_location_for(s))
    end

    private def scope_location_for(s : ::Mystral::Entry) : LSP::Location
      if end_line = s.end_line
        LSP::Location.new(
          s.uri,
          LSP::Range.new(
            LSP::Position.new(s.line, 0),
            LSP::Position.new(end_line, 0),
          ),
        )
      else
        location_for(s)
      end
    end

    private def location_for(s : ::Mystral::Entry) : LSP::Location
      end_char = s.column + s.name.size
      LSP::Location.new(
        s.uri,
        LSP::Range.new(
          LSP::Position.new(s.line, s.column),
          LSP::Position.new(s.line, end_char),
        ),
      )
    end

    private def symbol_kind(kind : String) : Int32
      case kind
      when "class"  then LSP::SymbolKind::CLASS
      when "struct" then LSP::SymbolKind::STRUCT
      when "module" then LSP::SymbolKind::MODULE
      when "enum"   then LSP::SymbolKind::ENUM
      when "def"    then LSP::SymbolKind::METHOD
      when "macro"  then LSP::SymbolKind::FUNCTION
      when "const"  then LSP::SymbolKind::CONSTANT
      when "lib"    then LSP::SymbolKind::MODULE   # closest shape for a C-binding namespace
      when "fun"    then LSP::SymbolKind::FUNCTION
      when "alias"  then LSP::SymbolKind::CLASS    # no TypeAlias kind; class is closest
      when "union"  then LSP::SymbolKind::STRUCT   # C union — render like a struct
      else               LSP::SymbolKind::FUNCTION
      end
    end
  end
end
