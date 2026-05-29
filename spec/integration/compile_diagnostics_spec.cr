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
