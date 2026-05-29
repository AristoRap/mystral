require "../server_context"
require "../resolve/text_scanner"
require "../lsp/types"
require "../lsp/entry_locations"

module Mystral
  # textDocument/definition — jump to where the symbol at the cursor is
  # defined. Resolves the identifier (with any receiver to its left) through
  # the shared Resolver, then maps each match to its name location. Returns
  # every match when a name is ambiguous (the editor offers a picker).
  class DefinitionProvider
    def initialize(@context : ServerContext)
    end

    def definition(params : JSON::Any?) : Array(LSP::Location)?
      return nil unless params
      uri = params["textDocument"]["uri"].as_s
      pos = params["position"]
      line = pos["line"].as_i
      character = pos["character"].as_i

      text = @context.documents.text_for(uri)
      return nil unless text
      scanner = TextScanner.new(text)
      name = scanner.word_at(line, character)
      return nil unless name

      receiver = scanner.receiver_at(line, character)
      matches = @context.resolver.matches_at(name, uri, receiver, line)
      locations = matches.map { |s| LSP::EntryLocations.name_range(s) }
      return nil if locations.empty?
      locations
    end
  end
end
