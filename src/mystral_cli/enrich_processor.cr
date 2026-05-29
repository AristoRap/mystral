require "json"
require "../mystral/server_context"
require "../mystral/support/workspace_entries"
require "../mystral/inference_index"

module MystralCLI
  # Builds the on-demand enrichment closure wired into the server (via
  # use_enricher). When a hover on a local can't be typed from the AST, the
  # hover provider fires this with (uri, line, char, scope_key); we run
  # `crystal tool context` off the hot path and stash the resolved types in the
  # side-index so the next hover there is precise.
  #
  # Shells out (never links the compiler). `crystal tool context` returns the
  # types of every local in scope at a position, so one invoke answers several
  # nearby hovers.
  #
  # Soundness: the tool reads DISK, so the stored fact is tagged with the disk
  # content-version. The reader compares the live BUFFER's version, so a fact
  # is served only when buffer == disk — an unsaved edit diverges the versions
  # and the reader falls back to the AST answer.
  module EnrichProcessor
    extend self

    # `crystal tool context -f json`:
    #   {"status":"ok","contexts":[{"arr":"Array(Foo)"}]}
    struct ContextResult
      include JSON::Serializable
      getter status : String
      getter contexts : Array(Hash(String, String)) = [] of Hash(String, String)
    end

    # First context's var→type map, or nil on non-ok / no contexts / unparseable.
    def context_types(json : String) : Hash(String, String)?
      result = ContextResult.from_json(json)
      return nil unless result.status == "ok"
      result.contexts.first?
    rescue JSON::ParseException
      nil
    end

    # The synchronous core (testable without a fiber): read the hovered file
    # from disk, run `crystal tool context` against the program entry with the
    # cursor in that file, store the WHOLE in-scope map under `scope_key`,
    # tagged with the disk content-version. No-op on any miss.
    def enrich_now(inference : Mystral::InferenceIndex, uri : String, line : Int32, char : Int32, scope_key : Int32, roots : Array(String), log : IO, debug : Bool = false) : Nil
      path = uri_to_path(uri)
      return unless path && File.exists?(path)
      disk = read_file(path)
      return unless disk
      version = Mystral::InferenceIndex.version(disk)

      json = run_context(enrich_target(path, roots), path, line, char)
      return unless json
      types = context_types(json)
      return unless types && !types.empty?

      inference.set_scope_locals(uri, version, scope_key, types)
      log_debug(log, debug, "enrich_processor: #{uri} scope #{scope_key} reaped #{types.size} local(s)")
    rescue ex
      log.puts "[#{Time.local.to_s("%H:%M:%S.%L")}] enrich_processor: #{uri} EXCEPTION #{ex.class}: #{ex.message}"
    end

    # The fire-and-forget closure the hover provider calls. Spawns so the hover
    # never blocks on the compile. Captures the shared inference + roots.
    def build(context : Mystral::ServerContext, log : IO, debug : Bool = false) : Proc(String, Int32, Int32, Int32, Nil)
      roots = context.workspace_roots
      inference = context.inference
      ->(uri : String, line : Int32, char : Int32, scope_key : Int32) do
        spawn { enrich_now(inference, uri, line, char, scope_key, roots, log, debug) }
        nil
      end
    end

    # Run `crystal tool context` with the cursor at (line, char) — LSP is
    # 0-indexed, the tool wants 1-indexed. Compile target is the program entry.
    private def run_context(target : String, cursor_file : String, line : Int32, char : Int32) : String?
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(
        "crystal",
        ["tool", "context", "--no-color", "-f", "json", target, "-c", "#{cursor_file}:#{line + 1}:#{char + 1}"],
        output: stdout, error: stderr,
      )
      return nil unless status.success?
      raw = stdout.to_s.strip
      raw.starts_with?("{") ? raw : nil
    end

    # Program entry to compile for context: prefer an EXECUTABLE main (context
    # only types methods the program actually calls; a library entry calls
    # nothing), fall back to the library entry, then the file itself.
    private def enrich_target(path : String, roots : Array(String)) : String
      root = roots.find { |r| under_root?(path, r) }
      return path unless root
      Mystral::WorkspaceEntries.executable_mains(root).first? ||
        Mystral::WorkspaceEntries.discover(root).first? ||
        path
    end

    private def under_root?(path : String, root : String) : Bool
      prefix = root.ends_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
      path == root || path.starts_with?(prefix)
    end

    private def uri_to_path(uri : String) : String?
      return nil unless uri.starts_with?("file://")
      uri[7..]
    end

    private def read_file(path : String) : String?
      File.read(path)
    rescue
      nil
    end

    private def log_debug(log : IO, debug : Bool, message : String) : Nil
      return unless debug
      log.puts "[#{Time.local.to_s("%H:%M:%S.%L")}] #{message}"
    end
  end
end
