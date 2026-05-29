module Mystral
  # Turns raw document text + a cursor position into the lexical facts the
  # resolver and providers need: the identifier under the cursor, the receiver
  # to its left, whether it's an ivar/cvar, and whether the cursor sits in a
  # comment/string. Also enumerates identifier occurrences for highlight /
  # references.
  #
  # Splits the text into lines ONCE at construction; every query reads the
  # cached `@lines`. All the boundary rules (suffix handling, sigil-snap)
  # live here in one place so hover, highlight, references, and completion
  # can never disagree about what the identifier at a position "is".
  class TextScanner
    # Crystal keywords that look like a variable receiver but aren't — bail so
    # the caller falls back to bare-name lookup (e.g. `def self.foo` with the
    # cursor on `foo` must NOT treat `self` as a variable receiver).
    KEYWORD_RECEIVERS = {"self", "super", "nil", "true", "false"}

    getter lines : Array(String)

    def initialize(text : String)
      @lines = text.split('\n')
    end

    # The identifier at the cursor, honoring Crystal's method-name suffixes
    # (`!`, `?`, `=`). Snaps onto an ivar/cvar name when the cursor is on the
    # `@`/`@@` sigil. nil when the cursor isn't on an identifier.
    def word_at(line : Int32, character : Int32) : String?
      return nil if line < 0 || line >= @lines.size
      l = @lines[line]
      return nil if character < 0 || character > l.size

      # Anchor on the char under the cursor. Method names can end in `!`/`?`/
      # `=`, treated as a suffix to a normal-word run. If the cursor is one
      # past the identifier (typical editor behavior), step back one char.
      anchor = character
      if anchor == l.size || !TextScanner.identifier_char?(l[anchor])
        # Sigil at cursor: `@`/`@@` aren't identifier chars but are inseparable
        # from the name that follows — snap right onto it.
        if anchor < l.size && l[anchor] == '@'
          skip = (anchor + 1 < l.size && l[anchor + 1] == '@') ? 2 : 1
          if anchor + skip < l.size && TextScanner.identifier_char?(l[anchor + skip])
            anchor += skip
          else
            return nil if anchor == 0 || !TextScanner.identifier_char?(l[anchor - 1])
            anchor -= 1
          end
        else
          return nil if anchor == 0 || !TextScanner.identifier_char?(l[anchor - 1])
          anchor -= 1
        end
      end

      # Find the start by walking left through word chars only — suffix chars
      # never appear inside an identifier.
      start_col = anchor
      while start_col > 0 && TextScanner.word_char?(l[start_col - 1])
        start_col -= 1
      end
      # If start_col landed on a suffix-only char, there's no real identifier
      # (e.g. cursor on `==` between two ints).
      return nil unless start_col < l.size && TextScanner.word_char?(l[start_col])

      end_col = start_col
      while end_col < l.size && TextScanner.word_char?(l[end_col])
        end_col += 1
      end

      # Allow one trailing `!`/`?`/`=` as part of the method name. `=` must NOT
      # swallow `==`/`=>`. `?` must NOT swallow nilable shorthand (`Foo?` =
      # `Foo | Nil`), recognized by the CamelCase shape (methods are
      # snake_case, types CamelCase).
      if end_col < l.size
        c = l[end_col]
        if c == '!'
          end_col += 1
        elsif c == '?'
          end_col += 1 unless l[start_col].uppercase?
        elsif c == '='
          next_c = (end_col + 1 < l.size) ? l[end_col + 1] : '\0'
          end_col += 1 unless next_c == '=' || next_c == '>'
        end
      end

      l[start_col...end_col]
    end

    # The receiver expression immediately left of the cursor's word, ending in
    # `.` or `::`. A CamelCase qualified chain (`Foo::Bar`, `Foo.Bar`
    # normalized to `Foo::Bar`) takes priority; otherwise the variable chain
    # ending at the separator (`@app`, `@app.event`, `Foo.event.dispatch`).
    # nil when there's no receiver, or it's a keyword.
    def receiver_at(line : Int32, character : Int32) : String?
      return nil if line < 0 || line >= @lines.size
      l = @lines[line]
      return nil if character < 0 || character > l.size

      start = character
      start -= 1 if start == l.size || !TextScanner.word_char?(l[start])
      while start > 0 && TextScanner.word_char?(l[start - 1])
        start -= 1
      end

      return nil if start <= 0
      sep_len = if l[start - 1] == '.'
                  1
                elsif start >= 2 && l[start - 2] == ':' && l[start - 1] == ':'
                  2
                else
                  return nil
                end

      prefix = l[0...start - sep_len]
      # Allow an optional `(...)` tail on the trailing segment so
      # `Set(String).new` / `Hash(K, V).new` resolve as `Set` / `Hash`.
      if m = prefix.match(/([A-Z][A-Za-z0-9_]*(?:(?:::|\.)[A-Z][A-Za-z0-9_]*)*)(?:\([^()]*\))?\z/)
        m[1].gsub('.', "::")
      elsif prefix.match(/(@?[a-z_][A-Za-z0-9_]*)\z/)
        full = TextScanner.chain_expr_at_end(prefix)
        return nil if full.empty?
        return nil if KEYWORD_RECEIVERS.includes?(full)
        full
      else
        nil
      end
    end

    # "ivar" / "cvar" when the cursor sits on an `@field` / `@@var` name (or on
    # the sigil itself), nil otherwise. Same cursor-snap as word_at. Returns
    # the index `kind` so callers can filter `s.kind == ivar_kind_at(...)`.
    def ivar_kind_at(line : Int32, character : Int32) : String?
      return nil if line < 0 || line >= @lines.size
      l = @lines[line]

      start_col = character
      if start_col < l.size && l[start_col] == '@'
        skip = (start_col + 1 < l.size && l[start_col + 1] == '@') ? 2 : 1
        start_col += skip
      end
      start_col -= 1 if start_col == l.size || !TextScanner.word_char?(l[start_col])
      while start_col > 0 && TextScanner.word_char?(l[start_col - 1])
        start_col -= 1
      end
      return nil unless start_col > 0 && l[start_col - 1] == '@'
      (start_col > 1 && l[start_col - 2] == '@') ? "cvar" : "ivar"
    end

    # True when the cursor sits inside a `#` line comment or a string/char
    # literal — positions where an identifier-shaped token is prose or string
    # data, not a symbol reference. `#{...}` interpolation is tracked as CODE
    # (returns false there) so a real variable inside it still resolves.
    # Single-line scan; heredocs / %-literals spanning lines aren't modeled.
    def in_comment_or_string?(line : Int32, character : Int32) : Bool
      return false if line < 0 || line >= @lines.size
      l = @lines[line]
      in_string = false
      delim = '\0'
      interp_depth = 0
      i = 0
      while i < l.size && i < character
        c = l[i]
        if in_string && interp_depth == 0
          if c == '\\'
            i += 2
            next
          elsif c == '#' && i + 1 < l.size && l[i + 1] == '{'
            interp_depth = 1
            i += 2
            next
          elsif c == delim
            in_string = false
          end
        elsif interp_depth > 0
          if c == '{'
            interp_depth += 1
          elsif c == '}'
            interp_depth -= 1
          end
        else
          if c == '"' || c == '\''
            in_string = true
            delim = c
          elsif c == '#'
            return true # comment runs to end of line
          end
        end
        i += 1
      end
      in_string && interp_depth == 0
    end

    # The start column of the identifier the cursor is inside — used to
    # normalize the cursor to one position per token (so side-index reads /
    # enrichment requests key consistently regardless of which char is
    # hovered). nil when not on an identifier.
    def identifier_start_at(line : Int32, character : Int32) : Int32?
      return nil unless line >= 0 && line < @lines.size
      start = nil.as(Int32?)
      TextScanner.scan_identifiers(@lines[line]) do |s, e, _name|
        start = s if s <= character && character <= e
      end
      start
    end

    # Yields `(line, start_col, end_col)` (end exclusive) for every identifier
    # equal to `target`, across all lines — the shared enumerator for
    # documentHighlight (one file) and references (workspace-wide), using the
    # exact suffix-aware rules word_at uses.
    def each_identifier_match(target : String, &block : Int32, Int32, Int32 ->) : Nil
      @lines.each_with_index do |l, ln|
        TextScanner.scan_identifiers(l) do |start_col, end_col, name|
          yield ln, start_col, end_col if name == target
        end
      end
    end

    # Yields every identifier in line `l` as `(start_col, end_col, name)`,
    # end-col exclusive. Mirrors word_at so the substring at
    # `(start_col...end_col)` is exactly what word_at returns for any cursor
    # inside that span (locked by a property spec).
    def self.scan_identifiers(l : String, &block : Int32, Int32, String ->) : Nil
      i = 0
      while i < l.size
        c = l[i]
        if c.letter? || c == '_'
          start_col = i
          while i < l.size && word_char?(l[i])
            i += 1
          end
          end_col = i
          if end_col < l.size
            sc = l[end_col]
            if sc == '!'
              end_col += 1
            elsif sc == '?'
              end_col += 1 unless l[start_col].uppercase?
            elsif sc == '='
              next_c = (end_col + 1 < l.size) ? l[end_col + 1] : '\0'
              end_col += 1 unless next_c == '=' || next_c == '>'
            end
          end
          yield start_col, end_col, l[start_col...end_col]
          i = end_col
        elsif c.number?
          # Skip a numeric literal run — identifiers can't start with a digit,
          # but a bare `123` would otherwise be picked up by word_char?.
          while i < l.size && (l[i].alphanumeric? || l[i] == '_' || l[i] == '.')
            i += 1
          end
        else
          i += 1
        end
      end
    end

    # Split a receiver expression like `@app.event` or `Foo::Bar.baz` into
    # ordered identifier segments with the separator preceding each (the first
    # is `:none`). Bails on the first unrecognized char — a partial chain
    # returns the part it could parse. A leading `@`/`@@` is valid only on the
    # first segment (ivars).
    def self.split_chain_segments(s : String) : Array(NamedTuple(name: String, sep: Symbol))
      result = [] of NamedTuple(name: String, sep: Symbol)
      i = 0
      while i < s.size
        sep = :none.as(Symbol)
        if !result.empty?
          if s[i] == '.'
            sep = :dot
            i += 1
          elsif i + 1 < s.size && s[i] == ':' && s[i + 1] == ':'
            sep = :double_colon
            i += 2
          else
            return result
          end
        end

        seg_start = i
        if result.empty?
          while i < s.size && s[i] == '@'
            i += 1
          end
        end
        while i < s.size && word_char?(s[i])
          i += 1
        end
        if i < s.size && (s[i] == '?' || s[i] == '!')
          i += 1
        end

        return result if seg_start == i
        result << {name: s[seg_start...i], sep: sep}
      end
      result
    end

    # The trailing chain expression of `s` (`...x.foo.bar` → `x.foo.bar`).
    def self.chain_expr_at_end(s : String) : String
      i = s.size
      while i > 0
        c = s[i - 1]
        if c.alphanumeric? || c == '_' || c == '@' || c == '.' || c == '?' || c == '!'
          i -= 1
        elsif i >= 2 && s[i - 2] == ':' && s[i - 1] == ':'
          i -= 2
        else
          break
        end
      end
      s[i..]
    end

    # Strict identifier body chars (walking left/right to find the bare name).
    def self.word_char?(c : Char) : Bool
      c.alphanumeric? || c == '_'
    end

    # Chars the cursor may sit on to count as "inside an identifier": word
    # chars plus the Crystal method-name suffixes.
    def self.identifier_char?(c : Char) : Bool
      word_char?(c) || c == '!' || c == '?' || c == '='
    end
  end
end
