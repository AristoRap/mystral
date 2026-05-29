require "../index"
require "../documents"
require "./type_resolver"
require "./scope_walker"
require "./text_scanner"
require "./signature_params"
require "./receiver_resolving"

module Mystral
  # Resolves a receiver/value EXPRESSION to a concrete type FQN, using only the
  # AST-derived index + buffer text (no compiler): qualified-type chains,
  # variable/ivar receivers, method-return chains, and local/parameter types
  # inferred from assignments and signatures. This is what lets `@app.event`,
  # `foo.bar.baz`, and a local `x = Foo.new` resolve on the parser-only hot
  # path. Implements ReceiverResolving so SymbolLookup can drive it.
  class ReceiverResolver
    include ReceiverResolving

    def initialize(@index : Index, @types : TypeResolver, @scopes : ScopeWalker, @documents : Documents)
    end

    # `Foo`, `Foo::Bar`, `@app`, `@app.event`, `Foo.event.emit` → the FQN of
    # the final type, or nil if any step doesn't resolve. Greedily consumes a
    # leading CamelCase type run, then treats each remaining segment as a
    # method call whose return type becomes the running type.
    def resolve_chain(receiver : String, chain : Array(String), uri : String, line : Int32) : String?
      segments = TextScanner.split_chain_segments(receiver)
      return nil if segments.empty?

      current = nil.as(String?)
      i = 0

      if segments[0][:name][0].uppercase?
        type_parts = [] of String
        while i < segments.size
          seg = segments[i]
          break unless seg[:name][0].uppercase?
          break if i > 0 && seg[:sep] == :dot
          type_parts << seg[:name]
          i += 1
        end
        return nil if type_parts.empty?
        current = @types.resolve_receiver(type_parts.join("::"), chain)
        return nil unless current
        current = @types.follow_alias(current, chain)
      else
        current = resolve_variable(segments[0][:name], chain, uri, line)
        return nil unless current
        i = 1
      end

      while i < segments.size
        seg = segments[i]
        next_type = resolve_method_return_type(seg[:name], current)
        return nil unless next_type
        current = next_type
        i += 1
      end

      current
    end

    # A single variable receiver (`@app` / `app`) → its type FQN. Tried in
    # order: a def (getter/method) on the lookup chain; for `@field`, an
    # indexed ivar/cvar declaration, then a body-assignment scan; for a plain
    # lowercase name, a local-var / parameter type.
    def resolve_variable(receiver : String, chain : Array(String), uri : String, line : Int32) : String?
      lookup_name = receiver.lstrip('@')
      return nil if lookup_name.empty?

      candidate_def = nil.as(::Mystral::Entry?)
      @index.find_by_name(lookup_name).each do |s|
        next unless s.kind == "def"
        next unless (container = s.container) && chain.includes?(container)
        candidate_def = s
        break
      end

      if candidate_def
        declared = candidate_def.declared_type
        return nil unless declared
        return @types.resolve_or_passthrough(declared, chain)
      end

      if receiver.starts_with?('@')
        @index.find_by_name(lookup_name).each do |s|
          next unless s.kind == "ivar" || s.kind == "cvar"
          next unless (container = s.container) && chain.includes?(container)
          declared = s.declared_type
          return nil unless declared
          return @types.resolve_or_passthrough(declared, chain)
        end

        if t = ivar_type_via_body_assignment(uri, line, lookup_name)
          return @types.resolve_or_passthrough(t, chain)
        end
        return nil
      end

      # Plain lowercase receiver: maybe a local / parameter.
      value_type(lookup_name, uri, line)
    end

    # The type of a bare value reference `name` in scope at `line` — the ONE
    # place params and locals get typed, shared by hover's value-ref paths and
    # the receiver step above, so hover and completion can't disagree. A
    # `name = …` local wins over a same-named parameter (Crystal shadows it);
    # a param with no local assignment falls through to its declared type.
    def value_type(name : String, uri : String, line : Int32) : String?
      infer_local_var_type(name, uri, line) || param_type_in_enclosing_def(name, uri, line)
    end

    # Walk `scope_fqn`'s inheritance chain for a def named `method_name`, pull
    # its `: ReturnType`, and resolve that lexically.
    private def resolve_method_return_type(method_name : String, scope_fqn : String) : String?
      @scopes.inheritance_chain(TypeResolver.base_type(scope_fqn)).each do |scope|
        def_sym = @types.find_def_on(method_name, scope)
        next unless def_sym
        declared = def_sym.declared_type
        return nil unless declared
        return @types.resolve_or_passthrough(declared, TypeResolver.lexical_ancestors(scope_fqn))
      end
      nil
    end

    # Type of local `name` at `line` — scan the enclosing def's body backwards
    # for the latest `name = expr`, resolve the RHS. Top-level code scans from
    # file start. Last-write-wins.
    def infer_local_var_type(name : String, uri : String, line : Int32) : String?
      text = @documents.text_for(uri)
      return nil unless text

      enclosing = @index.symbols_in(uri).find do |s|
        s.kind == "def" && s.line <= line && (end_line = s.end_line) && line <= end_line
      end
      scan_start = enclosing ? enclosing.line + 1 : 0

      lines = text.split('\n')
      assign_re = /\A\s*#{Regex.escape(name)}\s*=(?![=>])\s*(.+)\z/
      rhs = nil.as(String?)
      scan_start.upto(line) do |ln|
        next unless ln >= 0 && ln < lines.size
        if m = lines[ln].match(assign_re)
          rhs = m[1].strip
        end
      end
      return nil unless rhs

      infer_rhs_type(rhs, uri, line)
    end

    # Type of parameter `name` in the def enclosing `line`, or nil. Reads the
    # rendered signature we already store — no AST reparse.
    def param_type_in_enclosing_def(name : String, uri : String, line : Int32) : String?
      enclosing = @index.symbols_in(uri).select do |s|
        (s.kind == "def" || s.kind == "proc") &&
          s.line <= line &&
          (end_line = s.end_line) &&
          line <= end_line
      end.max_by?(&.line)
      return nil unless enclosing
      label = SignatureParams.parameter_label_for(enclosing.signature, name)
      return nil unless label
      parts = label.split(/\s*:\s*/, 2)
      parts.size == 2 ? parts[1].strip : nil
    end

    # Map an RHS expression string to a type FQN where the AST can tell;
    # nil for anything needing flow analysis.
    private def infer_rhs_type(rhs : String, uri : String, line : Int32) : String?
      raw = rhs.rstrip

      # Typed literals BEFORE any paren trimming (the value is the type expr).
      if m = raw.match(/\A\[.*\]\s+of\s+(.+)\z/)
        return "Array(#{m[1].strip})"
      end
      if m = raw.match(/\A\{.*?\}\s+of\s+(.+?)\s*=>\s*(.+)\z/)
        return "Hash(#{m[1].strip}, #{m[2].strip})"
      end

      trimmed = trim_trailing_call_args(raw) || raw
      trimmed = trimmed.rstrip(" \t(").rstrip if trimmed.ends_with?('(')

      # `Type.new`, `Foo::Bar.new`, `Set(String).new` — constructor returns the
      # receiver type. One level of generic params captured; resolved lexically.
      if m = trimmed.match(/\A([A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)(\([^()]*\))?\.new\z/)
        base = m[1]
        generic_args = m[2]?
        resolved = @types.resolve_receiver(base, @scopes.chain_at(uri, line)) || base
        return generic_args ? "#{resolved}#{generic_args}" : resolved
      end

      # Pure CamelCase type reference (`x = Foo::Bar` / `x = Set(String)`).
      if m = trimmed.match(/\A([A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)(\([^()]*\))?\z/)
        base = m[1]
        generic_args = m[2]?
        resolved = @types.resolve_receiver(base, @scopes.chain_at(uri, line)) || base
        return generic_args ? "#{resolved}#{generic_args}" : resolved
      end

      # Chain expression — defer to the chain resolver (which may recurse into
      # local-var resolution if it starts with another local).
      if trimmed.match(/\A[@A-Za-z_][\w@.:?!]*\z/)
        # `x = some_param`: a bare identifier naming a typed parameter
        # propagates that param's type. Checked before chain resolution.
        if !trimmed.includes?('.') && (pt = param_type_in_enclosing_def(trimmed, uri, line))
          return pt
        end
        return resolve_chain(trimmed, @scopes.chain_at(uri, line), uri, line)
      end

      nil
    end

    # Strip a trailing balanced `(...)` arg list. nil when the parens don't
    # balance (caller keeps the original).
    private def trim_trailing_call_args(s : String) : String?
      return nil unless s.ends_with?(')')
      depth = 1
      i = s.size - 2
      while i >= 0 && depth > 0
        case s[i]
        when ')' then depth += 1
        when '(' then depth -= 1
        end
        i -= 1
      end
      return nil if depth != 0
      s[0..i].rstrip
    end

    # Scan the enclosing type body for `@<name> = expr` (latest wins) when no
    # indexed ivar covers it. ivars only.
    private def ivar_type_via_body_assignment(uri : String, line : Int32, name : String) : String?
      text = @documents.text_for(uri)
      return nil unless text
      enclosing = @index.symbols_in(uri).find do |s|
        TypeResolver.container_kind?(s.kind) && s.line <= line && (end_line = s.end_line) && line <= end_line
      end
      return nil unless enclosing
      end_line = enclosing.end_line
      return nil unless end_line

      lines = text.split('\n')
      assign_re = /\A\s*@#{Regex.escape(name)}\s*=(?![=>])\s*(.+)\z/
      rhs = nil.as(String?)
      (enclosing.line + 1).upto(end_line) do |ln|
        next unless ln >= 0 && ln < lines.size
        if m = lines[ln].match(assign_re)
          rhs = m[1].strip
        end
      end
      return nil unless rhs
      infer_rhs_type(rhs, uri, line)
    end
  end
end
