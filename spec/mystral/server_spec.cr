require "../spec_helper"

private def frame(body : String) : String
  "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
end

# Read every well-formed frame the server wrote to `sink`.
private def responses_from(sink : IO::Memory) : Array(JSON::Any)
  reader = Mystral::Transport.new(IO::Memory.new(sink.to_s), IO::Memory.new, IO::Memory.new)
  out = [] of JSON::Any
  while message = reader.read
    out << message
  end
  out
end

describe Mystral::Server do
  it "drives a full initialize → exit handshake over the wire" do
    stream = frame(%({"jsonrpc":"2.0","id":1,"method":"initialize"})) +
             frame(%({"jsonrpc":"2.0","method":"initialized"})) +
             frame(%({"jsonrpc":"2.0","method":"exit"}))
    sink = IO::Memory.new

    Mystral::Server.new(IO::Memory.new(stream), sink, log: IO::Memory.new).run

    responses = responses_from(sink)
    responses.size.should eq(1) # only `initialize` produces a response
    responses.first["id"].as_i.should eq(1)
    responses.first["result"]["capabilities"]["textDocumentSync"].as_i.should eq(1)
  end

  it "survives a malformed frame and keeps serving later messages" do
    stream = frame("{ not valid json") +
             frame(%({"jsonrpc":"2.0","id":1,"method":"initialize"})) +
             frame(%({"jsonrpc":"2.0","method":"exit"}))
    sink = IO::Memory.new

    Mystral::Server.new(IO::Memory.new(stream), sink, log: IO::Memory.new).run

    responses = responses_from(sink)
    responses.size.should eq(1)
    responses.first["id"].as_i.should eq(1)
  end

  it "survives a structurally unexpected message body without dying" do
    # A JSON array where the loop expects an object: whatever `handle` does
    # with it, the per-message rescue must keep the loop alive for the
    # following initialize.
    stream = frame(%([1, 2, 3])) +
             frame(%({"jsonrpc":"2.0","id":1,"method":"initialize"})) +
             frame(%({"jsonrpc":"2.0","method":"exit"}))
    sink = IO::Memory.new

    Mystral::Server.new(IO::Memory.new(stream), sink, log: IO::Memory.new).run

    responses = responses_from(sink)
    responses.map(&.["id"].as_i).should contain(1)
  end

  it "exits cleanly on EOF with no exit notification" do
    sink = IO::Memory.new
    Mystral::Server.new(IO::Memory.new(""), sink, log: IO::Memory.new).run
    responses_from(sink).should be_empty
  end
end
