require "../server_context"
require "../resolve/text_scanner"
require "../lsp/types"

module Mystral
  # textDocument/references — workspace-wide name lookup. The cursor sits on
  # `Foo` or `bar`; we return every occurrence of that exact identifier across
  # the workspace.
  #
  # ALWAYS scans the full workspace, including bare lowercase names. Hover's
  # same-file noise suppression deliberately does NOT apply: references show
  # in a side panel with file paths visible. Restricting bare names to the
  # current file would make it useless for finding callers of a private helper.
  # The panel handles a noisy name like `path` fine — that's what it's for.
  #
  # `context.includeDeclaration` (LSP-standard) controls whether the cursor's
  # own position is included; honored by filtering after the scan.
  class ReferencesProvider
    def initialize(@context : ServerContext)
    end

    def references(params : JSON::Any?) : Array(LSP::Location)?
      return nil unless params
      uri = params["textDocument"]["uri"].as_s
      pos = params["position"]
      cursor_line = pos["line"].as_i
      cursor_char = pos["character"].as_i
      include_declaration = params["context"]?.try(&.["includeDeclaration"]?.try(&.as_bool)) != false

      text = @context.documents.text_for(uri)
      return nil unless text
      target = TextScanner.new(text).word_at(cursor_line, cursor_char)
      return nil unless target

      locations = [] of LSP::Location
      scanned = @context.index.uris
      scanned.each do |scan_uri|
        scan_text = @context.documents.text_for(scan_uri)
        next unless scan_text
        collect_matches(scan_text, target, scan_uri, locations) do |ln, start_col, end_col|
          drop_declaration?(include_declaration, scan_uri == uri, ln, start_col, end_col, cursor_line, cursor_char)
        end
      end

      # If the cursor's file isn't indexed yet (a brand-new open buffer), still
      # include its in-file hits so the user sees them.
      unless scanned.includes?(uri)
        collect_matches(text, target, uri, locations) do |ln, start_col, end_col|
          drop_declaration?(include_declaration, true, ln, start_col, end_col, cursor_line, cursor_char)
        end
      end

      return nil if locations.empty?
      locations
    end

    private def collect_matches(text : String, target : String, uri : String,
                                locations : Array(LSP::Location),
                                & : Int32, Int32, Int32 -> Bool) : Nil
      TextScanner.new(text).each_identifier_match(target) do |ln, start_col, end_col|
        next if yield ln, start_col, end_col # skip when the block says drop
        locations << LSP::Location.new(
          uri,
          LSP::Range.new(
            LSP::Position.new(ln, start_col),
            LSP::Position.new(ln, end_col),
          )
        )
      end
    end

    private def drop_declaration?(include_declaration : Bool, same_file : Bool,
                                  ln : Int32, start_col : Int32, end_col : Int32,
                                  cursor_line : Int32, cursor_char : Int32) : Bool
      return false if include_declaration
      same_file && ln == cursor_line && start_col <= cursor_char && cursor_char <= end_col
    end
  end
end
