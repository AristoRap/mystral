require "../server_context"
require "../resolve/text_scanner"
require "../resolve/type_resolver"
require "../lsp/types"
require "../lsp/entry_locations"

module Mystral
  # textDocument/typeDefinition — jump to the *type* of the expression under the
  # cursor, as distinct from definition (which jumps to the symbol itself): on a
  # `user` reference, definition goes to the `user` declaration; typeDefinition
  # goes to `class User`.
  #
  # Parser-only like every request path: resolve the value reference to a type
  # FQN through the SAME ReceiverResolver that hover and completion use, then map
  # that type's index Entry to a location. Covers bare locals, parameters, and
  # ivars/cvars; a receiver chain (`a.b.c`) is out of scope for now and answers
  # null — allowed for navigation (unlike hover, which must always answer).
  class TypeDefinitionProvider
    def initialize(@context : ServerContext)
    end

    def type_definition(params : JSON::Any?) : Array(LSP::Location)?
      return nil unless params
      uri = params["textDocument"]["uri"].as_s
      pos = params["position"]
      line = pos["line"].as_i
      character = pos["character"].as_i

      text = @context.documents.text_for(uri)
      return nil unless text
      scanner = TextScanner.new(text)
      return nil if scanner.in_comment_or_string?(line, character)
      name = scanner.word_at(line, character)
      return nil unless name
      # Bare value references only — a receiver chain is deferred.
      return nil if scanner.receiver_at(line, character)

      # word_at snaps to the bare name; restore the sigil so the ivar/cvar path
      # in resolve_variable fires.
      reference = case scanner.ivar_kind_at(line, character)
                  when "cvar" then "@@#{name}"
                  when "ivar" then "@#{name}"
                  else             name
                  end

      chain = @context.resolver.chain_at(uri, line)
      fqn = @context.resolver.receiver_resolver.resolve_variable(reference, chain, uri, line)
      return nil unless fqn

      locations = type_locations(fqn)
      return nil if locations.empty?
      locations
    end

    # Type Entries at `fqn` (generic args stripped, so `Array(String)` jumps to
    # `Array`) → name-range locations. Returns every match when ambiguous, like
    # definition.
    private def type_locations(fqn : String) : Array(LSP::Location)
      base = TypeResolver.base_type(fqn)
      @context.resolver.type_resolver.types_at_fqn(base).map do |s|
        LSP::EntryLocations.name_range(s)
      end
    end
  end
end
