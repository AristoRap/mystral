require "./index"
require "./documents"

module Mystral
  # The bundle of shared, long-lived state the providers need. ONE owner
  # constructs it (the Server) and hands it to each provider by injection —
  # replacing the old pattern of threading the same instance variables by
  # reference through a class reopened across nine files.
  #
  # Fields are added here as the increment that needs them lands (Diagnostics,
  # the InferenceIndex, the compile worker, workspace_roots, ...). Keeping
  # them in one named place is what makes the data flow traceable.
  class ServerContext
    getter index : Index
    getter documents : Documents
    getter log : IO
    getter? debug : Bool

    def initialize(@index : Index, @documents : Documents, @log : IO = STDERR, @debug : Bool = false)
    end
  end
end
