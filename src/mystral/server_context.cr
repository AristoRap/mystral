require "./index"
require "./documents"
require "./transport"
require "./diagnostics"
require "./compile_worker"
require "./inference_index"
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
    # Compile-reaped facts (hover side-index + hierarchy ancestry), shared by
    # reference: the compile/enrich processors populate it, hover + the scope
    # walker read it. One instance, like diagnostics.
    getter inference : InferenceIndex
    # On-demand hover enrichment closure (uri, line, char, scope_key), injected
    # by the CLI after construction. Until set, thin local hovers fire nothing.
    getter enricher : Proc(String, Int32, Int32, Int32, Nil)?
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
      @inference = InferenceIndex.new
      @workspace_roots = [] of String
      @enricher = nil
      # Ground-truth ancestry fallback for the scope walker: consulted only
      # when AST parent-resolution fails (empty until the hierarchy reaper
      # populates it, so production stays AST-only until then).
      inference = @inference
      @resolver.scope_walker.ancestry_source = ->(fqn : String) { inference.ancestors_of(fqn) }
    end

    # Inject the on-demand enrichment closure (built by the CLI with access to
    # the shared state). Until set, thin local hovers fire nothing.
    def use_enricher(p : Proc(String, Int32, Int32, Int32, Nil)) : Nil
      @enricher = p
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
