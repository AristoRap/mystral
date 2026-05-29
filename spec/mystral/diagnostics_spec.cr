require "../spec_helper"

private def diag(msg : String) : Mystral::LSP::Diagnostic
  Mystral::LSP::Diagnostic.new(
    Mystral::LSP::Range.new(Mystral::LSP::Position.new(0, 0), Mystral::LSP::Position.new(0, 1)),
    1, "mystral", msg
  )
end

# Run `block` against a fresh Diagnostics, then return the diagnostic-message
# list of the LAST publishDiagnostics frame written for `uri`.
private def last_published(uri : String, & : Mystral::Diagnostics ->) : Array(String)
  sink = IO::Memory.new
  transport = Mystral::Transport.new(IO::Memory.new, sink, IO::Memory.new)
  yield Mystral::Diagnostics.new(transport)

  reader = Mystral::Transport.new(IO::Memory.new(sink.to_s), IO::Memory.new, IO::Memory.new)
  last = nil.as(JSON::Any?)
  while msg = reader.read
    next unless msg["method"]?.try(&.as_s) == "textDocument/publishDiagnostics"
    last = msg if msg["params"]["uri"].as_s == uri
  end
  last.try(&.["params"]["diagnostics"].as_a.map(&.["message"].as_s)) || [] of String
end

describe Mystral::Diagnostics do
  it "a valid-syntax parse edit does NOT erase a live compile squiggle (the flicker incident)" do
    msgs = last_published("file:///a.cr") do |d|
      d.set_compile("file:///a.cr", [diag("type mismatch")])
      d.set_parse("file:///a.cr", [] of Mystral::LSP::Diagnostic) # valid syntax keystroke
    end
    msgs.should eq(["type mismatch"]) # compile half survives
  end

  it "a settled compile does not erase the parser's current syntax error" do
    msgs = last_published("file:///a.cr") do |d|
      d.set_parse("file:///a.cr", [diag("syntax error")])
      d.set_compile("file:///a.cr", [] of Mystral::LSP::Diagnostic)
    end
    msgs.should eq(["syntax error"])
  end

  it "publishes the union of both halves" do
    msgs = last_published("file:///a.cr") do |d|
      d.set_parse("file:///a.cr", [diag("syntax")])
      d.set_compile("file:///a.cr", [diag("semantic")])
    end
    msgs.sort.should eq(["semantic", "syntax"])
  end

  it "clears a half independently (empty list clears only that source)" do
    msgs = last_published("file:///a.cr") do |d|
      d.set_compile("file:///a.cr", [diag("semantic")])
      d.set_compile("file:///a.cr", [] of Mystral::LSP::Diagnostic) # error fixed
    end
    msgs.should be_empty
  end
end
