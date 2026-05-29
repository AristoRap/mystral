require "./types"
require "../index/entry"

module Mystral
  module LSP
    # Maps an index Entry to LSP Locations. Shared by every provider that
    # returns a symbol's position so the range shapes stay consistent.
    module EntryLocations
      extend self

      # A point-sized range over the symbol's name — for go-to-definition,
      # references, workspaceSymbol.
      def name_range(s : ::Mystral::Entry) : Location
        Location.new(
          s.uri,
          Range.new(
            Position.new(s.line, s.column),
            Position.new(s.line, s.column + s.name.size),
          ),
        )
      end

      # A range spanning the symbol's full body (down to its `end`), for
      # documentSymbol — so breadcrumbs / sticky scroll know which symbol the
      # cursor is inside. Falls back to the name range when no end_line.
      def body_range(s : ::Mystral::Entry) : Location
        if end_line = s.end_line
          Location.new(
            s.uri,
            Range.new(
              Position.new(s.line, 0),
              Position.new(end_line, 0),
            ),
          )
        else
          name_range(s)
        end
      end
    end
  end
end
