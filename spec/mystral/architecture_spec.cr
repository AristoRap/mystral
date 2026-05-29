require "../spec_helper"

# Architecture guard: the request path is parser-only. Hover, definition, and
# completion must answer in milliseconds, so the code under
# `src/mystral/providers/**` and `src/mystral/resolve/**` must NEVER reach for
# the Crystal compiler, the semantic layer, or a `crystal tool`/`crystal build`
# shell-out — any of those drags a multi-second whole-program analysis onto a
# keystroke. Reading a precomputed, content-hash-keyed fact is fine; the invokes
# that PRODUCE those facts live on the background compile worker, which is
# outside the directories scanned here.
#
# This grep is the executable form of that rule: it must pass against today's
# source (proving the hot path is already clean) and fail the instant anyone
# requires or calls the compiler into a provider/resolver. The parser is NOT the
# compiler — `compiler/crystal/syntax`, `Crystal::Parser`, `Crystal::Lexer`,
# `Crystal::Formatter`, and AST node/visitor types are all allowed.

private GUARDED_DIRS = ["providers", "resolve"]

# `require` of a compiler internal other than the parser (`syntax`) or
# `formatter` — both run in-memory in microseconds and are fine on the hot path;
# the rest of the compiler is the multi-second analysis we're keeping off it.
private FORBIDDEN_REQUIRE = /require\s+"compiler\/crystal\/(?!syntax|formatter)/

# The semantic/compiler API surface + the CLI subprocesses that run it.
private FORBIDDEN_PATTERNS = {
  "Crystal::Compiler" => /\bCrystal::Compiler\b/,
  "Crystal::Program"  => /\bCrystal::Program\b/,
  "Crystal::Command"  => /\bCrystal::Command\b/,
  "Crystal::Semantic" => /\bCrystal::Semantic/,
  "crystal build"     => /\bcrystal\s+build\b/,
  "crystal tool"      => /\bcrystal\s+tool\b/,
  "--no-codegen"      => /--no-codegen/,
}

# Strip a Crystal line comment so explanatory prose that *names* a forbidden
# API (e.g. a comment saying "no `crystal tool format` shell-out") doesn't trip
# the guard. Respects double-quoted strings so `#` inside `"..."` / `"#{x}"` is
# not mistaken for a comment. Good enough for source files; the guard is about
# real code, not exhaustive lexing.
private def strip_comment(line : String) : String
  in_str = false
  prev = '\0'
  line.each_char_with_index do |c, i|
    if c == '"' && prev != '\\'
      in_str = !in_str
    elsif c == '#' && !in_str
      return line[0...i]
    end
    prev = c
  end
  line
end

private def guarded_files : Array(String)
  src = File.expand_path(File.join(__DIR__, "..", "..", "src", "mystral"))
  GUARDED_DIRS.flat_map do |dir|
    Dir.glob(File.join(src, dir, "**", "*.cr"))
  end
end

describe "architecture: parser-only request path" do
  files = guarded_files

  it "scans a non-empty set of provider/resolve sources" do
    # Guard against the guard silently passing because the glob found nothing
    # (wrong path, moved dirs).
    files.should_not be_empty
  end

  files.each do |path|
    rel = path.sub(File.expand_path(File.join(__DIR__, "..", "..")) + "/", "")

    it "#{rel} does not require the compiler on the hot path" do
      File.read_lines(path).each do |line|
        code = strip_comment(line)
        code.should_not match(FORBIDDEN_REQUIRE)
      end
    end

    it "#{rel} does not touch the semantic/compiler surface" do
      File.read_lines(path).each do |line|
        code = strip_comment(line)
        FORBIDDEN_PATTERNS.each do |name, pattern|
          if code.matches?(pattern)
            fail "#{rel}: forbidden on the parser-only request path: #{name}\n  #{line.strip}"
          end
        end
      end
    end
  end
end
