require "json"

module Mystral
  # LSP wire-type records. Each knows how to serialize itself as a JSON object
  # matching the protocol; the Crystal-side `record` shape gives pattern-
  # friendly construction at the call sites.
  #
  # These live in their own module (not inside a handler) because they're
  # protocol shapes — every provider that builds a response consumes them.
  # Records are added here as the increment that needs them lands; we don't
  # carry wire shapes for features that don't exist yet.
  module LSP
    # 0-indexed (LSP convention) line + character offset within a document.
    record Position, line : Int32, character : Int32 do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "line", line
          json.field "character", character
        end
      end
    end

    record Range, start : Position, finish : Position do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "start", start
          json.field "end", finish
        end
      end
    end

    record Location, uri : String, range : Range do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "uri", uri
          json.field "range", range
        end
      end
    end

    # A flat symbol record for documentSymbol / workspace/symbol responses.
    # `kind` is an LSP::SymbolKind value; `location.range` spans the symbol's
    # full body for documentSymbol (so breadcrumbs/sticky-scroll know which
    # symbol the cursor is inside).
    record SymbolInformation, name : String, kind : Int32, location : Location do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "name", name
          json.field "kind", kind
          json.field "location", location
        end
      end
    end

    record MarkupContent, kind : String, value : String do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "kind", kind
          json.field "value", value
        end
      end
    end

    record Diagnostic, range : Range, severity : Int32, source : String, message : String do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "range", range
          json.field "severity", severity
          json.field "source", source
          json.field "message", message
        end
      end
    end
  end
end
