require "../server_context"
require "../resolve/block_arg_parser"

module Mystral
  # Fires background `crystal tool context` enrichment for a local the AST
  # can't type, and owns the dedup set that stops a thin hover re-firing on
  # every mouse-over. One instance is shared by the hover provider (which
  # fires) and the lifecycle provider (which forgets keys on a content change
  # so a fixed/reverted buffer re-fires rather than staying stuck).
  class EnrichmentRequester
    MAX_ENRICH_REQUESTS = 4096

    def initialize(@context : ServerContext)
      # Keyed uri\0version\0scope\0name. A different content-version makes a
      # fresh key (old facts are stale anyway); keys are pruned on a version
      # change so returning to a seen version re-fires.
      @requested = Set(String).new
    end

    # Fire enrichment for an unresolved local. Gated: an enricher must exist;
    # the name must be local-shaped (lowercase/underscore); it must be a real
    # in-scope local assignment or block param (never compile for a typo'd
    # method); and we must know the buffer's version. Returns true when it
    # newly fired (so hover can show a "resolving…" hint).
    def request(uri : String, text : String, line : Int32, character : Int32, name : String) : Bool
      enrich = @context.enricher
      return false unless enrich
      first = name[0]?
      return false unless first && (first.lowercase? || first == '_')
      unless has_local_assignment?(name, uri, text, line) || BlockArgParser.cursor_in_block_params?(text, line, character)
        return false
      end
      version = @context.documents.version(uri)
      return false unless version
      scope_key = enclosing_def_start(uri, line)
      key = "#{uri}\0#{version}\0#{scope_key}\0#{name}"
      return false if @requested.includes?(key)
      @requested.clear if @requested.size >= MAX_ENRICH_REQUESTS
      @requested << key
      enrich.call(uri, line, character, scope_key)
      true
    end

    # Drop every dedup key for `uri` (all versions) — on a content-version
    # change or close, the keys reference content that no longer matches and
    # the facts they guarded are evicted; keeping them would suppress a
    # legitimate re-request (the dead "resolving…" state after a fix/revert).
    def forget(uri : String) : Nil
      prefix = "#{uri}\0"
      @requested.select(&.starts_with?(prefix)).each { |k| @requested.delete(k) }
    end

    # Start line of the def enclosing `line`, or -1 at top level. The scope key
    # the enrichment populator and the hover reader agree on, so one context
    # run types a whole method's locals.
    def enclosing_def_start(uri : String, line : Int32) : Int32
      d = @context.index.symbols_in(uri).find do |s|
        s.kind == "def" && s.line <= line && (e = s.end_line) && line <= e
      end
      d ? d.line : -1
    end

    # True when an assignment to local `name` exists at/above `line` in the
    # enclosing def (or from file start at top level) — tells us `name` is a
    # local we failed to type (worth a compile) vs. a typo'd method (not).
    private def has_local_assignment?(name : String, uri : String, text : String, line : Int32) : Bool
      enclosing = @context.index.symbols_in(uri).find do |s|
        s.kind == "def" && s.line <= line && (e = s.end_line) && line <= e
      end
      scan_start = enclosing ? enclosing.line + 1 : 0
      lines = text.split('\n')
      assign_re = /\A\s*#{Regex.escape(name)}\s*=(?![=>])/
      scan_start.upto(line) do |ln|
        next unless ln >= 0 && ln < lines.size
        return true if lines[ln] =~ assign_re
      end
      false
    end
  end
end
