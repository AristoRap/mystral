require "../index"
require "./type_resolver"
require "./scope_walker"
require "./receiver_resolving"

module Mystral
  # The priority ladder that turns `(name, receiver, cursor)` into the
  # matching symbol(s) — emulating Crystal's method/constant lookup. The dense
  # core of the old scope.cr, now built on TypeResolver + ScopeWalker.
  #
  # Resolution order:
  #   1. Receiver call (`Foo.bar`, `Foo::Bar.baz`, and — once ReceiverResolver
  #      is wired — `@app.event`, `foo.bar.baz`): resolve the receiver to a
  #      type FQN, then walk that type's inheritance + includes for `name`.
  #   2. Bare type (CamelCase, no receiver): lexical scope walk-up to the type.
  #   3. Bare lowercase: a method on self — defs in the enclosing scope chain,
  #      then the top-level (implicit Object) fallback that lights up
  #      `puts`/`raise`/`loop`. Ivars/cvars are reachable only via `@`/`@@`.
  class SymbolLookup
    # The receiver resolver for variable / chain receivers; nil until its
    # increment lands (then those receiver shapes resolve to []).
    setter receivers : ReceiverResolving? = nil

    def initialize(@index : Index, @types : TypeResolver, @scopes : ScopeWalker)
      @receivers = nil
    end

    def scoped_matches(name : String, uri : String, receiver : String? = nil, line : Int32? = nil) : Array(::Mystral::Entry)
      chain = line ? @scopes.chain_at(uri, line) : [] of String

      if (recv = receiver) && (ln = line)
        # A bare/qualified type receiver (`Foo.bar`) is a CLASS-level call; a
        # variable (`obj.bar`) or longer chain resolves to an instance. Only
        # class-level receivers follow `extend`ed modules (extend contributes
        # class methods).
        class_level = !TypeResolver.chain_like?(recv) && !TypeResolver.variable_receiver?(recv)

        if TypeResolver.chain_like?(recv)
          resolved = @receivers.try(&.resolve_chain(recv, chain, uri, ln))
          return [] of ::Mystral::Entry unless resolved
          recv = resolved
        elsif TypeResolver.variable_receiver?(recv)
          resolved = @receivers.try(&.resolve_variable(recv, chain, uri, ln))
          return [] of ::Mystral::Entry unless resolved
          recv = resolved
        end

        # A generic instantiation (`Array(String)`) looks up methods under its
        # base type (`Array`). No-op for a non-generic receiver.
        recv = TypeResolver.base_type(recv)

        if resolved = @types.resolve_receiver(recv, chain)
          # If the receiver resolved to an alias, follow it to the real type
          # for method lookups.
          resolved = @types.follow_alias(resolved, chain)

          # Walk the receiver type's full method-resolution chain: superclass
          # ancestors AND every included module (each walked recursively).
          receiver_chain = [] of String
          @scopes.extend_chain(receiver_chain, resolved)
          if class_level
            @scopes.extends_of(resolved).each do |module_name|
              if mod = @types.resolve_receiver(module_name, TypeResolver.lexical_ancestors(resolved))
                @scopes.extend_chain(receiver_chain, mod)
              end
            end
          end

          receiver_chain.each do |scope|
            # A `recv.name` call resolves to a method, never a variable — the
            # ivar/cvar an accessor backs is reachable only via `@name`.
            hits = @index.find_by_name(name).select { |s| s.container == scope && !TypeResolver.var_kind?(s.kind) }
            unless hits.empty?
              # Type reopenings (same container/name/kind across files) collapse
              # to one — but method overloads keep their N entries.
              return hits.all? { |s| TypeResolver.container_kind?(s.kind) } ? dedupe_reopenings(hits) : hits
            end
            if name == "new"
              inits = @index.find_by_name("initialize").select { |s| s.container == scope }
              return inits unless inits.empty?
            end
          end

          # `.new` on a type with no explicit initialize anywhere in the chain
          # — fall back to the type itself so hovering `.new` shows its
          # signature instead of nothing.
          if name == "new"
            type_hits = @types.types_at_fqn(resolved)
            return dedupe_reopenings(type_hits) unless type_hits.empty?
          end

          return [] of ::Mystral::Entry
        end
      end

      if line && receiver.nil? && TypeResolver.type_shaped?(name)
        if resolved = @types.resolve_receiver(name, chain)
          type_matches = @types.types_at_fqn(resolved)
          return dedupe_reopenings(type_matches) unless type_matches.empty?
        end
      end

      return @index.find_by_name(name).select { |s| s.uri == uri } unless line

      if chain.empty?
        # Top-level call: resolve to top-level defs (container nil).
        return @index.find_by_name(name).select { |s| s.container.nil? }
      end

      # Inside a class/module. First container in the chain with a matching def
      # wins (Crystal's first-defined-wins). Ivars/cvars excluded (bare names
      # don't reach them).
      candidates = @index.find_by_name(name).reject { |s| TypeResolver.var_kind?(s.kind) }
      chain.each do |scope|
        hits = candidates.select { |s| s.container == scope }
        return hits unless hits.empty?
      end

      # Top-level fallback: a top-level `def` is a private method of Object,
      # reachable from any class via implicit self → Object → top-level
      # (`sleep`/`raise`/`puts`/`loop`). Top-level consts are global the same
      # way. Top-level TYPES are not here — they have the type-walk path above.
      top_hits = candidates.select do |s|
        s.container.nil? && (s.kind == "def" || s.kind == "macro" || s.kind == "const")
      end
      return top_hits unless top_hits.empty?

      [] of ::Mystral::Entry
    end

    # Crystal allows reopening a class/module/struct/enum across files; each
    # reopening is its own indexed symbol. Collapse to one per
    # (container, name, kind), preferring the version that carries a doc.
    def dedupe_reopenings(matches : Array(::Mystral::Entry)) : Array(::Mystral::Entry)
      best = {} of {String?, String, String} => ::Mystral::Entry
      matches.each do |s|
        key = {s.container, s.name, s.kind}
        existing = best[key]?
        if existing.nil? || (existing.doc.nil? && !s.doc.nil?)
          best[key] = s
        end
      end
      best.values
    end
  end
end
