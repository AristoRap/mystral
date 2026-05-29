require "../server_context"
require "../lsp/types"
require "../index/entry"

module Mystral
  # One hover item to render. A definition carries a `signature` (rendered as a
  # crystal code block); a value reference carries a `type` (rendered as
  # ` : Type` with click-through links); a pending enrichment sets `pending`.
  record HoverEntry,
    role : String,
    name : String,
    source_uri : String? = nil,
    source_line : Int32? = nil,
    type : String? = nil,
    type_suffix : String? = nil,
    signature : String? = nil,
    doc : String? = nil,
    annotations : Array(String) = [] of String,
    inferred_return : String? = nil,
    pending : Bool = false

  # The SINGLE markdown renderer every hover funnels through, plus the
  # type-name qualification/linking helpers. One visual language: a bold
  # (clickable) header, then a signature block for definitions or a ` : Type`
  # line for value references, then docs / inferred return.
  class HoverRenderer
    def initialize(@context : ServerContext)
      @index = @context.index
      @types = @context.resolver.type_resolver
      @scopes = @context.resolver.scope_walker
    end

    def render_markup(entries : Array(HoverEntry)) : LSP::MarkupContent
      LSP::MarkupContent.new("markdown", render_entries(entries))
    end

    # Render the matches of a name lookup as definition hovers.
    def render_hover(matches : Array(::Mystral::Entry)) : LSP::MarkupContent
      render_markup(matches.map { |s| entry_from_symbol(s) })
    end

    # Qualify every type-name token in `t` to its FQN against the cursor's
    # lexical scope, so the renderer can link each one. A bare `Item` and the
    # `Item` inside `Array(Item)` resolve identically; unresolvable tokens
    # (type vars, primitives absent from the index) pass through.
    def fqn_for_type_expr(t : String, uri : String, line : Int32) : String
      chain = @scopes.chain_at(uri, line)
      t.gsub(/[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*/) do |token|
        @types.resolve_receiver(token, chain) || token
      end
    end

    private def render_entries(entries : Array(HoverEntry)) : String
      String.build do |io|
        entries.each_with_index do |e, i|
          io << "\n---\n\n" if i > 0
          if (uri = e.source_uri) && (ln = e.source_line)
            # Definition: the signature block states the kind via its keyword,
            # so the header is just the bold, clickable name.
            io << "**[" << e.name << "](" << uri << "#L" << (ln + 1) << ")**"
          else
            # Value reference: the (role) label carries what it is.
            io << "**(" << e.role << ")** `" << e.name << "`"
          end

          if sig = e.signature
            io << "\n\n```crystal\n"
            e.annotations.each { |a| io << a << "\n" }
            io << sig << "\n```\n"
          elsif e.pending
            io << " : _resolving type…_\n"
          elsif type = e.type
            io << " : " << markdown_type_link(type)
            io << e.type_suffix.not_nil! unless e.type_suffix.nil?
            io << "\n"
            render_annotation_block(io, e.annotations)
          else
            io << "\n"
            render_annotation_block(io, e.annotations)
          end

          if doc = e.doc
            io << "\n" << doc.rstrip << "\n"
          end
          if inferred = e.inferred_return
            io << "\n_inferred return: `" << inferred << "`_\n"
          end
        end
      end
    end

    private def render_annotation_block(io : IO, annotations : Array(String)) : Nil
      return if annotations.empty?
      io << "```crystal\n"
      annotations.each { |a| io << a << "\n" }
      io << "```\n"
    end

    # Link every resolvable qualified type name inside a type expression,
    # leaving separators and unresolved names untouched. Markdown links don't
    # render inside backticks, so the caller keeps the type outside any `...`.
    private def markdown_type_link(type_expr : String) : String
      type_expr.gsub(/[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*/) do |token|
        simple, container = TypeResolver.split_fqn(token)
        sym = @index.find_by_name(simple).find do |s|
          s.container == container && TypeResolver.type_kind?(s.kind)
        end
        sym ? "[#{token}](#{sym.uri}#L#{sym.line + 1})" : token
      end
    end

    # Role word for the `(role)` header of an index symbol's kind.
    private def role_for(kind : String) : String
      case kind
      when "def"   then "method"
      when "const" then "constant"
      when "ivar"  then "instance variable"
      when "cvar"  then "class variable"
      else              kind
      end
    end

    # Header name for a definition: the container for methods/macros (the
    # signature block already shows `def name(...)`), the FQN for types.
    private def header_name(s : ::Mystral::Entry) : String
      container = s.container
      case s.kind
      when "def", "macro", "fun"
        container || s.name
      else
        container ? "#{container}::#{s.name}" : s.name
      end
    end

    private def entry_from_symbol(s : ::Mystral::Entry) : HoverEntry
      inferred = (s.kind == "def" && s.declared_type.nil?) ? s.inferred_return : nil
      # A hand-written getter (`def name; @name; end`) reads an ivar; resolve
      # its DECLARED type now that the whole index is built.
      inferred ||= resolve_return_ivar(s) if s.kind == "def" && s.declared_type.nil?
      HoverEntry.new(
        role: role_for(s.kind),
        name: header_name(s),
        source_uri: s.uri,
        source_line: s.line,
        signature: s.signature,
        doc: s.doc,
        annotations: s.annotations,
        inferred_return: inferred,
      )
    end

    # Declared type of the ivar/cvar a getter-def reads, looked up in the def's
    # own container. nil when not found / untyped — we only surface a return we
    # can state for certain.
    private def resolve_return_ivar(s : ::Mystral::Entry) : String?
      name = s.return_ivar
      return nil unless name
      @index.find_by_name(name).find do |e|
        (e.kind == "ivar" || e.kind == "cvar") && e.container == s.container
      end.try(&.declared_type)
    end
  end
end
