require "digest/sha256"

module Mystral
  # Precomputed semantic facts, reaped from background `crystal build
  # --no-codegen` / `crystal tool` runs and served on the hover hot path as a
  # plain map lookup. Reading a cached fact is NOT analysis, so it's allowed on
  # the request path — the invokes that PRODUCE these facts stay on the
  # background worker.
  #
  # Every fact is tagged with the content-version of the buffer it was computed
  # against. A read serves a fact only while that version still equals the live
  # buffer's; any mismatch returns nil (caller falls back to the AST answer)
  # and drops the stale bucket. So the index can never surface a type inferred
  # against stale content — "current truth or nothing".
  #
  # Single-fiber safe without locks: the request fiber reads, the compile-worker
  # fiber writes, and Crystal's cooperative scheduler never yields mid-method
  # here. MT flags are bench-only; revisit if that changes.
  class InferenceIndex
    # A single resolved fact at a source position (just the type FQN for now).
    record Fact, type : String

    # Canonical content-version of a buffer — a content hash, not a counter/TTL:
    # identical content ⇒ identical version, invalidated the instant a byte
    # changes. Computed off the hot path; the hover path compares two digests.
    def self.version(text : String) : String
      Digest::SHA256.hexdigest(text)
    end

    # Cap on tracked URIs (bounded RAM). Coarse clear on overflow — a dropped
    # bucket only costs a re-compute, never a wrong answer.
    MAX_URIS = 512

    private record Bucket, version : String, facts : Hash(Tuple(Int32, Int32), Fact)

    # Scope-keyed local types from one `crystal tool context` run: the tool
    # returns the type of EVERY local in scope at a position, so one invoke
    # types a whole method's locals — keyed by the enclosing scope (the def's
    # start line, or -1 for top-level) so any hover of any of them resolves
    # without re-compiling.
    private record LocalsBucket, version : String, by_scope : Hash(Int32, Hash(String, String))

    def initialize
      @by_uri = {} of String => Bucket
      @locals = {} of String => LocalsBucket
      # Program-global superclass ancestry from `crystal tool hierarchy`: type
      # FQN → ancestor FQNs (closest-first), generic args normalized off.
      # Ground truth for what the parser's name-resolution can't reach (generic
      # supers, macro-derived types). Replaced wholesale each settled compile,
      # consulted ONLY as the walk_parents fallback.
      @ancestry = {} of String => Array(String)
    end

    def set_ancestry(map : Hash(String, Array(String))) : Nil
      @ancestry = map
    end

    # Ancestor FQNs of `type_fqn` (closest-first), or nil when none reaped.
    def ancestors_of(type_fqn : String) : Array(String)?
      @ancestry[type_fqn]?
    end

    # Store the full `name → type` map of locals in one scope, tagged with
    # `version`. A version change starts a fresh per-uri bucket; same version
    # merges scopes in.
    def set_scope_locals(uri : String, version : String, scope_key : Int32, types : Hash(String, String)) : Nil
      bucket = @locals[uri]?
      unless bucket && bucket.version == version
        @locals.clear if @locals.size >= MAX_URIS && !@locals.has_key?(uri)
        bucket = LocalsBucket.new(version, {} of Int32 => Hash(String, String))
        @locals[uri] = bucket
      end
      bucket.by_scope[scope_key] = types
    end

    # Type of local `name` in `scope_key` of `uri`, only if the stored map's
    # version matches the live buffer's. Mismatch ⇒ nil + drop the bucket.
    def scope_local_type(uri : String, version : String, scope_key : Int32, name : String) : String?
      bucket = @locals[uri]?
      return nil unless bucket
      if bucket.version != version
        @locals.delete(uri)
        return nil
      end
      bucket.by_scope[scope_key]?.try(&.[name]?)
    end

    # Replace all position-facts for `uri`, tagged with their buffer `version`.
    def put(uri : String, version : String, facts : Hash(Tuple(Int32, Int32), Fact)) : Nil
      @by_uri.clear if @by_uri.size >= MAX_URIS && !@by_uri.has_key?(uri)
      @by_uri[uri] = Bucket.new(version, facts)
    end

    # The fact at (line, col), only if its bucket's version still matches.
    # Mismatch ⇒ nil AND drop the bucket (never re-serve a stale fact).
    def fact_at(uri : String, version : String, line : Int32, col : Int32) : Fact?
      bucket = @by_uri[uri]?
      return nil unless bucket
      if bucket.version != version
        @by_uri.delete(uri)
        return nil
      end
      bucket.facts[{line, col}]?
    end

    # Drop a URI's facts entirely (e.g. on didClose). No-op if absent.
    def forget(uri : String) : Nil
      @by_uri.delete(uri)
      @locals.delete(uri)
    end
  end
end
