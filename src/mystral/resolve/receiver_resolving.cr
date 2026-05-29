module Mystral
  # The contract SymbolLookup needs to resolve a variable / multi-segment-chain
  # receiver expression to a concrete type FQN. The concrete ReceiverResolver
  # (which needs the AST + buffer text to infer local/chain types) lands in a
  # later increment and `include`s this; until then SymbolLookup's receiver is
  # nil and those receiver shapes resolve to nothing — exactly the AST-only
  # scope this increment ships.
  module ReceiverResolving
    # `@app.event` / `foo.bar.baz` → the FQN the chain evaluates to, or nil.
    abstract def resolve_chain(receiver : String, chain : Array(String), uri : String, line : Int32) : String?

    # A single variable receiver (`@app` / `app`) → its type FQN, or nil.
    abstract def resolve_variable(receiver : String, chain : Array(String), uri : String, line : Int32) : String?
  end
end
