require "compiler/crystal/formatter"
require "../server_context"
require "../lsp/types"

module Mystral
  # textDocument/formatting — buffer-wide format via Crystal::Formatter
  # in-process (no `crystal tool format` shell-out), so latency matches the
  # parse path and the no-subprocess-on-the-request-path rule holds (the
  # formatter is not the compiler). On a parse failure we return nil (no
  # edits): VSCode's format-on-save keeps the user's text, no error popup.
  class FormattingProvider
    def initialize(@context : ServerContext)
    end

    def formatting(params : JSON::Any?) : Array(LSP::TextEdit)?
      return nil unless params
      uri = params["textDocument"]["uri"].as_s
      text = @context.documents.text_for(uri)
      return nil unless text

      formatted = ::Crystal::Formatter.format(text)
      return [] of LSP::TextEdit if formatted == text

      # Replace the whole document — VSCode preserves cursor/scroll, and a
      # minimal diff would add a dependency and range-arithmetic risk for
      # little gain.
      lines = text.split('\n')
      end_line = lines.size - 1
      end_col = lines.last.size
      [LSP::TextEdit.new(
        LSP::Range.new(
          LSP::Position.new(0, 0),
          LSP::Position.new(end_line, end_col),
        ),
        formatted,
      )]
    rescue ::Crystal::SyntaxException
      nil
    end
  end
end
