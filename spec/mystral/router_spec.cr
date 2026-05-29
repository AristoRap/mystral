require "../spec_helper"

# Route one message through a fresh Router and return {exited?, response}.
# The response is the first frame the router wrote back (nil if it wrote none,
# as for notifications).
private def route(message_json : String) : {Bool, JSON::Any?}
  sink = IO::Memory.new
  transport = Mystral::Transport.new(IO::Memory.new, sink, IO::Memory.new)
  context = Mystral::ServerContext.new(IO::Memory.new, false)
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
      _, response = route(%({"jsonrpc":"2.0","id":3,"method":"textDocument/hover"}))
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
