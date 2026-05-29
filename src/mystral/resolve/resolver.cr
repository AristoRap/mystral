require "../index"
require "../documents"
require "./type_resolver"
require "./scope_walker"
require "./symbol_lookup"
require "./receiver_resolver"

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
    getter receiver_resolver : ReceiverResolver

    def initialize(@index : Index, documents : Documents)
      @type_resolver = TypeResolver.new(@index)
      @scope_walker = ScopeWalker.new(@index, @type_resolver)
      @receiver_resolver = ReceiverResolver.new(@index, @type_resolver, @scope_walker, documents)
      @symbol_lookup = SymbolLookup.new(@index, @type_resolver, @scope_walker)
      # Plug the receiver resolver into the lookup so variable/chain receivers
      # (`@app.event`, `foo.bar`) now resolve instead of returning [].
      @symbol_lookup.receivers = @receiver_resolver
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
