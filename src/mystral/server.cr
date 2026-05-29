require "json"
require "./transport"
require "./server_context"
require "./router"

module Mystral
  # Stdio LSP server: read frame -> route -> write frame, until `exit`.
  #
  # The loop is deliberately small and defensive: a malformed frame or a
  # single message that raises mid-handling logs and continues — one bad
  # message can never kill the process.
  class Server
    # Log file path; override with MYSTRAL_LOG. Lives in /tmp so it's
    # predictable across sessions and `tail -f /tmp/mystral.log` works from
    # any terminal.
    DEFAULT_LOG_PATH = "/tmp/mystral.log"

    getter log : IO
    getter? debug : Bool
    # Exposed so production wiring (the CLI) can build the compile processor +
    # enrichment closures with access to the shared state, then inject them.
    getter context : ServerContext

    def initialize(input : IO = STDIN, output : IO = STDOUT, log : IO? = nil, debug : Bool = false)
      @log = log || open_log_target
      @debug = debug || debug_env?
      @transport = Transport.new(input, output, @log)
      @context = ServerContext.new(Index.new, Documents.new, @log, @debug, transport: @transport, async_compile: true)
      @router = Router.new(@transport, @context)
    end

    # Wire the production compile processor (built externally with access to
    # @context) into the worker. Call before #run.
    def use_compile_processor(p : Proc(String, String?, Nil)) : Nil
      @context.compile_worker.use_processor(p)
    end

    def run : Nil
      log "mystral v#{Mystral::VERSION}: server started, awaiting LSP frames on stdin"
      @context.compile_worker.start
      loop do
        begin
          message = @transport.read
        rescue ex : JSON::ParseException
          log "transport: malformed frame body (#{ex.message}); continuing"
          next
        rescue ex
          log "transport: read raised #{ex.class}: #{ex.message}; continuing"
          next
        end
        break unless message

        begin
          break if @router.handle(message)
        rescue ex
          # Never let one bad message kill the loop — log (the output stream
          # is reserved for LSP frames) and keep serving.
          log "error handling message: #{ex.class}: #{ex.message}"
        end
      end
      @context.compile_worker.stop
      log "server loop exiting"
    end

    # Dual-target log: a file (so the user can `tail -f` it) plus STDERR
    # (which the LSP client mirrors into its output channel). Falls back to
    # STDERR alone if the file can't be opened — never block startup on it.
    private def open_log_target : IO
      path = ENV["MYSTRAL_LOG"]? || DEFAULT_LOG_PATH
      file = File.open(path, "a")
      file.sync = true
      IO::MultiWriter.new(file, STDERR)
    rescue ex
      STDERR.puts "mystral: could not open log file (#{ex.message}); STDERR only"
      STDERR
    end

    private def debug_env? : Bool
      v = ENV["MYSTRAL_DEBUG"]?
      return false unless v
      v.in?({"1", "true", "yes", "on"})
    end

    private def log(message : String) : Nil
      @log.puts "[#{Time.local.to_s("%H:%M:%S.%L")}] #{message}"
    end
  end
end
