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

    # Compile every target and group errors by the real path of the file they
    # live in, deduped per file (a file reachable from two entries would
    # otherwise report each error twice). Keyed by real_path because the
    # compiler resolves requires through symlinks.
    def errors_grouped_by_realpath(targets : Array(String), log : IO, debug : Bool) : Hash(String, Array(CrystalError))
      grouped = Hash(String, Array(CrystalError)).new
      seen = Hash(String, Set({Int32, Int32, Int32, String})).new
      targets.each do |target|
        compile_errors(target, log, debug).each do |e|
          ef = e.file
          next unless ef
          rp = real_path(ef)
          key = {e.line || 0, e.column || 0, e.size || 0, e.message}
          per_file = seen[rp] ||= Set({Int32, Int32, Int32, String}).new
          next if per_file.includes?(key)
          per_file << key
          (grouped[rp] ||= [] of CrystalError) << e
        end
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
