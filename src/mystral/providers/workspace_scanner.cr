require "../server_context"
require "../support/crystal_paths"
require "../support/reachable_set"
require "../support/workspace_entries"
require "../support/symbol_cache"

module Mystral
  # Scans the workspace on `initialize`: index every .cr under the workspace
  # roots + CRYSTAL_PATH (stdlib + shards), build the reachability filter, and
  # kick off the startup compile. Emits `$/progress` so the editor can show
  # "Mystral: indexing …". Runs spawned off the main fiber (the initialize
  # response is already sent), so the editor stays responsive during the walk.
  class WorkspaceScanner
    WORKSPACE_SCAN_TOKEN = "mystral/workspace-scan"

    def initialize(@context : ServerContext)
      @next_request_id = 1_i64
    end

    def scan(params : JSON::Any?) : Nil
      return unless params
      roots = workspace_roots(params)
      return if roots.empty?

      # Share roots with the compile/enrich closures (they captured this array
      # by reference); replace contents in place so the binding stays stable.
      @context.workspace_roots.replace(roots)
      exclude_dirs = exclude_dirs_from(params)

      crystal_paths = CrystalPaths.resolve(CrystalPaths.discover, roots)
      target_dirs = CrystalPaths.target_subdirs(crystal_paths)
      all_roots = roots + crystal_paths + target_dirs

      progress = client_supports_progress?(params)
      token = WORKSPACE_SCAN_TOKEN
      log "scan start: #{all_roots.size} roots, progress_supported=#{progress}"
      if progress
        send_progress_create(token)
        send_progress_begin(token, "Mystral: indexing workspace")
      end

      # Disk symbol cache for the rarely-changing roots (stdlib, lib/ deps): a
      # digest hit deserializes instead of re-parsing. Workspace roots are NEVER
      # cached — the user edits them, so they always re-parse.
      cache = SymbolCache.new
      all_roots.each_with_index do |dir, i|
        is_workspace = roots.includes?(dir)
        @context.index.scan_directory(dir, is_workspace ? nil : cache, is_workspace ? exclude_dirs : Set(String).new)
        if progress
          send_progress_report(token, "#{i + 1} / #{all_roots.size}: #{File.basename(dir)}", i + 1, all_roots.size)
        end
      end

      # Reachability filter: walk the require graph from shard entry points
      # (with CRYSTAL_PATH on the search path), then sweep each root for files
      # whose top-level isn't a host-false macro guard.
      search_paths = crystal_paths + target_dirs
      walker = ReachableSet.new(search_paths, exclude_dirs)
      roots.each do |root|
        WorkspaceEntries.discover(root).each { |e| walker.add_entry(e) }
        walker.add_workspace_root(root)
      end
      @context.index.workspace_reachable = walker.reachable
      log "reachability: #{walker.reachable.size} files reachable from workspace"

      send_progress_end(token) if progress

      # Compile-on-startup: one compile per root entry so project diagnostics
      # (and the missing-dep toast) surface on server start, not on first edit.
      # The worker debounces + the digest dedups, so it's one compile.
      roots.each do |root|
        if entry = WorkspaceEntries.discover(root).first?
          @context.compile_worker.enqueue("file://#{entry}")
        end
      end
    end

    private def workspace_roots(params : JSON::Any) : Array(String)
      paths = [] of String
      if folders = params["workspaceFolders"]?
        if arr = folders.as_a?
          arr.each do |f|
            if uri = f["uri"]?.try(&.as_s?)
              if path = uri_to_path(uri)
                paths << path
              end
            end
          end
        end
      elsif root_uri = params["rootUri"]?.try(&.as_s?)
        if path = uri_to_path(root_uri)
          paths << path
        end
      end
      paths
    end

    private def uri_to_path(uri : String) : String?
      return nil unless uri.starts_with?("file://")
      uri[7..]
    end

    # Dir names from the client's `mystral.excludeDirs` initializationOption.
    # Defensive: a missing/malformed payload yields an empty set.
    private def exclude_dirs_from(params : JSON::Any) : Set(String)
      arr = params["initializationOptions"]?.try(&.["excludeDirs"]?).try(&.as_a?)
      return Set(String).new unless arr
      arr.compact_map(&.as_s?).to_set
    end

    private def client_supports_progress?(params : JSON::Any) : Bool
      window = params["capabilities"]?.try(&.["window"]?)
      return false unless window
      window["workDoneProgress"]?.try(&.as_bool?) == true
    end

    # LSP requires a `window/workDoneProgress/create` before `$/progress` with a
    # server-chosen token. Fire-and-forget (the client's response is dropped by
    # the router, which ignores response-shaped messages).
    private def send_progress_create(token : String) : Nil
      @context.transport.write({
        jsonrpc: "2.0",
        id:      next_request_id,
        method:  "window/workDoneProgress/create",
        params:  {token: token},
      })
    end

    private def send_progress_begin(token : String, title : String) : Nil
      @context.transport.write({
        jsonrpc: "2.0",
        method:  "$/progress",
        params:  {token: token, value: {kind: "begin", title: title, cancellable: false, percentage: 0}},
      })
    end

    private def send_progress_report(token : String, message : String, done : Int32, total : Int32) : Nil
      percentage = total <= 0 ? 0 : ((done * 100) // total)
      @context.transport.write({
        jsonrpc: "2.0",
        method:  "$/progress",
        params:  {token: token, value: {kind: "report", message: message, percentage: percentage}},
      })
    end

    private def send_progress_end(token : String) : Nil
      @context.transport.write({
        jsonrpc: "2.0",
        method:  "$/progress",
        params:  {token: token, value: {kind: "end"}},
      })
    end

    private def next_request_id : Int64
      id = -@next_request_id
      @next_request_id += 1
      id
    end

    private def log(message : String) : Nil
      @context.log.puts "[#{Time.local.to_s("%H:%M:%S.%L")}] #{message}"
    end
  end
end
