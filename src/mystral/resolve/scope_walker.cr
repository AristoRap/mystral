require "../index"
require "./type_resolver"

module Mystral
  # Crystal-faithful scope walk-up: which containers enclose a cursor, and the
  # full method-resolution chain from there (superclasses + included modules).
  # Builds on TypeResolver for the type-name lookups; the chain it produces is
  # what SymbolLookup searches in order.
  class ScopeWalker
    # Ground-truth ancestry source (reaped `crystal tool hierarchy`), injected
    # by the InferenceIndex increment. nil here → reaped_ancestors is empty, so
    # walk_parents behaves exactly as AST-only resolution (the documented
    # no-op until the populator lands).
    setter ancestry_source : (Proc(String, Array(String)?))? = nil

    def initialize(@index : Index, @types : TypeResolver)
      @ancestry_source = nil
    end

    # Enclosing container FQNs (innermost first) whose line range contains
    # `line`. Sorted by `::` depth so the deepest scope is tried first.
    def enclosing_containers(uri : String, line : Int32) : Array(String)
      scopes = [] of String
      @index.symbols_in(uri).each do |s|
        next unless TypeResolver.container_kind?(s.kind)
        next unless s.line <= line
        end_line = s.end_line
        next if end_line && line > end_line
        full = s.container ? "#{s.container}::#{s.name}" : s.name
        scopes << full
      end
      scopes.uniq.sort_by { |s| {-s.count("::"), -1} }
    end

    # Crystal's full constant/method lookup chain at a cursor: lexical scopes +
    # inheritance + includes. Empty at top level.
    def chain_at(uri : String, line : Int32) : Array(String)
      lookup_chain(enclosing_containers(uri, line))
    end

    # The method-resolution chain from the enclosing scopes, each expanded with
    # its superclass chain (classes) AND its included modules (classes and
    # modules). Duplicates suppressed.
    def lookup_chain(enclosing : Array(String)) : Array(String)
      chain = [] of String
      enclosing.each { |scope| extend_chain(chain, scope) }
      chain
    end

    # Append `scope` and everything it inherits/includes to `chain` (in place),
    # suppressing cycles and duplicates. Recursive: an included module is
    # itself walked for its parents/includes.
    def extend_chain(chain : Array(String), scope : String) : Nil
      return if chain.includes?(scope)
      chain << scope
      walk_parents(scope) do |ancestor|
        extend_chain(chain, ancestor)
      end
      includes_of(scope).each do |module_name|
        if resolved = @types.resolve_receiver(module_name, TypeResolver.lexical_ancestors(scope))
          extend_chain(chain, resolved)
        end
      end
    end

    # Yields each ancestor FQN of `class_fqn`, resolving each parent's written
    # name against the lexical scope. Stops at the first unresolved ancestor,
    # falling back to reaped ground-truth ancestry for the rest. Never loops.
    def walk_parents(class_fqn : String, &block : String ->) : Nil
      seen = Set(String).new
      current = class_fqn
      while !seen.includes?(current)
        seen << current
        resolved = resolve_ast_parent(current)
        unless resolved
          reaped_ancestors(current).each do |ancestor|
            next if seen.includes?(ancestor)
            seen << ancestor
            yield ancestor
          end
          break
        end
        yield resolved
        current = resolved
      end
    end

    # `class_fqn` plus its full ancestor chain (closest parent first).
    def inheritance_chain(class_fqn : String) : Array(String)
      chain = [class_fqn]
      walk_parents(class_fqn) { |a| chain << a }
      chain
    end

    # Module FQNs included by `scope` (visitor records each `include Foo` as a
    # synthetic symbol kind="include", container = the enclosing scope).
    def includes_of(scope : String) : Array(String)
      result = [] of String
      @index.each_symbol do |s|
        next unless s.kind == "include"
        next unless s.container == scope
        result << s.name
      end
      result
    end

    # Module FQNs extended by `scope` (kind="extend"). `extend self` is
    # filtered — the module's own methods already resolve under its container.
    def extends_of(scope : String) : Array(String)
      result = [] of String
      @index.each_symbol do |s|
        next unless s.kind == "extend"
        next unless s.container == scope
        next if s.name == "self"
        result << s.name
      end
      result
    end

    # Resolve `class_fqn`'s superclass via the AST `parent` field, looking the
    # recorded name up against the lexical scope (`class B < Error` inside
    # `module Lune` resolves `Error` → `Lune::Error` if that exists). nil when
    # no parent is recorded or it doesn't resolve to an indexed class.
    def resolve_ast_parent(class_fqn : String) : String?
      parent_name = class_symbol_parent(class_fqn)
      return nil unless parent_name
      scope_path = class_fqn.split("::")[0..-2]
      scopes = [] of String
      (0..scope_path.size).reverse_each do |depth|
        path = scope_path.first(depth)
        scopes << (path.empty? ? parent_name : (path + [parent_name]).join("::"))
      end
      scopes.find { |fqn| @types.class_exists?(fqn) }
    end

    private def class_symbol_parent(class_fqn : String) : String?
      simple, container = TypeResolver.split_fqn(class_fqn)
      sym = @index.find_by_name(simple).find do |s|
        s.container == container && (s.kind == "class" || s.kind == "struct")
      end
      sym.try(&.parent)
    end

    # Ground-truth ancestors for `class_fqn` from the reaped hierarchy, or
    # empty when none. Only consulted as the walk_parents fallback.
    private def reaped_ancestors(class_fqn : String) : Array(String)
      (@ancestry_source.try(&.call(class_fqn))) || [] of String
    end
  end
end
