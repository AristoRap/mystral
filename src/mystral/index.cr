require "compiler/crystal/syntax"
require "./index/entry"
require "./index/symbol_visitor"

module Mystral
  # In-memory symbol index: per-URI symbol lists plus a name-keyed secondary
  # index for O(1) name lookup. Single-file reindex is the surface for this
  # increment; the parallel workspace scan, disk symbol cache, and
  # reachability filter land in a later increment.
  class Index
    def initialize
      @by_uri = Hash(String, Array(::Mystral::Entry)).new
      # Secondary name index, derived from @by_uri and kept in sync on every
      # reindex/remove so find_by_name is O(1)+|matches| instead of scanning
      # every symbol. The per-name list preserves @by_uri insertion order so
      # callers that do `.find { ... }` get the same "first" match.
      @by_name = Hash(String, Array(::Mystral::Entry)).new
    end

    # Returns the parse exception when the source is invalid (the caller
    # publishes diagnostics from it), nil when the parse succeeded. On failure
    # we KEEP the previously indexed symbols, so the user still has navigation
    # against the last good version while editing.
    def reindex(uri : String, source : String) : ::Crystal::SyntaxException?
      result = parse(uri, source)
      if syms = result.symbols
        replace_uri(uri, syms)
      end
      result.error
    end

    def remove(uri : String) : Nil
      if old = @by_uri.delete(uri)
        unindex_names(old)
      end
    end

    def symbols_in(uri : String) : Array(::Mystral::Entry)
      @by_uri[uri]? || [] of ::Mystral::Entry
    end

    # Every URI we've indexed. Workspace-wide handlers (e.g. references)
    # iterate this. Order is insertion order; callers needing determinism sort.
    def uris : Array(String)
      @by_uri.keys
    end

    def find_by_name(name : String) : Array(::Mystral::Entry)
      bucket = @by_name[name]?
      # `.dup` keeps the internal bucket immune to caller mutation. Cheap —
      # it's an array of struct values.
      bucket ? bucket.dup : [] of ::Mystral::Entry
    end

    def each_symbol(& : ::Mystral::Entry ->) : Nil
      @by_uri.each_value do |syms|
        syms.each { |s| yield s }
      end
    end

    # Type kinds that can key reaped hierarchy ancestry (have a superclass /
    # are a hierarchy node).
    ANCESTRY_TYPE_KINDS = {"class", "struct", "module"}

    # FQNs of every type defined in a file under one of `roots` — the user's
    # own code. Used to scope reaped `crystal tool hierarchy` ancestry to
    # workspace types (stdlib/dep ancestry resolves via the already-indexed
    # types). Matches the FQN shape ancestry keys use.
    def workspace_type_names(roots : Array(String)) : Set(String)
      names = Set(String).new
      each_symbol do |s|
        next unless ANCESTRY_TYPE_KINDS.includes?(s.kind)
        path = s.uri.lchop("file://")
        next unless roots.any? { |r| path == r || path.starts_with?("#{r}/") }
        names << (s.container ? "#{s.container}::#{s.name}" : s.name)
      end
      names
    end

    # Atomic swap for one URI: drop the previous symbols' name-index entries,
    # then append the new ones. Keeps @by_name in sync without rebuilding it.
    private def replace_uri(uri : String, syms : Array(::Mystral::Entry)) : Nil
      if old = @by_uri[uri]?
        unindex_names(old)
      end
      @by_uri[uri] = syms
      syms.each do |s|
        (@by_name[s.name] ||= [] of ::Mystral::Entry) << s
      end
    end

    # Removes each entry from its @by_name bucket. Entry is a struct so
    # Array#delete matches by ==; sibling entries from the same URI but a
    # different line/column compare unequal, so only the exact value is
    # dropped.
    private def unindex_names(syms : Array(::Mystral::Entry)) : Nil
      syms.each do |s|
        next unless bucket = @by_name[s.name]?
        bucket.delete(s)
        @by_name.delete(s.name) if bucket.empty?
      end
    end

    private record ParseResult,
      symbols : Array(::Mystral::Entry)?,
      error : ::Crystal::SyntaxException?

    private def parse(uri : String, source : String) : ParseResult
      parser = ::Crystal::Parser.new(source)
      parser.filename = uri
      # Capture leading doc comments on every node that has a `doc` property.
      # Costs nothing — the parser already sees the comment tokens; this stops
      # it discarding them. Hover surfaces docs no other Crystal LSP does.
      parser.wants_doc = true
      ast = parser.parse
      symbols = [] of ::Mystral::Entry
      ast.accept(SymbolVisitor.new(uri, symbols))
      ParseResult.new(symbols, nil)
    rescue ex : ::Crystal::SyntaxException
      ParseResult.new(nil, ex)
    rescue ex
      # Faults other than SyntaxException (the lexer's InvalidByteSequenceError
      # on malformed UTF-8, a visitor bug) must not escape: in a spawned parse
      # fiber that would skip the channel send and hang the scan. No location
      # to anchor a squiggle, so report no symbols and no diagnostic.
      ParseResult.new(nil, nil)
    end
  end
end
