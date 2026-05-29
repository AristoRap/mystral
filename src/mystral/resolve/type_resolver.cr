require "../index"

module Mystral
  # Type-level queries over the symbol index: does a type exist at an FQN,
  # what is its base/aliased form, resolve a written name against a lexical
  # scope. Depends only on the Index — no scope-walk, no cursor state — so it
  # sits at the bottom of the resolver stack (ScopeWalker and SymbolLookup
  # build on it).
  class TypeResolver
    def initialize(@index : Index)
    end

    # Crystal name resolution: `Foo::Bar` written inside scope `X::Y::Z` tries
    # `X::Y::Z::Foo::Bar`, then `X::Y::Foo::Bar`, ... then `Foo::Bar`. First
    # match wins. `enclosing` is innermost-first.
    def resolve_receiver(receiver : String, enclosing : Array(String)) : String?
      enclosing.each do |scope|
        candidate = "#{scope}::#{receiver}"
        return candidate if type_exists?(candidate)
      end
      type_exists?(receiver) ? receiver : nil
    end

    # Common tail of every type-resolution path: lexical-walk first, fall back
    # to the type as-written if it's already a known FQN, else nil. (A prior
    # bug here returned the unresolved string instead of nil, silently passing
    # a bogus type up the chain — hence the explicit nil.)
    def resolve_or_passthrough(type : String, chain : Array(String)) : String?
      resolve_receiver(type, chain) || (type_exists?(type) ? type : nil)
    end

    # Does the index contain a type at this FQN? "Type" includes aliases
    # (nameable in receiver position) even though they define no scope.
    def type_exists?(fqn : String) : Bool
      simple, container = TypeResolver.split_fqn(fqn)
      @index.find_by_name(simple).any? do |s|
        s.container == container && TypeResolver.type_kind?(s.kind)
      end
    end

    def class_exists?(fqn : String) : Bool
      simple, container = TypeResolver.split_fqn(fqn)
      @index.find_by_name(simple).any? do |s|
        s.container == container && (s.kind == "class" || s.kind == "struct")
      end
    end

    # Type symbols (class/module/struct/enum/lib/alias) at exactly this FQN.
    def types_at_fqn(fqn : String) : Array(::Mystral::Entry)
      simple, container = TypeResolver.split_fqn(fqn)
      @index.find_by_name(simple).select { |s| s.container == container && TypeResolver.type_kind?(s.kind) }
    end

    # First def named `name` whose container is exactly `scope`. Does NOT walk
    # inheritance — callers iterate the inheritance chain themselves.
    def find_def_on(name : String, scope : String) : ::Mystral::Entry?
      @index.find_by_name(name).find { |s| s.kind == "def" && s.container == scope }
    end

    # Follow `alias A = B` chains until a non-alias. Idempotent for
    # non-aliases; transitive (`alias A = B; alias B = C` → C).
    def follow_alias(fqn : String, chain : Array(String)) : String
      seen = Set(String).new
      current = fqn
      while !seen.includes?(current)
        seen << current
        simple, container = TypeResolver.split_fqn(current)
        alias_sym = @index.find_by_name(simple).find do |s|
          s.kind == "alias" && s.container == container
        end
        break unless alias_sym
        sig = alias_sym.signature
        break unless sig
        m = sig.match(/\Aalias\s+\S+\s*=\s*(.+?)\s*\z/)
        break unless m
        target = m[1].strip
        # Resolve the target lexically — `alias Foo = Bar` inside `module Lune`
        # resolves `Bar` against `Lune` then top-level.
        scope_for_resolve = container ? [container] + TypeResolver.lexical_ancestors(container) : [] of String
        resolved = resolve_or_passthrough(target, scope_for_resolve)
        break unless resolved
        current = resolved
      end
      current
    end

    # ---- pure helpers (no index access) ----

    # `{simple, container}`. `"Foo::Bar::Baz"` → `{"Baz", "Foo::Bar"}`;
    # `"Foo"` → `{"Foo", nil}`.
    def self.split_fqn(fqn : String) : Tuple(String, String?)
      parts = fqn.split("::")
      {parts.last, parts.size > 1 ? parts[0..-2].join("::") : nil}
    end

    # Lexical ancestor FQNs for `scope`, inner first. `"App::Page"` →
    # `["App::Page", "App"]`.
    def self.lexical_ancestors(scope : String) : Array(String)
      parts = scope.split("::")
      result = [] of String
      parts.size.downto(1) do |n|
        result << parts.first(n).join("::")
      end
      result
    end

    # Base type of a (possibly generic) instantiation: `Array(String)` →
    # `Array`, `Foo::Bar(T)` → `Foo::Bar`, `Foo` → `Foo`. Lookup keys off the
    # base — the index stores `class Array(T)` under `Array`.
    def self.base_type(fqn : String) : String
      paren = fqn.index('(')
      paren ? fqn[0...paren].rstrip : fqn
    end

    # "can this define a scope" — class/module/struct/enum/lib.
    def self.container_kind?(kind : String) : Bool
      kind == "class" || kind == "module" || kind == "struct" || kind == "enum" || kind == "lib"
    end

    # "can this be NAMED as a type" — container kinds plus aliases (which
    # enclose nothing and must be followed to their target before method
    # lookup).
    def self.type_kind?(kind : String) : Bool
      container_kind?(kind) || kind == "alias"
    end

    def self.var_kind?(kind : String) : Bool
      kind == "ivar" || kind == "cvar"
    end

    # An identifier shaped like a type — leading uppercase (Crystal convention).
    def self.type_shaped?(name : String) : Bool
      !name.empty? && name[0].uppercase?
    end

    # Variable-shaped receiver: bare lowercase / underscore identifier or
    # `@ivar`. CamelCase qualified chains are NOT variable receivers.
    def self.variable_receiver?(receiver : String) : Bool
      return false if receiver.empty?
      c = receiver[0]
      c == '@' || c.lowercase? || c == '_'
    end

    # Does the receiver contain a chain separator (`.` or `::`)?
    def self.chain_like?(receiver : String) : Bool
      receiver.includes?('.') || receiver.includes?("::")
    end
  end
end
