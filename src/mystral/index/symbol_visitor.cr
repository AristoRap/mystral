require "compiler/crystal/syntax"
require "./entry"
require "./signature_renderer"

module Mystral
  # The AST walker that turns a parsed `.cr` file into Entry records.
  #
  # DESIGN NOTE: this class intentionally exceeds the project's 300-line
  # guideline. It is a single-responsibility node dispatcher — one
  # `visit(SomeNode)` per Crystal AST node kind — and is NEVER reopened.
  # Splitting the dispatch across files would hurt traceability (to see how
  # `class` is indexed you read `visit(ClassDef)` here, in one place) without
  # reducing coupling. The genuinely independent concern — pure AST→string /
  # type inference — already lives in SignatureRenderer; what remains is the
  # irreducible walk. Keep new node handling here; do not reopen this class.
  class SymbolVisitor < ::Crystal::Visitor
    # Shared immutable empty list for the (common) undecorated symbol —
    # avoids a per-record allocation.
    EMPTY_ANNOTATIONS = [] of String

    def initialize(@uri : String, @symbols : Array(::Mystral::Entry))
      # Modifier stashed while descending a VisibilityModifier, so the inner
      # Def/Macro renders `private def ...` — the modifier lives on the
      # wrapper, not the inner node.
      @pending_visibility = nil.as(::Crystal::Visibility?)
      # Enclosing module/class/struct/enum names; joined with `::` to form the
      # container for symbols inside.
      @scope_stack = [] of String
      # When set, every record() uses this location: we're walking a sub-AST
      # parsed out of a MacroLiteral whose locations are relative to the macro
      # body text, not the file. Pointing macro-body symbols at the macro
      # block's line is approximate but navigable.
      @macro_body_location = nil.as(::Crystal::Location?)
      # Annotations (`@[Foo]`) are sibling nodes preceding what they decorate;
      # buffer their text and attach to the next recorded symbol.
      @pending_annotations = [] of String
    end

    # `@[Foo(...)]` — buffer the full text for the next recorded symbol. Don't
    # descend into the args (identifier-shaped nodes we don't want to index).
    def visit(node : ::Crystal::Annotation) : Bool
      @pending_annotations << node.to_s
      false
    end

    def visit(node : ::Crystal::ClassDef) : Bool
      segments = node.name.names
      push_outer_segments(segments)
      keyword = node.struct? ? "struct" : "class"
      sig = String.build do |io|
        io << keyword << " " << node.name
        if sc = node.superclass
          io << " < " << sc
        end
      end
      record(
        segments.last, keyword, node.location,
        signature: sig,
        doc: node.doc, end_loc: node.end_location,
        parent: node.superclass.try(&.to_s),
      )
      @scope_stack.push(segments.last)
      true
    end

    def end_visit(node : ::Crystal::ClassDef) : Nil
      node.name.names.size.times { @scope_stack.pop }
    end

    def visit(node : ::Crystal::ModuleDef) : Bool
      segments = node.name.names
      push_outer_segments(segments)
      record(
        segments.last, "module", node.location,
        signature: "module #{node.name}",
        doc: node.doc, end_loc: node.end_location,
      )
      @scope_stack.push(segments.last)
      true
    end

    def end_visit(node : ::Crystal::ModuleDef) : Nil
      node.name.names.size.times { @scope_stack.pop }
    end

    def visit(node : ::Crystal::EnumDef) : Bool
      segments = node.name.names
      push_outer_segments(segments)
      record(
        segments.last, "enum", node.location,
        signature: SignatureRenderer.enum_signature(node),
        doc: node.doc, end_loc: node.end_location,
      )
      @scope_stack.push(segments.last)
      true
    end

    def end_visit(node : ::Crystal::EnumDef) : Nil
      # Pop every segment visit pushed (push_outer_segments + the leaf). A
      # multi-segment `enum Foo::Color` pushes both `Foo` and `Color`; popping
      # once would leak `Foo` and mis-container the following siblings.
      node.name.names.size.times { @scope_stack.pop }
    end

    # `annotation Foo; end` (and namespaced `annotation Foo::Bar`). A leaf type
    # — empty body by design — but a real, navigable definition (`@[Foo]` jumps
    # here), so it earns a symbol. Same name/scope bookkeeping as ClassDef.
    def visit(node : ::Crystal::AnnotationDef) : Bool
      segments = node.name.names
      push_outer_segments(segments)
      record(
        segments.last, "annotation", node.location,
        signature: "annotation #{node.name}",
        doc: node.doc, end_loc: node.end_location,
      )
      @scope_stack.push(segments.last)
      true
    end

    def end_visit(node : ::Crystal::AnnotationDef) : Nil
      node.name.names.size.times { @scope_stack.pop }
    end

    def visit(node : ::Crystal::Def) : Bool
      # `def Foo.bar` / `def Foo::Bar.baz` at top level is a class method ON
      # the named type, not a free-floating top-level def. Push the receiver
      # path while we record so the symbol lands with container = the type
      # (e.g. stdlib's `def Time.instant` defined outside `struct Time`).
      pushed = 0
      if (recv = node.receiver) && recv.is_a?(::Crystal::Path)
        recv.names.each { |seg| @scope_stack.push(seg); pushed += 1 }
      end

      declared = node.return_type.try { |rt| SignatureRenderer.normalize_type_str(rt.to_s) }
      # Only infer when the user didn't annotate — declared always wins. A
      # single literal yields its type outright; a bare ivar/cvar-read body
      # records the source var for hover-time resolution. Both leaf shapes,
      # no branch/dispatch/macro, so neither can lie. Everything else: nil.
      inferred = declared ? nil : SignatureRenderer.infer_default_literal_type(node.body)
      inferred ||= SignatureRenderer.bare_param_read_type(node) unless declared
      return_ivar = (declared || inferred) ? nil : SignatureRenderer.bare_var_read_name(node.body)
      record(
        node.name, "def", node.location,
        SignatureRenderer.signature_for(node, @pending_visibility),
        node.doc,
        class_method: !node.receiver.nil?,
        end_loc: node.end_location,
        visibility: visibility_str(@pending_visibility),
        declared_type: declared,
        inferred_return: inferred,
        return_ivar: return_ivar,
      )

      emit_param_backed_ivars(node) unless @scope_stack.empty?

      pushed.times { @scope_stack.pop }
      false # don't descend into method bodies — locals aren't workspace symbols
    end

    # `def initialize(@field : T)` is sugar — the parser rewrites it to
    # `def initialize(field : T); @field = field; ...`. The Arg has its sigil
    # stripped (the rendered signature can't tell shorthand from a plain
    # param), but the auto-inserted Assign IS preserved. Walk the body's
    # top-level exprs, pick `Assign(InstanceVar|ClassVar, Var)` whose Var
    # matches a typed arg, and emit an ivar/cvar entry with the arg's type.
    # Also catches user-written `def foo(x : T); @x = x; end` (same semantics).
    private def emit_param_backed_ivars(node : ::Crystal::Def) : Nil
      arg_types = {} of String => String
      node.args.each do |a|
        if r = a.restriction
          arg_types[a.name] = SignatureRenderer.normalize_type_str(r.to_s)
        elsif (dv = a.default_value) && (t = SignatureRenderer.infer_default_literal_type(dv))
          arg_types[a.name] = t
        end
      end
      return if arg_types.empty?

      exprs = case body = node.body
              when ::Crystal::Expressions then body.expressions
              when ::Crystal::Assign      then [body] of ::Crystal::ASTNode
              else                             return
              end

      exprs.each do |expr|
        next unless expr.is_a?(::Crystal::Assign)
        value = expr.value
        next unless value.is_a?(::Crystal::Var)
        type_str = arg_types[value.name]?
        next unless type_str

        case target = expr.target
        when ::Crystal::InstanceVar
          record_param_backed_ivar("ivar", "@", target.name, type_str, expr.location)
        when ::Crystal::ClassVar
          record_param_backed_ivar("cvar", "@@", target.name, type_str, expr.location)
        end
      end
    end

    private def record_param_backed_ivar(kind : String, sigil : String, raw_name : String, type_str : String, loc) : Nil
      name = raw_name.lstrip('@')
      record(name, kind, loc, signature: "#{sigil}#{name} : #{type_str}", declared_type: type_str)
    end

    private def visibility_str(v : ::Crystal::Visibility?) : String?
      case v
      when ::Crystal::Visibility::Private   then "private"
      when ::Crystal::Visibility::Protected then "protected"
      else                                       nil
      end
    end

    def visit(node : ::Crystal::Macro) : Bool
      record(node.name, "macro", node.location, signature: SignatureRenderer.macro_signature(node), doc: node.doc, end_loc: node.end_location)
      false
    end

    # `record Name, field : Type, ...` (stdlib's one-liner immutable struct)
    # and accessor macros (`getter`/`property`/...) parse as plain Calls (the
    # macro isn't expanded at parse time). Synthesize the symbols they'd
    # generate so types relying on them aren't invisible.
    def visit(node : ::Crystal::Call) : Bool
      if node.obj.nil? && ACCESSOR_MACROS.includes?(node.name) && !@scope_stack.empty?
        synthesize_accessor_macros(node)
        return false
      end
      if node.obj.nil? && node.name == "record" && (first = node.args.first?)
        name = record_macro_name(first)
        if name
          field_strs = node.args.skip(1).map(&.to_s)
          struct_sig = String.build do |io|
            io << "struct " << name
            field_strs.each { |f| io << "\n  " << f }
            io << "\nend" unless field_strs.empty?
          end
          record(name, "struct", node.location,
            signature: struct_sig,
            end_loc: node.end_location, doc: node.doc,
          )
          # The record macro synthesizes an `initialize` taking each field in
          # order. We don't see the expansion, so emit a synthetic def so
          # hover on `Foo.new(...)` redirects to a signature with the right
          # arg names + types. Container is the record's name.
          @scope_stack.push(name)
          record("initialize", "def", node.location,
            signature: SignatureRenderer.wrap_initialize_signature(field_strs),
            end_loc: node.end_location,
          )
          if block = node.block
            block.body.accept(self)
          end
          @scope_stack.pop
          return false
        end
      end
      true
    end

    private def record_macro_name(arg : ::Crystal::ASTNode) : String?
      case arg
      when ::Crystal::Path then arg.names.join("::")
      else                      nil
      end
    end

    # Every accessor-generating macro we recognize. `class_*` variants
    # generate type-level accessors; for symbol-index purposes the name is the
    # same, so we strip the prefix and treat them alike.
    ACCESSOR_MACROS = {
      "getter", "getter?", "getter!",
      "property", "property?", "property!",
      "setter",
      "class_getter", "class_getter?", "class_getter!",
      "class_property", "class_property?", "class_property!",
      "class_setter",
    }

    # `getter wv : Webview` / `property title : String = ""` / `setter limit :
    # Int32` (and `class_*`, `?`, `!` variants) emit synthesized accessors
    # after expansion. The visitor only sees the macro Call, so synthesize the
    # def symbols: a reader for getter/property, a `name=` setter for
    # property/setter, plus the backing ivar/cvar. Anchor each at the ARG's
    # location, not the macro keyword's, so hovering the actual token hits.
    # Suffix: `?` variants name the reader `foo?`; `!` variants `foo`.
    private def synthesize_accessor_macros(node : ::Crystal::Call) : Nil
      base = node.name.lchop("class_") # class_getter -> getter, etc.
      emits_reader = base.starts_with?("getter") || base.starts_with?("property")
      emits_setter = base.starts_with?("property") || base == "setter"
      suffix = base.ends_with?("?") ? "?" : ""
      var_kind = node.name.starts_with?("class_") ? "cvar" : "ivar"
      var_sigil = var_kind == "cvar" ? "@@" : "@"

      node.args.each do |arg|
        name, type = accessor_name_and_type(arg)
        next unless name
        loc = arg.location || node.location
        reader = "#{name}#{suffix}"

        if emits_reader
          sig = type ? "def #{reader} : #{type}" : "def #{reader}"
          record(reader, "def", loc, signature: sig, declared_type: type)
        end

        if emits_setter
          setter_name = "#{name}="
          sig = type ? "def #{setter_name}(value : #{type})" : "def #{setter_name}(value)"
          record(setter_name, "def", loc, signature: sig)
        end

        # The variable the accessors front. `getter app : T` declares `@app :
        # T` as much as `def app`; without this, hovering the ivar/cvar itself
        # resolves to nothing.
        var_sig = type ? "#{var_sigil}#{name} : #{type}" : "#{var_sigil}#{name}"
        record(name, var_kind, loc, signature: var_sig, declared_type: type)
      end
    end

    # `(name, declared_type)` from one accessor-macro arg: a `name : Type
    # [= default]` (TypeDeclaration), a bare `name` (Var), or `name = default`
    # (Assign). nil name for shapes we don't understand.
    private def accessor_name_and_type(arg : ::Crystal::ASTNode) : Tuple(String?, String?)
      case arg
      when ::Crystal::TypeDeclaration
        var = arg.var
        name = var.is_a?(::Crystal::Var) ? var.name : var.to_s
        {name, SignatureRenderer.normalize_type_str(arg.declared_type.to_s)}
      when ::Crystal::Var
        {arg.name, nil}
      when ::Crystal::Assign
        tgt = arg.target
        name = tgt.is_a?(::Crystal::Var) ? tgt.name : tgt.to_s
        {name, nil}
      else
        {nil, nil}
      end
    end

    # `NAME = value` at top level or inside a class/module is a constant.
    # Class/instance vars (`@@x`/`@x`) are state, not constants — they route
    # to record_assigned_var. Multi-segment `Foo::BAR = ...` is skipped for v1.
    def visit(node : ::Crystal::Assign) : Bool
      case target = node.target
      when ::Crystal::Path
        if target.names.size == 1
          name = target.names.first
          if !name.empty? && name[0].uppercase?
            value_str = node.value.to_s
            preview = value_str.size > 200 ? "#{value_str[0..196]}..." : value_str
            record(name, "const", node.location, signature: "#{name} = #{preview}")
          end
        end
      when ::Crystal::InstanceVar
        # `@x = ...` at type-body level (method bodies never reach here —
        # visit(Def) stops descent). Declares an ivar just as `@x : T` does.
        record_assigned_var("ivar", "@", target.name, node) unless @scope_stack.empty?
      when ::Crystal::ClassVar
        record_assigned_var("cvar", "@@", target.name, node) unless @scope_stack.empty?
      end
      # Descend into the value so RHS ProcLiterals get visited and their
      # params become reachable; skip the LHS target.
      node.value.accept(self)
      false
    end

    # A type-body `@x = expr` / `@@x = expr`. The type is the RHS's where the
    # AST can tell for sure (`Foo.new` → Foo, a literal → its type); nil
    # otherwise, in which case hover still resolves the var (showing the
    # assignment) but states no type. Never a lie.
    private def record_assigned_var(kind : String, sigil : String, raw_name : String, node : ::Crystal::Assign) : Nil
      name = raw_name.lstrip('@')
      type = SignatureRenderer.infer_assigned_type(node.value)
      if type
        record(name, kind, node.location, signature: "#{sigil}#{name} : #{type}", declared_type: type)
      else
        preview = node.value.to_s
        preview = "#{preview[0..196]}..." if preview.size > 200
        record(name, kind, node.location, signature: "#{sigil}#{name} = #{preview}")
      end
    end

    # `@field : T [= value]` / `@@var : T [= value]` at class/module body
    # level. The AST knows everything we need — capture it once so hover/chain
    # resolution read a field instead of regexing the source line. Only inside
    # a type scope (top-level `@x : T` is illegal); local-var ascriptions never
    # reach here (visit(Def) stops descent).
    def visit(node : ::Crystal::TypeDeclaration) : Bool
      return true if @scope_stack.empty?
      var = node.var
      case var
      when ::Crystal::InstanceVar then ivar_or_cvar_record("ivar", "@", var.name, node)
      when ::Crystal::ClassVar    then ivar_or_cvar_record("cvar", "@@", var.name, node)
      end
      node.value.try(&.accept(self)) # descend into the default (RHS ProcLiterals)
      false
    end

    private def ivar_or_cvar_record(kind : String, sigil : String, raw_name : String, node : ::Crystal::TypeDeclaration) : Nil
      name = raw_name.lstrip('@')
      type_str = SignatureRenderer.normalize_type_str(node.declared_type.to_s)
      sig = String.build do |io|
        io << sigil << name << " : " << type_str
        if v = node.value
          io << " = " << v
        end
      end
      record(name, kind, node.location, signature: sig, declared_type: type_str)
    end

    # `@buf = uninitialized UInt8` at type-body level — a distinct node from
    # TypeDeclaration but the same intent: a typed ivar/cvar declaration.
    def visit(node : ::Crystal::UninitializedVar) : Bool
      return false if @scope_stack.empty?
      var = node.var
      type_str = SignatureRenderer.normalize_type_str(node.declared_type.to_s)
      case var
      when ::Crystal::InstanceVar then record_var_decl("ivar", "@", var.name, type_str, node.location)
      when ::Crystal::ClassVar    then record_var_decl("cvar", "@@", var.name, type_str, node.location)
      end
      false
    end

    private def record_var_decl(kind : String, sigil : String, raw_name : String, type_str : String, loc) : Nil
      name = raw_name.lstrip('@')
      record(name, kind, loc, signature: "#{sigil}#{name} : #{type_str}", declared_type: type_str)
    end

    # `CONST = ->(x : T) { ... }` and any ProcLiteral. Index the inner def
    # under a sentinel name + dedicated kind so parameter hover can find it by
    # line range, but find_by_name / workspace_symbol skip it.
    def visit(node : ::Crystal::ProcLiteral) : Bool
      inner = node.def
      record(
        "<proc>", "proc", inner.location,
        signature: SignatureRenderer.signature_for(inner, nil),
        end_loc: inner.end_location,
        declared_type: inner.return_type.try(&.to_s),
      )
      false
    end

    # `alias Foo = Bar` — top-level, in a module, or in a lib (how stdlib's
    # LibC declares `Char`, `Int`, etc.).
    def visit(node : ::Crystal::Alias) : Bool
      name = node.name.to_s
      record(name, "alias", node.location,
        signature: "alias #{name} = #{node.value}",
        doc: node.doc,
      )
      false
    end

    # `lib LibC; ...; end` — index the lib and descend so fun/struct/
    # ExternalVar inside land with the lib as their container.
    def visit(node : ::Crystal::LibDef) : Bool
      name = node.name.to_s
      record(name, "lib", node.location,
        signature: "lib #{name}",
        doc: node.doc, end_loc: node.end_location,
      )
      @scope_stack.push(name)
      true
    end

    def end_visit(node : ::Crystal::LibDef) : Nil
      @scope_stack.pop
    end

    # C struct/union inside a `lib` — `struct Kevent ... end`. Treat like a
    # regular struct: record + push scope for nested fields.
    def visit(node : ::Crystal::CStructOrUnionDef) : Bool
      keyword = node.union? ? "union" : "struct"
      record(node.name, keyword, node.location,
        signature: "#{keyword} #{node.name}",
        doc: node.doc,
      )
      @scope_stack.push(node.name)
      true
    end

    def end_visit(node : ::Crystal::CStructOrUnionDef) : Nil
      @scope_stack.pop
    end

    # `fun foo(args) : Ret` C-binding declaration inside a `lib`.
    def visit(node : ::Crystal::FunDef) : Bool
      sig = String.build do |io|
        io << "fun " << node.name
        io << '(' << node.args.join(", ") { |a| a.to_s }
        io << ", ..." if node.varargs?
        io << ')'
        if ret = node.return_type
          io << " : " << ret
        end
      end
      record(node.name, "fun", node.location, signature: sig, doc: node.doc)
      false
    end

    # `{% begin %}` / `{% if %}` / `{% unless %}` blocks parse as MacroIf with
    # body content stored as MacroLiteral strings, so any `def` inside is
    # invisible to a plain walk (concrete victim: stdlib File.read on some
    # versions). Pull the literal text, parse it, and walk it with the same
    # scope stack. Walk BOTH branches — filtering at index time would hide
    # in-file editing on the "wrong" platform; cross-file platform dedupe is
    # ReachableSet's job. Parse failures (interpolated `{{ var }}`) fall
    # through (they need a real macro evaluator).
    def visit(node : ::Crystal::MacroIf) : Bool
      extract_macro_body_defs(node, node.then)
      extract_macro_body_defs(node, node.else)
      false
    end

    private def extract_macro_body_defs(macro_node : ::Crystal::ASTNode, body : ::Crystal::ASTNode) : Nil
      text = String.build { |io| collect_macro_text(body, io) }
      return if text.strip.empty?
      return if @macro_body_location # don't recurse into nested macros for v1
      ast = (::Crystal::Parser.new(text).parse rescue nil)
      return unless ast
      @macro_body_location = macro_node.location
      begin
        ast.accept(self)
      ensure
        @macro_body_location = nil
      end
    end

    private def collect_macro_text(node : ::Crystal::ASTNode, io : IO) : Nil
      case node
      when ::Crystal::MacroLiteral
        io << node.value
      when ::Crystal::Expressions
        node.expressions.each { |e| collect_macro_text(e, io) }
      end
    end

    # `include Foo` inside a class/module — name resolved lexically at lookup
    # time, like superclasses. Top-level include is beyond what we model.
    def visit(node : ::Crystal::Include) : Bool
      record(node.name.to_s, "include", node.location) unless @scope_stack.empty?
      false
    end

    # `extend Foo` mixes Foo's instance methods in as the enclosing type's
    # CLASS methods. `extend self` is recorded too but the resolver skips it.
    def visit(node : ::Crystal::Extend) : Bool
      record(node.name.to_s, "extend", node.location) unless @scope_stack.empty?
      false
    end

    def visit(node : ::Crystal::VisibilityModifier) : Bool
      # Drive recursion manually to scope @pending_visibility to exactly the
      # wrapped node (no leakage to siblings).
      prev = @pending_visibility
      @pending_visibility = node.modifier
      node.exp.accept(self)
      @pending_visibility = prev
      false
    end

    def visit(node : ::Crystal::ASTNode) : Bool
      true
    end

    private def current_container : String?
      return nil if @scope_stack.empty?
      @scope_stack.join("::")
    end

    private def record(name : String, kind : String, loc, signature : String? = nil, doc : String? = nil, class_method : Bool = false, end_loc = nil, visibility : String? = nil, parent : String? = nil, declared_type : String? = nil, inferred_return : String? = nil, return_ivar : String? = nil) : Nil
      loc = @macro_body_location || loc
      return unless loc
      # Consume buffered annotations — they decorate THIS symbol. Common case
      # is none: share one frozen empty array instead of allocating per symbol.
      if @pending_annotations.empty?
        annotations = EMPTY_ANNOTATIONS
      else
        annotations = @pending_annotations
        @pending_annotations = [] of String
      end
      @symbols << ::Mystral::Entry.new(
        name, kind, @uri,
        loc.line_number - 1,
        loc.column_number - 1,
        signature,
        doc,
        current_container,
        class_method,
        end_loc.try(&.line_number.try { |n| n - 1 }),
        visibility,
        parent,
        declared_type,
        annotations,
        inferred_return,
        return_ivar,
      )
    end

    # Crystal allows `class Foo::Bar::Baz < X` shorthand. Push every leading
    # segment so the leaf records with the right container (`class IO::Memory`
    # → `Memory` with container `"IO"`). end_visit pops as many as segments.
    private def push_outer_segments(segments : Array(String)) : Nil
      return if segments.size <= 1
      segments[0..-2].each { |seg| @scope_stack.push(seg) }
    end
  end
end
