require "./mystral/lsp/types"
require "./mystral/lsp/protocol"
require "./mystral/lsp/entry_locations"
require "./mystral/resolve/text_scanner"
require "./mystral/resolve/cursor_context"
require "./mystral/resolve/signature_params"
require "./mystral/resolve/block_arg_parser"
require "./mystral/resolve/resolver"
require "./mystral/transport"
require "./mystral/diagnostics"
require "./mystral/compile_worker"
require "./mystral/inference_index"
require "./mystral/server"

# Mystral — a blazing-fast, parser-driven Crystal language server.
#
# This file is the library root: it pulls in the pieces in dependency order.
# The executable entry point lives in src/cli.cr (the shard target's main).
module Mystral
  VERSION = "0.1.0"

  # The one build identity the CLI and serverInfo both report. Carries the
  # version today; a git commit can be folded in here later without touching
  # the call sites.
  def self.build_version : String
    VERSION
  end
end
