require "../server_context"
require "../resolve/text_scanner"
require "../resolve/signature_params"
require "../lsp/types"

module Mystral
  # textDocument/signatureHelp — the popup that follows the cursor through call
  # arguments (triggers on `(` and `,`). Reuses the same chain resolver as
  # hover/completion; the only new piece is call_site_at, which walks back
  # through balanced delimiters to the enclosing `(` and the method before it,
  # counting depth-0 commas for the active parameter index.
  class SignatureHelpProvider
    def initialize(@context : ServerContext)
    end

    def signature_help(params : JSON::Any?) : LSP::SignatureHelp?
      return nil unless params
      uri = params["textDocument"]["uri"].as_s
      pos = params["position"]
      line = pos["line"].as_i
      character = pos["character"].as_i

      text = @context.documents.text_for(uri)
      return nil unless text

      call = call_site_at(text, line, character)
      return nil unless call
      method = call[:method]
      return nil unless method
      receiver = call[:receiver]
      active_param = call[:param_idx]

      matches = if receiver
                  resolved = @context.resolver.receiver_resolver.resolve_chain(receiver, @context.resolver.chain_at(uri, line), uri, line)
                  return nil unless resolved
                  on_type = @context.index.find_by_name(method).select { |s| s.kind == "def" && s.container == resolved && s.visibility.nil? }
                  # Crystal sugar: `Foo.new(...)` → `Foo#initialize`.
                  if method == "new" && on_type.empty?
                    on_type = @context.index.find_by_name("initialize").select { |s| s.kind == "def" && s.container == resolved && s.visibility.nil? }
                  end
                  on_type
                else
                  # No receiver — same-file only (same rule as bare hover).
                  @context.index.find_by_name(method).select { |s| s.kind == "def" && s.uri == uri && s.visibility.nil? }
                end
      return nil if matches.empty?

      sigs = matches.map { |s| signature_information_for(s, active_param) }
      LSP::SignatureHelp.new(sigs, 0, active_param)
    end

    # `{receiver, method, param_idx}` when the cursor is inside
    # `<method>(...arg, |cursor|...)`, else nil. Tracks delimiter depth so
    # commas in nested calls / literals don't count.
    private def call_site_at(text : String, line : Int32, character : Int32)
      lines = text.split('\n')
      return nil if line < 0 || line >= lines.size
      l = lines[line]
      return nil if character < 0 || character > l.size

      depth = 0
      param_idx = 0
      pos = character - 1
      while pos >= 0
        case l[pos]
        when ')', ']', '}'
          depth += 1
        when '(', '[', '{'
          if depth == 0
            break if l[pos] == '('
            return nil # walked out of a non-paren delimiter first
          end
          depth -= 1
        when ','
          param_idx += 1 if depth == 0
        end
        pos -= 1
      end
      return nil if pos < 0

      name_end = pos
      name_start = pos
      while name_start > 0 && TextScanner.word_char?(l[name_start - 1])
        name_start -= 1
      end
      return nil if name_start == name_end
      method = l[name_start...name_end]

      receiver = nil
      prefix = nil
      if name_start >= 1 && l[name_start - 1] == '.'
        prefix = l[0...name_start - 1]
      elsif name_start >= 2 && l[name_start - 2] == ':' && l[name_start - 1] == ':'
        prefix = l[0...name_start - 2]
      end
      if prefix
        if m = prefix.match(/([A-Z][A-Za-z0-9_]*(?:(?:::|\.)[A-Z][A-Za-z0-9_]*)*)\z/)
          receiver = m[1].gsub('.', "::")
        else
          receiver = TextScanner.chain_expr_at_end(prefix).presence
        end
      end

      {receiver: receiver, method: method, param_idx: param_idx}
    end

    private def signature_information_for(s : ::Mystral::Entry, active_param : Int32) : LSP::SignatureInformation
      sig = s.signature || "def #{s.name}(...)"
      params = parameter_offsets_from(sig).map do |label, range|
        LSP::ParameterInformation.new(label, range)
      end
      LSP::SignatureInformation.new(sig, params, s.doc, active_param)
    end

    # Each parameter's label + `[start, end]` offset into the signature string
    # (VSCode highlights the offset form reliably). ASCII signatures, so UTF-16
    # and UTF-8 offsets coincide.
    private def parameter_offsets_from(signature : String) : Array({String, Tuple(Int32, Int32)})
      result = [] of {String, Tuple(Int32, Int32)}
      SignatureParams.each_top_level_param(signature) do |start, finish|
        push_param(result, signature, start, finish)
      end
      result
    end

    private def push_param(acc : Array({String, Tuple(Int32, Int32)}), sig : String, start : Int32, finish : Int32) : Nil
      trimmed_start = start
      while trimmed_start < finish && sig[trimmed_start].whitespace?
        trimmed_start += 1
      end
      trimmed_end = finish
      while trimmed_end > trimmed_start && sig[trimmed_end - 1].whitespace?
        trimmed_end -= 1
      end
      return if trimmed_end <= trimmed_start
      acc << {sig[trimmed_start...trimmed_end], {trimmed_start, trimmed_end}}
    end
  end
end
