require "../server_context"
require "../resolve/text_scanner"
require "../lsp/types"

module Mystral
  # textDocument/documentHighlight — highlights every occurrence of the
  # cursor's identifier in the CURRENT file. Pure text scan: no workspace
  # lookup, no scope resolution. The editor paints subtle backgrounds on
  # matching tokens as the user navigates, so cheap + same-file-only is the
  # whole point. Identifier extraction mirrors word_at, so "highlight the same
  # identifier" matches what hover/definition consider the identifier here.
  class DocumentHighlightProvider
    def initialize(@context : ServerContext)
    end

    def document_highlight(params : JSON::Any?) : Array(LSP::DocumentHighlight)?
      return nil unless params
      uri = params["textDocument"]["uri"].as_s
      pos = params["position"]
      line = pos["line"].as_i
      character = pos["character"].as_i

      text = @context.documents.text_for(uri)
      return nil unless text
      scanner = TextScanner.new(text)
      target = scanner.word_at(line, character)
      return nil unless target

      highlights = [] of LSP::DocumentHighlight
      scanner.each_identifier_match(target) do |ln, start_col, end_col|
        highlights << LSP::DocumentHighlight.new(
          LSP::Range.new(
            LSP::Position.new(ln, start_col),
            LSP::Position.new(ln, end_col),
          )
        )
      end
      return nil if highlights.empty?
      highlights
    end
  end
end
