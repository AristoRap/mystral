require "./text_scanner"

module Mystral
  # The lexical facts about one cursor position, computed once per request via
  # a TextScanner and carried as a value object. Providers read these fields
  # instead of re-deriving them (word_at + receiver_at + ivar_kind each
  # re-scan the line) — both cheaper and a single source of truth.
  struct CursorContext
    getter uri : String
    getter line : Int32
    getter character : Int32
    # The identifier under the cursor (nil if not on one).
    getter word : String?
    # The receiver expression to its left, ending in `.`/`::` (nil if none).
    getter receiver : String?
    # "ivar" / "cvar" when the cursor is on an `@field` / `@@var`, else nil.
    getter ivar_kind : String?
    # True when the cursor is inside a comment or string literal.
    getter in_comment_or_string : Bool
    # The start column of the identifier the cursor is inside (token-anchored
    # position for side-index / enrichment keying), nil if not on one.
    getter identifier_start_col : Int32?

    def initialize(@uri, @line, @character, @word, @receiver, @ivar_kind,
                   @in_comment_or_string, @identifier_start_col)
    end

    # Build the context for `(line, character)` in `uri` from a scanner.
    def self.at(uri : String, scanner : TextScanner, line : Int32, character : Int32) : CursorContext
      new(
        uri, line, character,
        scanner.word_at(line, character),
        scanner.receiver_at(line, character),
        scanner.ivar_kind_at(line, character),
        scanner.in_comment_or_string?(line, character),
        scanner.identifier_start_at(line, character),
      )
    end

    # True when the cursor is on a real identifier and not in a comment/string
    # — the precondition for any symbol resolution.
    def on_identifier? : Bool
      !word.nil? && !in_comment_or_string
    end
  end
end
