require "compiler/crystal/syntax"

module Mystral
  # Pure AST → display-string / inferred-type helpers used by SymbolVisitor.
  #
  # Every method here is a pure function of its AST-node argument(s): no
  # access to scope, symbol accumulation, or any visitor state. That's what
  # lets it live in its own file as a genuine collaborator (called, not mixed
  # in) and be unit-tested directly against parsed nodes.
  module SignatureRenderer
    extend self

    # Wrap signatures whose inline form exceeds this many characters — one arg
    # per line with a hanging close paren, matching `crystal tool format`.
    SIGNATURE_WRAP_THRESHOLD = 100

    # Full `def` signature, optionally prefixed with a visibility modifier.
    def signature_for(node : ::Crystal::Def, visibility : ::Crystal::Visibility? = nil) : String
      parts = [] of String

      # Positional args. The splat arg (if any) lives inline at splat_index;
      # prefix it with "*". double_splat and block_arg are separate Def
      # fields, NOT inside `args`.
      node.args.each_with_index do |arg, i|
        prefix = (node.splat_index == i) ? "*" : ""
        parts << render_arg(arg, prefix)
      end

      if ds = node.double_splat
        parts << render_arg(ds, "**")
      end

      if ba = node.block_arg
        # "&" prefix. An anonymous proc block (`& : Options::Menu ->`) has an
        # empty arg name, so render_arg yields "& : Options::Menu ->".
        parts << render_arg(ba, "&")
      end

      ret = ""
      if rt = node.return_type
        ret = " : #{render_type(rt)}"
      end

      visibility_prefix = case visibility
                          when ::Crystal::Visibility::Private   then "private "
                          when ::Crystal::Visibility::Protected then "protected "
                          else                                       ""
                          end
      receiver_prefix = node.receiver ? "#{node.receiver}." : ""
      head = "#{visibility_prefix}def #{receiver_prefix}#{node.name}"

      inline = "#{head}(#{parts.join(", ")})#{ret}"
      return inline if inline.size <= SIGNATURE_WRAP_THRESHOLD || parts.empty?

      String.build do |io|
        io << head << "(\n"
        parts.each { |p| io << "  " << p << ",\n" }
        io << ')' << ret
      end
    end

    # `macro NAME(args)` preview. Macro params reuse the def arg shapes; the
    # only differences are the keyword and that macros carry no return type.
    def macro_signature(node : ::Crystal::Macro) : String
      parts = [] of String
      node.args.each_with_index do |arg, i|
        parts << render_arg(arg, (node.splat_index == i) ? "*" : "")
      end
      if ds = node.double_splat
        parts << render_arg(ds, "**")
      end
      if ba = node.block_arg
        parts << render_arg(ba, "&")
      end
      parts.empty? ? "macro #{node.name}" : "macro #{node.name}(#{parts.join(", ")})"
    end

    # `enum Name\n  Member1\n  Member2 = 2\nend` preview, rendered as a fenced
    # block by hover. Methods inside the enum body get their own symbol via
    # visit(Def) and are skipped here so the preview stays scannable.
    def enum_signature(node : ::Crystal::EnumDef) : String
      String.build do |io|
        io << "enum " << node.name
        if base = node.base_type
          io << " : " << base
        end
        io << "\n"
        node.members.each do |m|
          if m.is_a?(::Crystal::Arg)
            io << "  " << m.name
            if dv = m.default_value
              io << " = " << dv
            end
            io << "\n"
          end
        end
        io << "end"
      end
    end

    # Same inline-vs-wrapped rule as signature_for, for the synthetic
    # `initialize` of a `record` macro.
    def wrap_initialize_signature(field_strs : Array(String)) : String
      head = "def initialize"
      inline = "#{head}(#{field_strs.join(", ")})"
      return inline if inline.size <= SIGNATURE_WRAP_THRESHOLD || field_strs.empty?
      String.build do |io|
        io << head << "(\n"
        field_strs.each { |f| io << "  " << f << ",\n" }
        io << ')'
      end
    end

    def render_arg(arg : ::Crystal::Arg, prefix : String) : String
      s = prefix + arg.name
      if r = arg.restriction
        s += " : #{render_type(r)}"
      end
      if dv = arg.default_value
        s += " = #{dv}"
      end
      s
    end

    # `ASTNode#to_s` wraps `ProcNotation` in parens (`Foo ->` -> `(Foo ->)`),
    # which is valid Crystal but doesn't match what the user typed in
    # `& : Foo ->`. Render proc notations inline at the top level; nested
    # procs keep the to_s parens (they need the grouping).
    def render_type(node : ::Crystal::ASTNode) : String
      return normalize_type_str(node.to_s) unless node.is_a?(::Crystal::ProcNotation)
      inputs = node.inputs.try(&.map(&.to_s).join(", ")) || ""
      output = node.output.try(&.to_s) || ""
      normalize_type_str("#{inputs}#{inputs.empty? ? "" : " "}->#{output.empty? ? "" : " #{output}"}")
    end

    # Strip the absolute-path marker `::` the parser emits on top-level
    # constants — most visibly `IO?` -> `IO | ::Nil`, which we display as
    # `IO | Nil`. The lookbehind keeps namespaced paths intact: only a LEADING
    # `::` (start of string, or after ` `, `|`, `(`, `,`) is removed.
    def normalize_type_str(s : String) : String
      s.gsub(/(?<![A-Za-z0-9_:])::/, "")
    end

    # Best-effort type of a default-value/RHS literal, AST only. Precise where
    # the literal declares element types (`[] of T`, `{} of K => V`), a bare
    # `Array`/`Hash` for an untyped collection literal, the scalar mapping
    # otherwise. nil when we genuinely can't tell (a call, a const).
    def infer_default_literal_type(node : ::Crystal::ASTNode) : String?
      case node
      when ::Crystal::ArrayLiteral
        (of = node.of) ? "Array(#{normalize_type_str(of.to_s)})" : "Array"
      when ::Crystal::HashLiteral
        if of = node.of
          "Hash(#{normalize_type_str(of.key.to_s)}, #{normalize_type_str(of.value.to_s)})"
        else
          "Hash"
        end
      else
        infer_literal_return(node)
      end
    end

    # Best-effort type of an assignment's RHS, AST only. `Type.new` /
    # `Type::Nested.new` → the type; otherwise the literal mapping. nil for
    # anything needing real inference (a method call, a variable, a branch).
    def infer_assigned_type(value : ::Crystal::ASTNode) : String?
      if value.is_a?(::Crystal::Call) && value.name == "new" && (obj = value.obj) && obj.is_a?(::Crystal::Path)
        return normalize_type_str(obj.to_s)
      end
      infer_default_literal_type(value)
    end

    # The bare instance/class-var name when `body` is exactly a single `@x` /
    # `@@x` read (`def name; @name; end`), sigil stripped; nil otherwise. A
    # one-element Expressions wrapper is unwrapped; anything more is not a bare
    # read.
    def bare_var_read_name(body : ::Crystal::ASTNode) : String?
      node = body
      if node.is_a?(::Crystal::Expressions) && node.expressions.size == 1
        node = node.expressions.first
      end
      case node
      when ::Crystal::InstanceVar then node.name.lstrip('@')
      when ::Crystal::ClassVar    then node.name.lstrip('@')
      else                             nil
      end
    end

    # Return type when a def's whole body is a single bare read of a typed
    # positional parameter (`def echo(x : Int32); x; end` → Int32). The splat
    # param is excluded (`*x` reads as a Tuple, not its element type). nil for
    # an untyped param, a splat, or any non-bare body. Resolves fully at index
    # time (the param type is right here on the def).
    def bare_param_read_type(node : ::Crystal::Def) : String?
      body = node.body
      body = body.expressions.first if body.is_a?(::Crystal::Expressions) && body.expressions.size == 1
      return nil unless body.is_a?(::Crystal::Var)
      node.args.each_with_index do |arg, i|
        next unless arg.name == body.name
        return nil if node.splat_index == i
        r = arg.restriction
        return r ? normalize_type_str(r.to_s) : nil
      end
      nil
    end

    def infer_literal_return(body : ::Crystal::ASTNode) : String?
      case body
      when ::Crystal::StringLiteral then "String"
      when ::Crystal::BoolLiteral   then "Bool"
      when ::Crystal::CharLiteral   then "Char"
      when ::Crystal::SymbolLiteral then "Symbol"
      when ::Crystal::NilLiteral    then "Nil"
      when ::Crystal::NumberLiteral then number_literal_type(body)
      else                               nil
      end
    end

    def number_literal_type(n : ::Crystal::NumberLiteral) : String
      case n.kind
      when .i8?   then "Int8"
      when .i16?  then "Int16"
      when .i32?  then "Int32"
      when .i64?  then "Int64"
      when .i128? then "Int128"
      when .u8?   then "UInt8"
      when .u16?  then "UInt16"
      when .u32?  then "UInt32"
      when .u64?  then "UInt64"
      when .u128? then "UInt128"
      when .f32?  then "Float32"
      when .f64?  then "Float64"
      else             "Int32"
      end
    end
  end
end
