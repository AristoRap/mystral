require "../spec_helper"

# Route one message through a fresh Router and return {exited?, response}.
# The response is the first frame the router wrote back (nil if it wrote none,
# as for notifications).
private def route(message_json : String) : {Bool, JSON::Any?}
  sink = IO::Memory.new
  transport = Mystral::Transport.new(IO::Memory.new, sink, IO::Memory.new)
  context = Mystral::ServerContext.new(Mystral::Index.new, Mystral::Documents.new, IO::Memory.new, false)
  router = Mystral::Router.new(transport, context)

  exited = router.handle(JSON.parse(message_json))

  reader = Mystral::Transport.new(IO::Memory.new(sink.to_s), IO::Memory.new, IO::Memory.new)
  {exited, reader.read}
end

describe Mystral::Router do
  describe "initialize" do
    it "advertises Full text-document sync and serverInfo" do
      _, response = route(%({"jsonrpc":"2.0","id":1,"method":"initialize"}))
      result = response.not_nil!["result"]

      result["capabilities"]["textDocumentSync"].as_i.should eq(1)
      result["serverInfo"]["name"].as_s.should eq("mystral")
      result["serverInfo"]["version"].as_s.should eq(Mystral::VERSION)
    end

    it "advertises exactly the supported capability set" do
      # Pin the whole set so a refactor can't silently DROP a capability (e.g.
      # hover) or ADD one whose output isn't a strict superset of the editor's
      # built-in (advertising a weaker provider makes the editor stop using its
      # own richer one). Update this list deliberately when a provider lands.
      _, response = route(%({"jsonrpc":"2.0","id":1,"method":"initialize"}))
      capabilities = response.not_nil!["result"]["capabilities"].as_h

      capabilities.keys.sort.should eq([
        "completionProvider",
        "definitionProvider",
        "documentFormattingProvider",
        "documentHighlightProvider",
        "documentSymbolProvider",
        "hoverProvider",
        "implementationProvider",
        "referencesProvider",
        "signatureHelpProvider",
        "textDocumentSync",
        "typeDefinitionProvider",
        "workspaceSymbolProvider",
      ].sort)

      capabilities["documentSymbolProvider"].should eq(true)
      capabilities["workspaceSymbolProvider"].should eq(true)
      capabilities["documentHighlightProvider"].should eq(true)
      capabilities["referencesProvider"].should eq(true)
      capabilities["definitionProvider"].should eq(true)
      capabilities["typeDefinitionProvider"].should eq(true)
      capabilities["implementationProvider"].should eq(true)
      capabilities["hoverProvider"].should eq(true)
      capabilities["documentFormattingProvider"].should eq(true)
    end

    it "advertises completion + signatureHelp trigger characters" do
      _, response = route(%({"jsonrpc":"2.0","id":1,"method":"initialize"}))
      capabilities = response.not_nil!["result"]["capabilities"]

      capabilities["completionProvider"]["triggerCharacters"].as_a.map(&.as_s).should eq([".", ":"])
      capabilities["signatureHelpProvider"]["triggerCharacters"].as_a.map(&.as_s).should eq(["(", ","])
    end

    it "never advertises foldingRange (it would degrade the editor's own folds)" do
      _, response = route(%({"jsonrpc":"2.0","id":1,"method":"initialize"}))
      capabilities = response.not_nil!["result"]["capabilities"]
      capabilities["foldingRangeProvider"]?.should be_nil
    end

    it "does not signal exit" do
      exited, _ = route(%({"jsonrpc":"2.0","id":1,"method":"initialize"}))
      exited.should be_false
    end
  end

  describe "shutdown" do
    it "responds with null and does not exit" do
      exited, response = route(%({"jsonrpc":"2.0","id":2,"method":"shutdown"}))
      exited.should be_false
      response.not_nil!["result"].raw.should be_nil
    end
  end

  describe "exit" do
    it "signals the server to stop" do
      exited, _ = route(%({"jsonrpc":"2.0","method":"exit"}))
      exited.should be_true
    end
  end

  describe "unknown request" do
    it "returns a Method-not-found error (-32601)" do
      _, response = route(%({"jsonrpc":"2.0","id":3,"method":"textDocument/rename"}))
      response.not_nil!["error"]["code"].as_i.should eq(-32601)
    end
  end

  describe "notifications" do
    it "ignores `initialized` without responding or exiting" do
      exited, response = route(%({"jsonrpc":"2.0","method":"initialized"}))
      exited.should be_false
      response.should be_nil
    end

    it "ignores a message with no method field" do
      exited, response = route(%({"jsonrpc":"2.0","id":9,"result":null}))
      exited.should be_false
      response.should be_nil
    end
  end
end
