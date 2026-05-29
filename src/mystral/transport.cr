require "json"

module Mystral
  # LSP stdio framing: every message is `Content-Length: N\r\n\r\n<json>`.
  # Reads from the input IO, writes to the output IO. Logs go to a separate
  # IO exclusively — anything on the output stream corrupts the protocol.
  #
  # Writes are serialized through `@write_mutex`. The framing-then-body write
  # must land on the wire as one logical operation: if two fibers interleaved
  # between the `Content-Length` header and the JSON body, the client would
  # see one message's header followed by another's body and the connection
  # would desynchronize. The mutex makes a spawned fiber (e.g. the workspace
  # scan sending `$/progress`) safe to coexist with the main fiber.
  class Transport
    def initialize(@input : IO = STDIN, @output : IO = STDOUT, @log : IO = STDERR)
      @write_mutex = Mutex.new
    end

    # Returns the next message, or nil on EOF. Raises `JSON::ParseException`
    # for a malformed body — the server loop catches that and continues, so a
    # single bad frame can't kill the process.
    def read : JSON::Any?
      content_length = 0
      while line = @input.gets("\r\n")
        line = line.chomp("\r\n")
        break if line.empty?
        if line.starts_with?("Content-Length:")
          content_length = line[15..].strip.to_i
        end
      end
      return nil if content_length == 0

      body = Bytes.new(content_length)
      @input.read_fully(body)
      JSON.parse(String.new(body))
    rescue IO::Error
      nil
    end

    def write(message) : Nil
      body = message.to_json
      @write_mutex.synchronize do
        @output << "Content-Length: " << body.bytesize << "\r\n\r\n" << body
        @output.flush
      end
    end
  end
end
