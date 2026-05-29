require "../server_context"
require "../resolve/text_scanner"
require "../resolve/block_arg_parser"
require "../resolve/signature_params"
require "./hover_renderer"
require "./enrichment_requester"

module Mystral
  # textDocument/hover — the sub-50ms flagship, parser-only. Dispatch order
  # mirrors Crystal's own name resolution at a cursor:
  #   ivar/cvar (`@x`) → parameter → block parameter → local → name lookup.
  # The ivar path is exclusive: a cursor on `@field` never falls through to a
  # same-spelled parameter (the param is sigil-stripped in the signature, so a
  # naive match can't tell them apart) — returning nil there is the honest
  # result; flashing the param would lie about identity.
  #
  # The compile-reaped side-index read and on-demand enrichment hook in at a
  # later increment (top and bottom of this dispatch respectively); for now
  # hover is purely AST/index-derived.
  class HoverProvider
    def initialize(@context : ServerContext, @enrichment : EnrichmentRequester)
      @renderer = HoverRenderer.new(@context)
    end

    def hover(params : JSON::Any?) : LSP::MarkupContent?
      return nil unless params
      uri = params["textDocument"]["uri"].as_s
      pos = params["position"]
      line = pos["line"].as_i
      character = pos["character"].as_i

      text = @context.documents.text_for(uri)
      return nil unless text
      scanner = TextScanner.new(text)
      # Suppress hover inside a comment or string literal (interpolation is
      # code, deliberately not suppressed).
      return nil if scanner.in_comment_or_string?(line, character)
      name = scanner.word_at(line, character)
      return nil unless name

      # Normalize the cursor to the identifier's START column so the side-index
      # read and the enrichment request key off one position per token.
      col = scanner.identifier_start_at(line, character) || character

      # Side-index first: an enriched type reaped from a background run, served
      # at parser speed as a map lookup — but only while its content-version
      # matches the live buffer (else AST fallback, never a stale type).
      if md = inferred_hover(uri, line, col, name)
        return md
      end

      receiver = scanner.receiver_at(line, character)

      if receiver.nil?
        # Cursor on `@field` / `@@var`: dispatch exclusively to the ivar path.
        if scanner.ivar_kind_at(line, character)
          return instance_var_hover(uri, scanner, line, character, name)
        end
        # Parameters shadow same-named methods inside a def body — check first.
        if md = parameter_hover(uri, line, name)
          return md
        end
        if md = block_arg_hover(uri, text, line, character, name)
          return md
        end
        if md = local_var_hover(uri, line, name)
          return md
        end
        if md = accessor_decl_hover(uri, line, col, name)
          return md
        end
      end

      matches = @context.resolver.matches_at(name, uri, receiver, line)
      return @renderer.render_hover(matches) unless matches.empty?

      # Nothing resolved. If this is a local the AST can't type, fire a
      # background enrichment so the next hover here is precise; show a hint
      # rather than an empty hover when we actually fire.
      if receiver.nil? && @enrichment.request(uri, text, line, col, name)
        return @renderer.render_markup([HoverEntry.new(role: "local", name: name, pending: true)])
      end
      nil
    end

    # Read a compile-reaped fact for the identifier and render it; nil (→ AST
    # fallback) when no version, no fact, or a stale version (the version gate
    # is what keeps this from ever showing a stale type — see InferenceIndex).
    private def inferred_hover(uri : String, line : Int32, col : Int32, name : String) : LSP::MarkupContent?
      version = @context.documents.version(uri)
      return nil unless version
      scope_key = @enrichment.enclosing_def_start(uri, line)
      if type = @context.inference.scope_local_type(uri, version, scope_key, name)
        return @renderer.render_markup([HoverEntry.new(role: "inferred", name: name, type: type)])
      end
      if fact = @context.inference.fact_at(uri, version, line, col)
        return @renderer.render_markup([HoverEntry.new(role: "inferred", name: name, type: fact.type)])
      end
      nil
    end

    private def receiver_resolver
      @context.resolver.receiver_resolver
    end

    # `@field` / `@@var`: indexed declaration first (carries declared_type +
    # annotations), then a body-assignment fallback for ivars the visitor
    # couldn't model.
    private def instance_var_hover(uri : String, scanner : TextScanner, line : Int32, character : Int32, name : String) : LSP::MarkupContent?
      kind = scanner.ivar_kind_at(line, character)
      return nil unless kind
      is_cvar = kind == "cvar"

      @context.resolver.chain_at(uri, line).each do |scope|
        entry = @context.index.find_by_name(name).find do |s|
          s.kind == kind && s.container == scope
        end
        next unless entry
        if type = entry.declared_type
          return render_var_hover(is_cvar, name, type, entry.annotations)
        end
      end

      return nil if is_cvar
      type = receiver_resolver.ivar_type_via_body_assignment(uri, line, name)
      return nil unless type
      render_var_hover(false, name, type)
    end

    private def render_var_hover(is_cvar : Bool, name : String, type : String, annotations : Array(String) = [] of String) : LSP::MarkupContent
      role = is_cvar ? "class variable" : "instance variable"
      sigil = is_cvar ? "@@" : "@"
      @renderer.render_markup([HoverEntry.new(role: role, name: "#{sigil}#{name}", type: type, annotations: annotations)])
    end

    private def parameter_hover(uri : String, line : Int32, name : String) : LSP::MarkupContent?
      enclosing = @context.index.symbols_in(uri).select do |s|
        (s.kind == "def" || s.kind == "proc") &&
          s.line <= line &&
          (end_line = s.end_line) &&
          line <= end_line
      end.max_by?(&.line)
      return nil unless enclosing

      label = SignatureParams.parameter_label_for(enclosing.signature, name)
      return nil unless label
      @renderer.render_markup([param_entry(label, uri, line)])
    end

    # A `name : Type [= default]` parameter label as a hover entry: the name is
    # the header, the type resolved to an FQN for linking, a default value
    # carried as a backticked suffix.
    private def param_entry(label : String, uri : String, line : Int32) : HoverEntry
      colon = label.index(" : ")
      return HoverEntry.new(role: "parameter", name: label) unless colon
      pname = label[0...colon]
      rest = label[(colon + 3)..]
      eq = rest.index(" = ")
      type_str = eq ? rest[0...eq] : rest
      suffix = eq ? "`#{rest[eq..]}`" : nil
      HoverEntry.new(role: "parameter", name: pname, type: @renderer.fqn_for_type_expr(type_str, uri, line), type_suffix: suffix)
    end

    private def block_arg_hover(uri : String, text : String, line : Int32, character : Int32, name : String) : LSP::MarkupContent?
      ctx = BlockArgParser.find_block_arg_context(text, line, character)
      return nil unless ctx

      lookup = @context.resolver.chain_at(uri, line)
      resolved = receiver_resolver.resolve_chain(ctx[:chain], lookup, uri, line)
      return nil unless resolved

      def_sym = nil.as(::Mystral::Entry?)
      @context.resolver.scope_walker.inheritance_chain(resolved).each do |scope|
        if found = @context.resolver.type_resolver.find_def_on(ctx[:method_name], scope)
          def_sym = found
          break
        end
      end
      return nil unless def_sym

      block_types = BlockArgParser.parse_block_param_types(def_sym.signature)
      return nil unless block_types
      arg_type = block_types[ctx[:arg_index]]?
      return nil unless arg_type

      @renderer.render_markup([HoverEntry.new(role: "block parameter", name: name, type: @renderer.fqn_for_type_expr(arg_type, uri, line))])
    end

    private def local_var_hover(uri : String, line : Int32, name : String) : LSP::MarkupContent?
      type = receiver_resolver.infer_local_var_type(name, uri, line)
      return nil unless type
      @renderer.render_markup([HoverEntry.new(role: "local", name: name, type: type)])
    end

    # A `?`/`!` accessor (`getter? x`, `getter! x`) synthesizes its reader under
    # the name `x?` / `x!`, so a plain-name lookup on the declaration token `x`
    # finds nothing (the backing ivar is reachable only via `@x`). Resolve the
    # token to its reader def — anchored at THIS exact declaration position so it
    # can never match an unrelated `x?`/`x!` elsewhere in the file.
    private def accessor_decl_hover(uri : String, line : Int32, col : Int32, name : String) : LSP::MarkupContent?
      reader = @context.index.symbols_in(uri).find do |s|
        s.kind == "def" && s.line == line && s.column == col &&
          (s.name == "#{name}?" || s.name == "#{name}!")
      end
      return nil unless reader
      @renderer.render_hover([reader])
    end
  end
end
