require "../index"
require "./type_resolver"
require "./scope_walker"
require "./symbol_lookup"

module Mystral
  # The single resolution entry point every provider injects. It composes the
  # stack (TypeResolver → ScopeWalker → SymbolLookup) so hover, definition,
  # completion, and signature help all resolve `a.b.c` through the SAME code —
  # they can't disagree about what a symbol/type at a cursor is.
  #
  # The pieces are exposed (getters) so providers that need lower-level access
  # (hover's renderer walks the type chain, completion enumerates a scope) can
  # reach them without re-deriving the wiring.
  class Resolver
    getter type_resolver : TypeResolver
    getter scope_walker : ScopeWalker
    getter symbol_lookup : SymbolLookup

    def initialize(@index : Index)
      @type_resolver = TypeResolver.new(@index)
      @scope_walker = ScopeWalker.new(@index, @type_resolver)
      @symbol_lookup = SymbolLookup.new(@index, @type_resolver, @scope_walker)
    end

    # The symbol(s) the cursor's `name` (with optional `receiver`) resolves to.
    def matches_at(name : String, uri : String, receiver : String?, line : Int32?) : Array(::Mystral::Entry)
      @symbol_lookup.scoped_matches(name, uri, receiver, line)
    end

    # Crystal's lookup chain at a cursor (lexical scopes + inheritance +
    # includes).
    def chain_at(uri : String, line : Int32) : Array(String)
      @scope_walker.chain_at(uri, line)
    end
  end
end
