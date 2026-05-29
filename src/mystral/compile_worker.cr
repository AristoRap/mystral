module Mystral
  # Background worker that watches for "settled" file changes (per-file
  # debounced) and runs semantic analysis off the LSP request path. Owns the
  # queue + debouncer.
  #
  # On each settled URI it calls the injected `processor`. Production wires one
  # that shells out to `crystal build --no-codegen` and publishes diagnostics.
  # The compiler is NEVER linked in-process — its first invocation corrupts the
  # fiber scheduler (worker dies after one compile, no exception). A subprocess
  # is process-isolated.
  #
  # Concurrency: single-threaded context. enqueue runs on the main fiber
  # (didChange); the run-loop fiber drains and calls the processor inline — its
  # Process.run yields via the event loop while the child compiles, so the main
  # fiber stays unblocked. @pending / @last_change / @texts guarded by @mutex.
  #
  # Test isolation: pass `async: false` to skip the spawn; drive via drain_now.
  class CompileWorker
    DEBOUNCE = 800.milliseconds
    TICK     = 200.milliseconds

    def initialize(@log : IO, async : Bool = true, debug : Bool = false, debounce : Time::Span? = nil, tick : Time::Span? = nil, @processor : Proc(String, String?, Nil) = ->(_uri : String, _text : String?) { nil })
      @last_change = {} of String => Time::Instant
      @pending = Set(String).new
      # Buffer-text snapshot captured at enqueue time on the main fiber and
      # handed to the processor (so it doesn't read the docs store itself).
      @texts = {} of String => String?
      @mutex = Mutex.new
      @async = async
      @debug = debug
      @debounce = debounce || DEBOUNCE
      @tick = tick || TICK
      @running = false
    end

    # Spawn the run loop. Idempotent; a noop when async: false (tests drive
    # drain_now directly).
    def start : Nil
      return unless @async
      return if @running
      @running = true
      spawn { run_loop }
    end

    # Signal the run loop to exit at its next iteration (may lag up to one tick).
    def stop : Nil
      @running = false
    end

    # Swap in the real processor (production wiring builds it after the server
    # is constructed).
    def use_processor(p : Proc(String, String?, Nil)) : Nil
      @processor = p
    end

    # Mark `uri` changed, resetting its debounce timer. `text` is the buffer at
    # the moment of the edit, snapshotted here so the compile pool never reads
    # a concurrently-resized docs Hash. Each enqueue overwrites the prior
    # snapshot — after debounce, the last edit's text is what we compile.
    def enqueue(uri : String, text : String? = nil) : Nil
      @mutex.synchronize do
        @last_change[uri] = Time.instant
        @pending << uri
        @texts[uri] = text
      end
    end

    # Synchronously drain everything currently settled, processing each inline.
    # Tests use this to drive the pipeline deterministically; production relies
    # on the spawned loop (the off-main-fiber guarantee).
    def drain_now : Nil
      drain_settled.each do |uri, text|
        log_debug "compile_worker: settled #{uri}"
        @processor.call(uri, text)
      end
    end

    private def run_loop : Nil
      while @running
        begin
          sleep @tick
          drain_settled.each { |uri, text| process(uri, text) }
        rescue ex
          @log.puts "[#{Time.local.to_s("%H:%M:%S.%L")}] compile_worker: run_loop caught #{ex.class}: #{ex.message}"
        end
      end
    end

    private def drain_settled : Array({String, String?})
      cutoff = Time.instant - @debounce
      @mutex.synchronize do
        ready = @pending.select do |uri|
          last = @last_change[uri]?
          last && last < cutoff
        end
        out = ready.map { |uri| {uri, @texts[uri]?} }
        ready.each do |uri|
          @pending.delete(uri)
          @last_change.delete(uri)
          @texts.delete(uri)
        end
        out.to_a
      end
    end

    private def process(uri : String, text : String?) : Nil
      log_debug "compile_worker: settled #{uri}"
      @processor.call(uri, text)
    end

    private def log_debug(message : String) : Nil
      return unless @debug
      @log.puts "[#{Time.local.to_s("%H:%M:%S.%L")}] #{message}"
    end
  end
end
