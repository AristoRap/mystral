require "../spec_helper"
require "../../src/mystral_cli/compile_processor"

# End-to-end: the compile processor shells out to a real `crystal build
# --no-codegen` and publishes the semantic errors as LSP diagnostics. Slower
# than the unit specs (a real subprocess), so it lives under spec/integration.
describe "compile diagnostics (end-to-end)" do
  it "publishes a semantic error for a loose file and clears it when fixed" do
    file = File.tempfile("compile", ".cr") { |f| f.print "ThisConstantDoesNotExist\n" }
    uri = "file://#{file.path}"
    begin
      sink = IO::Memory.new
      transport = Mystral::Transport.new(IO::Memory.new, sink, IO::Memory.new)
      context = Mystral::ServerContext.new(Mystral::Index.new, Mystral::Documents.new, IO::Memory.new, false, transport: transport)
      processor = MystralCLI::CompileProcessor.build(context, IO::Memory.new, false)

      processor.call(uri, nil)
      messages = published_for(sink, uri)
      messages.should_not be_empty
      messages.join.should contain("ThisConstantDoesNotExist")

      # Fix the file on disk and recompile → the squiggle is retracted.
      File.write(file.path, "x = 1\n")
      processor.call(uri, nil)
      published_for(sink, uri).should be_empty # last publish for the uri is empty
    ensure
      file.delete
    end
  end

  it "collapses an error trace to one diagnostic, frames as relatedInformation" do
    # `crystal build` is fail-fast and emits the call stack innermost-LAST, so
    # the array's last element is the real error and the leading "instantiating
    # ..." entries are context. We must publish ONE squiggle (the real error),
    # not one per frame, with the frames carried as relatedInformation.
    src = "def a(x)\n  b(x)\nend\ndef b(x)\n  x.no_such_method\nend\na(1)\n"
    file = File.tempfile("compile", ".cr") { |f| f.print(src) }
    uri = "file://#{file.path}"
    begin
      sink = IO::Memory.new
      transport = Mystral::Transport.new(IO::Memory.new, sink, IO::Memory.new)
      context = Mystral::ServerContext.new(Mystral::Index.new, Mystral::Documents.new, IO::Memory.new, false, transport: transport)
      processor = MystralCLI::CompileProcessor.build(context, IO::Memory.new, false)

      processor.call(uri, nil)
      diags = diags_for(sink, uri)
      diags.size.should eq(1) # the real error only — not the two frames
      diags.first["message"].as_s.should contain("no_such_method")

      related = diags.first["relatedInformation"].as_a
      related.map(&.["message"].as_s).should eq(["instantiating 'a(Int32)'", "instantiating 'b(Int32)'"])
    ensure
      file.delete
    end
  end
end

# Full diagnostic objects of the LAST publishDiagnostics frame written for `uri`.
private def diags_for(sink : IO::Memory, uri : String) : Array(JSON::Any)
  reader = Mystral::Transport.new(IO::Memory.new(sink.to_s), IO::Memory.new, IO::Memory.new)
  last = nil.as(JSON::Any?)
  while msg = reader.read
    next unless msg["method"]?.try(&.as_s) == "textDocument/publishDiagnostics"
    last = msg if msg["params"]["uri"].as_s == uri
  end
  last.try(&.["params"]["diagnostics"].as_a) || [] of JSON::Any
end

# Diagnostic messages of the LAST publishDiagnostics frame written for `uri`.
private def published_for(sink : IO::Memory, uri : String) : Array(String)
  reader = Mystral::Transport.new(IO::Memory.new(sink.to_s), IO::Memory.new, IO::Memory.new)
  last = nil.as(JSON::Any?)
  while msg = reader.read
    next unless msg["method"]?.try(&.as_s) == "textDocument/publishDiagnostics"
    last = msg if msg["params"]["uri"].as_s == uri
  end
  last.try(&.["params"]["diagnostics"].as_a.map(&.["message"].as_s)) || [] of String
end
