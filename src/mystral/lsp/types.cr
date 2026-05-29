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

    # A range to replace plus its replacement text. Used on a CompletionItem
    # to override the default "replace the word at cursor" — e.g. swapping `.`
    # for `::` when a nested type is picked after `Foo.`.
    record TextEdit, range : Range, new_text : String do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "range", range
          json.field "newText", new_text
        end
      end
    end

    # A completion suggestion. `detail` typically holds the signature (shown
    # inline); `documentation` is the doc comment. `additional_text_edits` are
    # applied alongside the primary insertion (the `.`→`::` swap).
    record CompletionItem,
      label : String,
      kind : Int32,
      detail : String? = nil,
      documentation : String? = nil,
      additional_text_edits : Array(TextEdit)? = nil do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "label", label
          json.field "kind", kind
          if d = detail
            json.field "detail", d
          end
          if doc = documentation
            json.field "documentation", doc
          end
          if edits = additional_text_edits
            json.field "additionalTextEdits", edits
          end
        end
      end
    end

    # One parameter inside a signature. We emit the `[start, end]` offset form
    # (VSCode highlights it more reliably than substring-matching the label).
    record ParameterInformation, label : String, offset : Tuple(Int32, Int32)? = nil do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          if off = offset
            json.field "label" do
              json.array do
                json.number off[0]
                json.number off[1]
              end
            end
          else
            json.field "label", label
          end
        end
      end
    end

    # One callable signature: `label` is the full text shown, `parameters` its
    # params, `active_parameter` the index the cursor is currently filling.
    record SignatureInformation,
      label : String,
      parameters : Array(ParameterInformation),
      documentation : String? = nil,
      active_parameter : Int32? = nil do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "label", label
          json.field "parameters", parameters
          if doc = documentation
            json.field "documentation", doc
          end
          if ap = active_parameter
            json.field "activeParameter", ap
          end
        end
      end
    end

    # The full signatureHelp response: the overload set + which one and which
    # parameter within it are active.
    record SignatureHelp,
      signatures : Array(SignatureInformation),
      active_signature : Int32 = 0,
      active_parameter : Int32 = 0 do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "signatures", signatures
          json.field "activeSignature", active_signature
          json.field "activeParameter", active_parameter
        end
      end
    end

    # One foldable region. The editor folds whole lines; we don't use the
    # optional `kind` hint.
    record FoldingRange, start_line : Int32, end_line : Int32 do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "startLine", start_line
          json.field "endLine", end_line
        end
      end
    end

    # One highlight of the cursor's identifier within the current document.
    # We emit kind=1 (Text) explicitly even though it's the spec default —
    # some clients drop highlights without it.
    record DocumentHighlight, range : Range do
      KIND_TEXT = 1

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "range", range
          json.field "kind", KIND_TEXT
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
