require "./mystral/lsp/types"
require "./mystral/lsp/protocol"
require "./mystral/lsp/entry_locations"
require "./mystral/resolve/text_scanner"
require "./mystral/resolve/cursor_context"
require "./mystral/resolve/signature_params"
require "./mystral/resolve/resolver"
require "./mystral/transport"
require "./mystral/server"

# Mystral — a blazing-fast, parser-driven Crystal language server.
#
# This file is the library root: it pulls in the pieces in dependency order.
# The executable entry point (the `mystral` binary) is wired in once the
# server + CLI land.
module Mystral
  VERSION = "0.1.0"
end
