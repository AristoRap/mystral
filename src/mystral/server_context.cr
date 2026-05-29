require "./index"
require "./documents"
require "./transport"
require "./diagnostics"
require "./compile_worker"
require "./resolve/resolver"

module Mystral
  # The bundle of shared, long-lived state the providers need. ONE owner
  # constructs it (the Server) and hands it to each provider by injection —
  # replacing the old pattern of threading the same instance variables by
  # reference through a class reopened across nine files.
  #
  # Transport / diagnostics / compile worker are optional with inert defaults
  # so provider unit specs can construct a context with just (index, documents,
  # log, debug); the Server passes the real stdio transport + an async worker.
  class ServerContext
    # window/showMessage severities.
    MESSAGE_ERROR   = 1
    MESSAGE_WARNING = 2
    MESSAGE_INFO    = 3

    getter index : Index
    getter documents : Documents
    getter resolver : Resolver
    getter transport : Transport
    getter diagnostics : Diagnostics
    getter compile_worker : CompileWorker
    # Workspace roots, shared BY REFERENCE with the compile processor closure:
    # the LSP `initialize` handler replaces its contents in place, and the
    # closure (capturing this same Array) sees the roots immediately.
    getter workspace_roots : Array(String)
    getter log : IO
    getter? debug : Bool

    def initialize(@index : Index, @documents : Documents, @log : IO = STDERR, @debug : Bool = false,
                   transport : Transport? = nil, async_compile : Bool = false)
      @transport = transport || Transport.new(IO::Memory.new, IO::Memory.new, @log)
      @resolver = Resolver.new(@index, @documents)
      @diagnostics = Diagnostics.new(@transport)
      @compile_worker = CompileWorker.new(@log, async: async_compile, debug: @debug)
      @workspace_roots = [] of String
    end

    # Pop a window/showMessage toast in the client — for setup-level problems
    # that aren't code squiggles (e.g. a require that can't resolve because
    # deps aren't installed).
    def show_message(type : Int32, message : String) : Nil
      @transport.write({
        jsonrpc: "2.0",
        method:  "window/showMessage",
        params:  {type: type, message: message},
      })
    end
  end
end
