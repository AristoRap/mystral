require "../spec_helper"

# Build an LSP wire frame for a JSON body string.
private def frame(body : String) : String
  "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
end

# A Transport whose input is `input` and whose output + log are throwaway
# memory buffers (the output sink is returned so callers can inspect writes).
private def reader_for(input : String) : {Mystral::Transport, IO::Memory}
  sink = IO::Memory.new
  {Mystral::Transport.new(IO::Memory.new(input), sink, IO::Memory.new), sink}
end

describe Mystral::Transport do
  describe "#write" do
    it "frames a message as Content-Length header + CRLF + body" do
      sink = IO::Memory.new
      transport = Mystral::Transport.new(IO::Memory.new, sink, IO::Memory.new)

      transport.write({jsonrpc: "2.0", id: 1, result: nil})

      body = %({"jsonrpc":"2.0","id":1,"result":null})
      sink.to_s.should eq("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
    end

    it "uses byte length, not character length, for multi-byte bodies" do
      sink = IO::Memory.new
      transport = Mystral::Transport.new(IO::Memory.new, sink, IO::Memory.new)

      transport.write({message: "café→"})

      body = %({"message":"café→"})
      sink.to_s.should start_with("Content-Length: #{body.bytesize}\r\n\r\n")
    end
  end

  describe "#read" do
    it "round-trips a written message" do
      buffer = IO::Memory.new
      writer = Mystral::Transport.new(IO::Memory.new, buffer, IO::Memory.new)
      writer.write({jsonrpc: "2.0", method: "initialize", id: 7})

      reader = Mystral::Transport.new(IO::Memory.new(buffer.to_s), IO::Memory.new, IO::Memory.new)
      message = reader.read.should_not be_nil
      message["method"].as_s.should eq("initialize")
      message["id"].as_i.should eq(7)
    end

    it "reads consecutive frames in order" do
      stream = frame(%({"id":1})) + frame(%({"id":2}))
      transport, _ = reader_for(stream)

      transport.read.not_nil!["id"].as_i.should eq(1)
      transport.read.not_nil!["id"].as_i.should eq(2)
      transport.read.should be_nil
    end

    it "returns nil on EOF" do
      transport, _ = reader_for("")
      transport.read.should be_nil
    end

    it "raises JSON::ParseException on a malformed body so the loop can recover" do
      transport, _ = reader_for(frame("{not valid json"))
      expect_raises(JSON::ParseException) do
        transport.read
      end
    end
  end

  describe "concurrent writes" do
    it "keeps each frame intact when written from many fibers" do
      sink = IO::Memory.new
      transport = Mystral::Transport.new(IO::Memory.new, sink, IO::Memory.new)

      count = 50
      done = Channel(Nil).new
      count.times do |i|
        spawn do
          transport.write({id: i})
          done.send(nil)
        end
      end
      count.times { done.receive }

      # Every frame must read back as a well-formed message; no header/body
      # interleaving. The set of ids must be exactly 0...count.
      reader = Mystral::Transport.new(IO::Memory.new(sink.to_s), IO::Memory.new, IO::Memory.new)
      ids = [] of Int32
      while message = reader.read
        ids << message["id"].as_i
      end
      ids.sort.should eq((0...count).to_a)
    end
  end
end
