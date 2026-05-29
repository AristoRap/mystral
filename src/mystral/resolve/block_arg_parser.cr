require "./text_scanner"

module Mystral
  # Block-argument analysis: detect that the cursor is inside a `|...|` block
  # parameter list and extract which call/parameter it belongs to, and parse
  # block parameter types out of a rendered def signature. Pure functions over
  # text + signature strings (no index).
  #
  # v1 limitation: same-line shape only — the call, the `do`/`{`, and the
  # `|...|` must be on one line. Multi-line block headers defer.
  module BlockArgParser
    extend self

    # `{arg_index, chain, method_name}` when the cursor is inside a
    # `chain.method[(args)] do |x, y|` / `{ |x, y| ... }` block-param list, or
    # nil. Bare-method blocks (no receiver chain) defer for v1.
    def find_block_arg_context(text : String, line : Int32, character : Int32) : NamedTuple(arg_index: Int32, chain: String, method_name: String)?
      lines = text.split('\n')
      return nil if line < 0 || line >= lines.size
      l = lines[line]
      return nil unless character > 0 && character <= l.size

      pipe_col = nil.as(Int32?)
      i = character - 1
      while i >= 0
        c = l[i]
        if c == '|'
          pipe_col = i
          break
        end
        break unless c.alphanumeric? || c == '_' || c == ',' || c == ' ' || c == '\t' || c == '*' || c == '&'
        i -= 1
      end
      return nil unless pipe_col

      pre = l[0...pipe_col].rstrip
      call_end = if pre.ends_with?("do")
                   pre.size - 2
                 elsif pre.ends_with?('{')
                   pre.size - 1
                 else
                   return nil
                 end

      arg_index = l[(pipe_col + 1)...character].count(',')

      call_text = l[0...call_end].rstrip
      return nil if call_text.empty?

      # Skip a trailing `(args)` group back to the method name (single line).
      if call_text.ends_with?(')')
        depth = 1
        j = call_text.size - 2
        while j >= 0 && depth > 0
          case call_text[j]
          when ')' then depth += 1
          when '(' then depth -= 1
          end
          j -= 1
        end
        return nil if depth != 0
        call_text = call_text[0..j]
      end

      expr = TextScanner.chain_expr_at_end(call_text)
      return nil if expr.empty?

      segments = TextScanner.split_chain_segments(expr)
      return nil if segments.size < 2 # bare-method calls deferred

      last_sep_pos = expr.rindex("::")
      last_dot = expr.rindex('.')
      sep_pos = if last_sep_pos && last_dot
                  Math.max(last_sep_pos, last_dot)
                else
                  last_sep_pos || last_dot
                end
      return nil unless sep_pos
      method_start = sep_pos + (expr[sep_pos] == ':' ? 2 : 1)
      chain_str = expr[0...sep_pos]
      method = expr[method_start..]

      {arg_index: arg_index, chain: chain_str, method_name: method}
    end

    # True when the cursor sits inside a `|...|` block-param list. Unlike
    # find_block_arg_context it doesn't require the call to resolve, so
    # bare-name blocks (`loop do |x|`) qualify — used to gate enrichment.
    def cursor_in_block_params?(text : String, line : Int32, character : Int32) : Bool
      lines = text.split('\n')
      return false if line < 0 || line >= lines.size
      l = lines[line]
      return false unless character > 0 && character <= l.size

      i = character - 1
      while i >= 0
        c = l[i]
        break if c == '|'
        return false unless c.alphanumeric? || c == '_' || c == ',' || c == ' ' || c == '\t' || c == '*' || c == '&'
        i -= 1
      end
      return false if i < 0

      pre = l[0...i].rstrip
      pre.ends_with?("do") || pre.ends_with?('{')
    end

    # The block parameter types from a rendered def signature, in
    # `&block : T1, T2 -> R` order, or nil when there's no block param. Empty
    # list when the block takes no args (`& : -> Nil`).
    def parse_block_param_types(signature : String?) : Array(String)?
      return nil unless signature
      open = signature.index('(')
      return nil unless open

      depth = 1
      i = open + 1
      while i < signature.size
        c = signature[i]
        case c
        when '(', '[', '{'
          depth += 1
          i += 1
        when ')', ']', '}'
          depth -= 1
          i += 1
          return nil if depth == 0
        when '&'
          if depth == 1
            i += 1
            while i < signature.size && TextScanner.word_char?(signature[i])
              i += 1
            end
            while i < signature.size && signature[i] == ' '
              i += 1
            end
            return nil unless i < signature.size && signature[i] == ':'
            i += 1
            while i < signature.size && signature[i] == ' '
              i += 1
            end
            return capture_block_types(signature, i)
          else
            i += 1
          end
        else
          i += 1
        end
      end
      nil
    end

    # Capture `T1, T2 -> R` from `start`; returns the arg-type list (the
    # return type after `->` is ignored — block-arg hover cares about inputs).
    private def capture_block_types(signature : String, start : Int32) : Array(String)?
      types = [] of String
      seg_start = start
      depth = 0
      i = start
      while i < signature.size - 1
        c = signature[i]
        nc = signature[i + 1]
        if c == '(' || c == '[' || c == '{'
          depth += 1
        elsif c == ')' || c == ']' || c == '}'
          return nil if depth == 0
          depth -= 1
        elsif depth == 0 && c == '-' && nc == '>'
          seg = signature[seg_start...i].strip
          types << seg unless seg.empty?
          return types
        elsif depth == 0 && c == ','
          seg = signature[seg_start...i].strip
          types << seg unless seg.empty?
          seg_start = i + 1
        end
        i += 1
      end
      nil
    end
  end
end
