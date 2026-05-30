require "./compile_runner"
require "../mystral/lsp/types"

module MystralCLI
  # Detects unresolved requires in a compile's output and turns them into a
  # located shard.yml diagnostic + a toast. When requires don't resolve the
  # program never loaded, so the compile's other "errors" are require-chain
  # noise — we suppress those and point at the real problem (a dependency)
  # instead of spraying squiggles on require lines.
  module MissingRequires
    extend self

    DIAGNOSTIC_SEVERITY_ERROR = 1

    # Crystal's require-resolution failure: `can't find file 'radix'`.
    REQUIRE_NOT_FOUND_RE = /can't find file '([^']+)'/

    # The require targets the compile couldn't resolve. Non-empty ⇒ the program
    # never loaded.
    def detect(grouped : Hash(String, Array(CompileRunner::ErrorTrace))) : Set(String)
      names = Set(String).new
      grouped.each_value do |traces|
        traces.each do |t|
          if m = t.error.message.match(REQUIRE_NOT_FOUND_RE)
            names << m[1]
          end
        end
      end
      names
    end

    def message(missing : Set(String)) : String
      names = missing.to_a.sort.join(", ")
      plural = missing.size > 1
      "mystral: can't resolve require#{plural ? "s" : ""} #{names} — run `shards install`? " \
      "Semantic checks are paused until dependencies resolve."
    end

    # One Error diagnostic per unresolved require, anchored on shard.yml at the
    # declaring dependency (or the top of the file when undeclared/relative).
    def shard_yml_diagnostics(shard_path : String, missing : Set(String)) : Array(Mystral::LSP::Diagnostic)
      lines = (CompileRunner.read_file(shard_path) || "").lines
      diags = [] of Mystral::LSP::Diagnostic
      missing.to_a.sort.each do |req|
        dep = req.partition('/').first # `radix/foo` -> shard `radix`
        if loc = locate_dependency(lines, dep)
          line, col, len = loc
        else
          line, col, len = 0, 0, (lines.first?.try(&.size) || 1)
        end
        diags << Mystral::LSP::Diagnostic.new(
          Mystral::LSP::Range.new(
            Mystral::LSP::Position.new(line, col),
            Mystral::LSP::Position.new(line, col + len),
          ),
          DIAGNOSTIC_SEVERITY_ERROR,
          "mystral",
          "shard `#{dep}` can't be resolved — run `shards install` (required as `#{req}`)",
        )
      end
      diags
    end

    # (line, col, len) of a `<dep>:` key in shard.yml, or nil if absent.
    private def locate_dependency(lines : Array(String), dep : String) : {Int32, Int32, Int32}?
      re = /^(\s*)#{Regex.escape(dep)}\s*:/
      lines.each_with_index do |text, i|
        if m = text.match(re)
          return {i, m[1].size, dep.size}
        end
      end
      nil
    end
  end
end
