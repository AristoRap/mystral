require "compiler/crystal/syntax"
require "./index/entry"
require "./index/symbol_visitor"
require "./support/symbol_cache"

module Mystral
  # In-memory symbol index: per-URI symbol lists plus a name-keyed secondary
  # index for O(1) name lookup. Single-file reindex is the surface for this
  # increment; the parallel workspace scan, disk symbol cache, and
  # reachability filter land in a later increment.
  class Index
    # File URIs reachable from the workspace's entry points (computed by
    # ReachableSet during the scan). Empty by default → reachability filter
    # off (find_by_name returns all matches). When populated, find_by_name
    # prefers reachable matches, falling back to ALL when none in a container
    # are reachable (stdlib/deps live outside the workspace graph, still
    # resolve).
    property workspace_reachable : Set(String) = Set(String).new

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
      matches = bucket ? bucket.dup : [] of ::Mystral::Entry
      apply_reachability(matches)
    end

    # When workspace_reachable is populated, drop matches OUTSIDE it — but only
    # if at least one reachable match exists IN THE SAME CONTAINER. The
    # per-container fallback matters because find_by_name("open") spans many
    # containers (File, IO, LibC, …); a global filter would let File.open's
    # reachability evict every LibC.open. Per-container keeps each container's
    # fallback independent: platform-split duplicates within ONE container
    # collapse to the reachable ones; containers not in the graph stay visible.
    private def apply_reachability(matches : Array(::Mystral::Entry)) : Array(::Mystral::Entry)
      return matches if @workspace_reachable.empty?
      result = [] of ::Mystral::Entry
      matches.group_by(&.container).each_value do |bucket|
        reachable = bucket.select { |s| @workspace_reachable.includes?(uri_to_path(s.uri)) }
        result.concat(reachable.empty? ? bucket : reachable)
      end
      result
    end

    # ReachableSet keys on absolute paths; index symbols key on file:// URIs.
    private def uri_to_path(uri : String) : String
      uri.starts_with?("file://") ? uri[7..] : uri
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

    # Parses every (uri, source) pair concurrently and assigns results in one
    # pass. Only the main fiber writes @by_uri, so no locking. Work is chunked
    # across N fibers (not one-per-file): a medium file parses in ~0.4ms, less
    # than spawn+channel overhead, so chunking amortizes coordination. Real
    # parallelism only under the MT flags (bench-only); otherwise cooperative.
    def reindex_many(pairs : Enumerable({String, String})) : Nil
      pair_array = pairs.is_a?(Array) ? pairs : pairs.to_a
      return if pair_array.empty?

      worker_count = parse_worker_count
      chunk_size = (pair_array.size + worker_count - 1) // worker_count
      chunks = pair_array.each_slice(chunk_size).to_a

      results = Channel(Array({String, Array(::Mystral::Entry)?})).new
      chunks.each { |chunk| schedule_chunk(chunk, results) }

      chunks.size.times do
        results.receive.each do |uri, symbols|
          replace_uri(uri, symbols) if symbols
        end
      end
    end

    private def schedule_chunk(chunk : Array({String, String}), results : Channel(Array({String, Array(::Mystral::Entry)?}))) : Nil
      job = -> {
        # Every scheduled chunk MUST send exactly once — a short channel count
        # blocks the receiver forever. Guard the whole chunk; degrade to nil
        # symbols rather than let a raise skip the send.
        parsed = begin
          chunk.map { |uri, source| {uri, parse(uri, source).symbols} }
        rescue
          chunk.map { |uri, _source| {uri, nil.as(Array(::Mystral::Entry)?)} }
        end
        results.send(parsed)
      }
      spawn { job.call }
    end

    private def parse_worker_count : Int32
      1 # no real parallelism without the MT flags; one chunk minimizes overhead
    end

    # Directories skipped on a workspace scan — project-artifact locations whose
    # contents shouldn't show up as workspace symbols.
    SCAN_SKIP_DIRS = {"lib", "bin", ".git", ".shards", "node_modules"}

    # Walk `root` for every `.cr` file (skipping SCAN_SKIP_DIRS + exclude_dirs
    # at any depth), read each, and reindex via reindex_many. Safe on a missing
    # root. When `cache` is given (boot path, for rarely-changing roots like the
    # stdlib), a (path, mtime, size) digest is checked first: a HIT deserializes
    # symbols from disk instead of re-parsing; a MISS does the full scan and
    # rewrites the cache. The workspace root passes no cache (it changes).
    def scan_directory(root : String, cache : SymbolCache? = nil, exclude_dirs : Set(String) = Set(String).new) : Nil
      return unless Dir.exists?(root)

      digest = cache.try &.digest_for(root)
      if cache && digest && (grouped = cache.load(root, digest))
        grouped.each { |uri, syms| replace_uri(uri, syms) }
        return
      end

      pairs = [] of {String, String}
      collect_cr_files(root, pairs, exclude_dirs)
      reindex_many(pairs)

      if cache && digest
        grouped = {} of String => Array(::Mystral::Entry)
        pairs.each { |uri, _| grouped[uri] = @by_uri[uri]? || [] of ::Mystral::Entry }
        cache.store(root, digest, grouped)
      end
    end

    private def collect_cr_files(dir : String, pairs : Array({String, String}), exclude_dirs : Set(String) = Set(String).new) : Nil
      Dir.each_child(dir) do |child|
        next if SCAN_SKIP_DIRS.includes?(child) || exclude_dirs.includes?(child)
        full = File.join(dir, child)
        if File.directory?(full)
          collect_cr_files(full, pairs, exclude_dirs)
        elsif child.ends_with?(".cr")
          begin
            pairs << {file_uri(full), File.read(full)}
          rescue
            # Skip files we can't read — they shouldn't kill the whole scan.
          end
        end
      end
    end

    private def file_uri(path : String) : String
      "file://#{File.expand_path(path)}"
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
