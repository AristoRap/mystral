require "json"
require "./transport"
require "./server_context"
require "./providers/lifecycle"
require "./providers/document_symbol_provider"
require "./providers/document_highlight_provider"
require "./providers/references_provider"
require "./providers/definition_provider"

module Mystral
  # Routes one LSP message to the provider that owns it, and owns the
  # response-writing helpers. This is the ONE dispatch surface — there is no
  # god-class reopened across files. Each LSP method delegates to a small
  # provider held as an instance variable; new methods add a `when` clause and
  # a provider, never a reopening.
  #
  # `handle` returns true only when the client asked us to exit.
  class Router
    def initialize(@transport : Transport, @context : ServerContext)
      @lifecycle = LifecycleProvider.new(@context)
      @document_symbols = DocumentSymbolProvider.new(@context)
      @document_highlights = DocumentHighlightProvider.new(@context)
      @references = ReferencesProvider.new(@context)
      @definitions = DefinitionProvider.new(@context)
    end

    # Returns true if the server should exit after handling this message.
    def handle(message : JSON::Any) : Bool
      method = message["method"]?.try(&.as_s)
      return false unless method
      params = message["params"]?
      id = message["id"]?

      if id
        log "req  #{method} id=#{id}"
        handle_request(id, method, params)
        false
      else
        log "notif #{method}"
        handle_notification(method, params)
      end
    end

    private def handle_request(id : JSON::Any, method : String, params : JSON::Any?) : Nil
      case method
      when "initialize"
        respond(id, @lifecycle.initialize_result)
      when "shutdown"
        respond_null(id)
      when "textDocument/documentSymbol"
        respond(id, @document_symbols.document_symbol(params))
      when "workspace/symbol"
        respond(id, @document_symbols.workspace_symbol(params))
      when "textDocument/documentHighlight"
        respond_or_null(id, @document_highlights.document_highlight(params))
      when "textDocument/references"
        respond_or_null(id, @references.references(params))
      when "textDocument/definition"
        respond_or_null(id, @definitions.definition(params))
      else
        respond_error(id, -32601, "Method not found: #{method}")
      end
    end

    # Returns true if the server should exit.
    private def handle_notification(method : String, params : JSON::Any?) : Bool
      case method
      when "initialized"
        # Client is ready; nothing to do.
      when "textDocument/didOpen"
        @lifecycle.did_open(params)
      when "textDocument/didChange"
        @lifecycle.did_change(params)
      when "textDocument/didClose"
        @lifecycle.did_close(params)
      when "exit"
        return true
      end
      false
    end

    # ---- response helpers ----

    private def respond(id, result) : Nil
      @transport.write({jsonrpc: "2.0", id: id, result: result})
    end

    private def respond_null(id) : Nil
      @transport.write({jsonrpc: "2.0", id: id, result: nil})
    end

    # Write `value` as the result, or null when it's nil. LSP request handlers
    # that "find nothing" must answer with null, not omit the response.
    private def respond_or_null(id, value) : Nil
      value.nil? ? respond_null(id) : respond(id, value)
    end

    private def respond_error(id, code : Int32, message : String) : Nil
      @transport.write({
        jsonrpc: "2.0",
        id:      id,
        error:   {code: code, message: message},
      })
    end

    private def log(message : String) : Nil
      @context.log.puts "[#{Time.local.to_s("%H:%M:%S.%L")}] #{message}"
    end
  end
end
