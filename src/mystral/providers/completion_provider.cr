require "../server_context"
require "../resolve/text_scanner"
require "../resolve/type_resolver"
require "../lsp/types"
require "../lsp/protocol"

module Mystral
  # textDocument/completion — receiver-aware only. After `Foo.` / `Foo::` (or
  # `Foo.bar` mid-identifier) we list what's actually on the resolved type,
  # filtered by the partial prefix. Bare-prefix completion (typing `pu` and
  # seeing every workspace symbol) is the wall-of-noise case we suppress, the
  # same reason hover does — accepted limitation until type-aware completion.
  class CompletionProvider
    def initialize(@context : ServerContext)
    end

    def completion(params : JSON::Any?) : Array(LSP::CompletionItem)
      empty = [] of LSP::CompletionItem
      return empty unless params
      uri = params["textDocument"]["uri"].as_s
      pos = params["position"]
      line = pos["line"].as_i
      character = pos["character"].as_i

      text = @context.documents.text_for(uri)
      return empty unless text
      scanner = TextScanner.new(text)
      # Inside a comment/string the `.`/identifier is prose, not a receiver.
      return empty if scanner.in_comment_or_string?(line, character)

      ctx = completion_context(text, line, character)
      return empty unless ctx
      chain_expr = ctx[:chain_expr]
      return empty unless chain_expr # bare-prefix completion stays disabled

      resolved = @context.resolver.receiver_resolver.resolve_chain(chain_expr, @context.resolver.chain_at(uri, line), uri, line)
      return empty unless resolved
      resolved = TypeResolver.base_type(resolved)

      # An all-CamelCase chain resolves to a CLASS (`Foo.`, `Foo::Bar.`); any
      # lowercase segment means we evaluated a method call and the receiver is
      # an INSTANCE. That drives class-methods+new vs instance-methods.
      segments = TextScanner.split_chain_segments(chain_expr)
      is_instance = segments.any? { |s| !s[:name][0].uppercase? }

      sep_len = ctx[:sep] == :colon ? 2 : 1
      sep_col = character - ctx[:prefix].size - sep_len
      completions_for_fqn(resolved, ctx[:prefix], ctx[:sep], is_instance, line, sep_col)
    end

    # `{chain_expr, prefix, sep}`: the receiver chain left of the separator
    # (nil → bare-prefix mode), the partial identifier at the cursor, and which
    # separator preceded it.
    private def completion_context(text : String, line : Int32, character : Int32)
      lines = text.split('\n')
      return nil if line < 0 || line >= lines.size
      l = lines[line]
      return nil if character < 0 || character > l.size

      start = character
      while start > 0 && TextScanner.word_char?(l[start - 1])
        start -= 1
      end
      prefix = l[start...character]

      sep_len = 0
      if start >= 1 && l[start - 1] == '.'
        sep_len = 1
      elsif start >= 2 && l[start - 2] == ':' && l[start - 1] == ':'
        sep_len = 2
      end

      chain_expr = nil
      if sep_len > 0
        before_sep = l[0...start - sep_len]
        chain_expr = TextScanner.chain_expr_at_end(before_sep).presence
      end

      sep = sep_len == 2 ? :colon : (sep_len == 1 ? :dot : :none)
      {chain_expr: chain_expr, prefix: prefix, sep: sep}
    end

    private def completions_for_fqn(resolved : String, prefix : String, sep : Symbol, is_instance : Bool, line : Int32, sep_col : Int32) : Array(LSP::CompletionItem)
      results = [] of LSP::CompletionItem
      seen = Set(String).new
      @context.index.each_symbol do |s|
        next unless s.container == resolved
        next unless relevant_for_separator?(s, sep, is_instance)
        # Completing from outside the class — private/protected aren't callable.
        next unless s.visibility.nil?

        # Crystal sugar: `Foo.new(...)` invokes `Foo#initialize`; surface `new`.
        label = (s.kind == "def" && s.name == "initialize" && !s.class_method?) ? "new" : s.name

        next unless prefix.empty? || label.starts_with?(prefix)
        # Dedupe overloads of the same rendered signature.
        key = "#{label}|#{s.signature}"
        next if seen.includes?(key)
        seen << key

        # Nested type picked after `Foo.`: Crystal needs `::`. Keep the primary
        # insertion as-is, add an edit rewriting the single `.` to `::`.
        extra_edits = nil.as(Array(LSP::TextEdit)?)
        if sep == :dot && TypeResolver.container_kind?(s.kind)
          extra_edits = [LSP::TextEdit.new(
            LSP::Range.new(
              LSP::Position.new(line, sep_col),
              LSP::Position.new(line, sep_col + 1),
            ),
            "::",
          )]
        end

        results << LSP::CompletionItem.new(label, completion_item_kind(s.kind), s.signature, s.doc, extra_edits)
      end
      results
    end

    # What's valid after each separator. `Foo.`: class methods (+ macros) and
    # `new`, NOT nested types (Crystal parses `Foo.Item` as a call). `obj.`:
    # instance methods (not initialize). `Foo::`: nested types only.
    private def relevant_for_separator?(s : ::Mystral::Entry, sep : Symbol, is_instance : Bool) : Bool
      case sep
      when :dot
        case s.kind
        when "def"   then is_instance ? !s.class_method? && s.name != "initialize" : (s.class_method? || s.name == "initialize")
        when "macro" then true
        else
          # Nested types are valid after `.` only on a class receiver (we
          # attach the `.`→`::` edit); instance receivers can't reach them.
          !is_instance && TypeResolver.container_kind?(s.kind)
        end
      when :colon
        TypeResolver.container_kind?(s.kind)
      else
        false
      end
    end

    private def completion_item_kind(kind : String) : Int32
      case kind
      when "class"  then LSP::CompletionItemKind::CLASS
      when "struct" then LSP::CompletionItemKind::STRUCT
      when "module" then LSP::CompletionItemKind::MODULE
      when "enum"   then LSP::CompletionItemKind::ENUM
      when "def"    then LSP::CompletionItemKind::METHOD
      when "macro"  then LSP::CompletionItemKind::FUNCTION
      else               LSP::CompletionItemKind::TEXT
      end
    end
  end
end
