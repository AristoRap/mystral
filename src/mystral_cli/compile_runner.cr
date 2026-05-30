require "json"
require "digest/sha256"

module MystralCLI
  # Runs `crystal build --no-codegen` subprocesses and shapes their output:
  # the parsed error list, grouped by the real path of the file each error
  # lives in, plus the reachable-content digest used to skip redundant
  # recompiles. No in-process compiler — the subprocess is process-isolated.
  module CompileRunner
    extend self

    NUL = "\0"

    # Dependency / VCS dirs excluded from the workspace content digest.
    SKIP_DIRS = {"lib", "bin", ".git", ".shards", "node_modules"}

    # One element of `crystal build --format json`:
    #   [{"file":"...","line":4,"column":14,"size":9,"message":"..."}]
    struct CrystalError
      include JSON::Serializable
      getter file : String?
      getter line : Int32?
      getter column : Int32?
      getter size : Int32?
      getter message : String
    end

    # One fail-fast error and the call/expansion stack leading to it. `crystal
    # build` stops at the first error and emits its frames innermost-LAST, so
    # the JSON array's last element is the REAL error and the rest are context
    # ("instantiating 'a(Int32)'", "expanding macro"). Surfacing the frames as
    # their own squiggles is noise — and for a bad macro call the frame points
    # at the macro body, not the user's typo. We keep the real error as the
    # diagnostic and carry the frames as relatedInformation.
    struct ErrorTrace
      getter error : CrystalError
      getter frames : Array(CrystalError)

      def initialize(@error : CrystalError, @frames : Array(CrystalError))
      end
    end

    # Run one target and return its parsed error list ([] when clean or the
    # output isn't parseable).
    def compile_errors(target : String, log : IO, debug : Bool) : Array(CrystalError)
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(
        "crystal",
        ["build", "--no-codegen", "--no-color", "--format", "json", target],
        output: stdout, error: stderr,
      )
      return [] of CrystalError if status.success?

      # `--format json` writes the array to stderr; fall back to stdout.
      raw = stderr.to_s.strip
      raw = stdout.to_s.strip if raw.empty?
      return [] of CrystalError unless raw.starts_with?("[")
      Array(CrystalError).from_json(raw)
    rescue ex : JSON::ParseException
      log_debug(log, debug, "compile_runner: #{target} JSON parse failed: #{ex.message}")
      [] of CrystalError
    end

    # Compile every target and collect each one's error trace, grouped by the
    # real path of the file the REAL error lives in (a frame-only file is never
    # squiggled — it appears as relatedInformation instead). Deduped by the real
    # error's identity, since a file reachable from two entries would otherwise
    # report the same error twice. Keyed by real_path because the compiler
    # resolves requires through symlinks.
    def errors_grouped_by_realpath(targets : Array(String), log : IO, debug : Bool) : Hash(String, Array(ErrorTrace))
      grouped = Hash(String, Array(ErrorTrace)).new
      seen = Set({String, Int32, Int32, Int32, String}).new
      targets.each do |target|
        errs = compile_errors(target, log, debug)
        next if errs.empty?
        real = errs.last
        ef = real.file
        next unless ef
        rp = real_path(ef)
        key = {rp, real.line || 0, real.column || 0, real.size || 0, real.message}
        next if seen.includes?(key)
        seen << key
        (grouped[rp] ||= [] of ErrorTrace) << ErrorTrace.new(real, errs[0...-1])
      end
      grouped
    end

    def real_path(path : String) : String
      File.realpath(path)
    rescue
      path
    end

    def read_file(path : String) : String?
      File.read(path)
    rescue
      nil
    end

    def under_root?(path : String, root : String) : Bool
      prefix = root.ends_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
      path == root || path.starts_with?(prefix)
    end

    # Digest of everything that can change a compile's result without being a
    # fixed/external input: every workspace `.cr` (deps excluded) + each root's
    # shard.lock. stdlib is treated as fixed for the server's lifetime.
    # Over-inclusive on purpose — an extra recompile is safe, a missed change
    # would be a stale squiggle. A loose file with no root hashes just itself.
    def reachable_content_digest(path : String, roots : Array(String)) : String
      digest = Digest::SHA256.new
      root = roots.find { |r| under_root?(path, r) }
      if root
        workspace_cr_files(root).each do |file|
          digest.update(file); digest.update(NUL)
          digest.update(read_file(file) || ""); digest.update(NUL)
        end
        if lock_text = read_file(File.join(root, "shard.lock"))
          digest.update("shard.lock"); digest.update(NUL); digest.update(lock_text)
        end
      else
        digest.update(read_file(path) || "")
      end
      digest.hexfinal
    end

    private def workspace_cr_files(root : String) : Array(String)
      files = [] of String
      gather_workspace_cr(root, files)
      files.sort!
    end

    private def gather_workspace_cr(dir : String, acc : Array(String)) : Nil
      Dir.each_child(dir) do |child|
        next if SKIP_DIRS.includes?(child)
        full = File.join(dir, child)
        if File.directory?(full)
          gather_workspace_cr(full, acc)
        elsif child.ends_with?(".cr")
          acc << full
        end
      end
    rescue
      # Unreadable dir — an over/under-walk only changes recompile frequency.
    end

    private def log_debug(log : IO, debug : Bool, message : String) : Nil
      return unless debug
      log.puts "[#{Time.local.to_s("%H:%M:%S.%L")}] #{message}"
    end
  end
end
