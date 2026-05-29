require "../mystral/server_context"
require "../mystral/support/workspace_entries"
require "./compile_runner"
require "./missing_requires"
require "./hierarchy"

module MystralCLI
  # Builds the closure CompileWorker runs when a URI settles: compile the
  # program (shard entry points, so cross-file references resolve), then
  # publish the errors anchored to the edited file as LSP diagnostics.
  #
  # We compile shard.yml entry points rather than the file alone — Crystal has
  # no per-file unit, so compiling a file in isolation invents `undefined
  # constant` errors for every sibling reference. Nothing project-specific is
  # hardcoded; it's whatever shard.yml declares. A loose file with no shard is
  # its own unit. Syntax errors are already published by the in-process parser
  # on every didChange; this surfaces SEMANTIC errors only.
  #
  # (Ground-truth hierarchy ancestry reaping hooks in here in a later
  # increment, once the InferenceIndex exists.)
  module CompileProcessor
    extend self

    DIAGNOSTIC_SEVERITY_ERROR = 1
    # One digest entry per compile program the session touches; past the cap we
    # clear the whole map (a dropped digest only costs one recompile).
    MAX_TRACKED_PROGRAMS = 256

    def build(context : Mystral::ServerContext, log : IO, debug : Bool = false) : Proc(String, String?, Nil)
      roots = context.workspace_roots
      # URIs we last published a NON-EMPTY compile diagnostic for. One compile
      # sees the whole program, so a fix in the settled file can clear an error
      # in a DIFFERENT open file; the compiler only lists files WITH errors, so
      # we remember what we flagged and retract any that don't reappear.
      # Retraction is always sound. Single worker fiber → no lock.
      flagged = Set(String).new
      # Last reachable-content digest per program (target set). A settle whose
      # digest matches the last compile is skipped — the subprocess reads disk,
      # so an unsaved buffer's repeated settles recompile identical content.
      digests = {} of String => String
      # Unresolved-require names last toasted, and the shard.yml URIs reddened,
      # so we dedupe the toast and retract the moment requires resolve.
      notified_missing = Set(String).new
      dep_flagged = Set(String).new
      # Program-keys we've reaped hierarchy ancestry for — that tool is a
      # SECOND full compile, so we populate ancestry once per program (the
      # startup compile), not per settle.
      hierarchy_populated = Set(String).new

      ->(uri : String, _snapshot : String?) do
        begin
          path = uri_to_path(uri)
          return nil if path.nil? || !File.exists?(path)

          targets = compile_targets(path, roots)
          program_key = targets.sort.join('\0')
          digest = CompileRunner.reachable_content_digest(path, roots)
          if digests[program_key]? == digest
            return nil # reachable content unchanged → prior diagnostics still true
          end

          grouped = CompileRunner.errors_grouped_by_realpath(targets, log, debug)

          # Unresolved requires ⇒ the program never loaded; its other errors are
          # noise. Redden shard.yml + toast once (on change), retract .cr
          # squiggles, and DON'T store the digest (re-check when requires
          # resolve).
          missing = MissingRequires.detect(grouped)
          unless missing.empty?
            handle_missing(context, path, roots, missing, notified_missing, dep_flagged, flagged) do |new_notified, new_dep_flagged|
              notified_missing = new_notified
              dep_flagged = new_dep_flagged
              flagged = Set(String).new
            end
            return nil
          end
          # Requires resolve now — clear any reddened shard.yml + re-arm toast.
          unless dep_flagged.empty?
            dep_flagged.each { |u| context.diagnostics.set_compile(u, [] of Mystral::LSP::Diagnostic) }
            dep_flagged = Set(String).new
          end
          notified_missing.clear

          anchor_real = CompileRunner.real_path(path)
          published = Set(String).new

          # 1. The settled file: always publish (empty clears, non-empty shows).
          anchor_diags = (grouped[anchor_real]? || [] of CompileRunner::CrystalError).map { |e| diagnostic_for(e) }
          context.diagnostics.set_compile(uri, anchor_diags)
          published << uri unless anchor_diags.empty?

          # 2. Open dependents with errors — only saved files (buffer == disk;
          #    an unsaved buffer's truth may differ from what we compiled).
          open_map = open_saved_realpath_to_uri(context)
          grouped.each do |file_real, errs|
            next if file_real == anchor_real
            duri = open_map[file_real]?
            next unless duri
            diags = errs.map { |e| diagnostic_for(e) }
            context.diagnostics.set_compile(duri, diags)
            published << duri unless diags.empty?
          end

          # 3. Retract anything we flagged before that this compile no longer
          #    reports (sound — only ever clears).
          (flagged - published).each do |stale_uri|
            next if stale_uri == uri
            context.diagnostics.set_compile(stale_uri, [] of Mystral::LSP::Diagnostic)
          end

          flagged = published
          digests.clear if digests.size >= MAX_TRACKED_PROGRAMS
          digests[program_key] = digest

          # Reap ground-truth ancestry once per program (a second compile), to
          # fill the generic/macro-superclass gap walk_parents can't resolve.
          # Scoped to workspace types so the stored map stays small. Marked
          # attempted up front so a tool failure doesn't re-pay every settle.
          unless hierarchy_populated.includes?(program_key)
            hierarchy_populated << program_key
            if hjson = Hierarchy.json_for(targets.first)
              ancestry = Hierarchy.parse(hjson, context.index.workspace_type_names(roots))
              context.inference.set_ancestry(ancestry)
            end
          end
          nil
        rescue ex
          log.puts "[#{Time.local.to_s("%H:%M:%S.%L")}] compile_processor: #{uri} EXCEPTION #{ex.class}: #{ex.message}"
          nil
        end
      end
    end

    # Redden shard.yml for the missing deps + toast once (only when the missing
    # set changed), retract prior .cr squiggles. Yields the new
    # (notified_missing, dep_flagged) sets for the caller to store.
    private def handle_missing(context, path, roots, missing : Set(String),
                               notified_missing : Set(String), dep_flagged : Set(String), flagged : Set(String),
                               & : Set(String), Set(String) -> Nil) : Nil
      return if missing == notified_missing
      new_dep_flagged = Set(String).new
      if (root = roots.find { |r| CompileRunner.under_root?(path, r) })
        shard_path = File.join(root, "shard.yml")
        if File.file?(shard_path)
          shard_uri = "file://#{shard_path}"
          diags = MissingRequires.shard_yml_diagnostics(shard_path, missing)
          unless diags.empty?
            context.diagnostics.set_compile(shard_uri, diags)
            new_dep_flagged << shard_uri
          end
        end
      end
      (dep_flagged - new_dep_flagged).each { |u| context.diagnostics.set_compile(u, [] of Mystral::LSP::Diagnostic) }
      flagged.each { |u| context.diagnostics.set_compile(u, [] of Mystral::LSP::Diagnostic) }
      context.show_message(Mystral::ServerContext::MESSAGE_WARNING, MissingRequires.message(missing))
      yield missing, new_dep_flagged
    end

    # shard.yml entry points if the file is under a workspace root, else the
    # file itself (a loose script is its own compilation unit).
    private def compile_targets(path : String, roots : Array(String)) : Array(String)
      root = roots.find { |r| CompileRunner.under_root?(path, r) }
      return [path] unless root
      entries = Mystral::WorkspaceEntries.discover(root)
      entries.empty? ? [path] : entries
    end

    # real_path -> URI for every open document whose buffer matches disk (the
    # compiler reads disk; we only attribute a verdict to a saved buffer).
    private def open_saved_realpath_to_uri(context : Mystral::ServerContext) : Hash(String, String)
      map = {} of String => String
      context.documents.each_open do |duri, buffer|
        dpath = uri_to_path(duri)
        next unless dpath && File.exists?(dpath)
        next unless CompileRunner.read_file(dpath) == buffer
        map[CompileRunner.real_path(dpath)] = duri
      end
      map
    end

    private def diagnostic_for(e : CompileRunner::CrystalError) : Mystral::LSP::Diagnostic
      line = ((e.line || 1) - 1).clamp(0, Int32::MAX)
      col = ((e.column || 1) - 1).clamp(0, Int32::MAX)
      end_col = col + (e.size || 1)
      Mystral::LSP::Diagnostic.new(
        Mystral::LSP::Range.new(
          Mystral::LSP::Position.new(line, col),
          Mystral::LSP::Position.new(line, end_col),
        ),
        DIAGNOSTIC_SEVERITY_ERROR,
        "mystral",
        e.message,
      )
    end

    private def uri_to_path(uri : String) : String?
      return nil unless uri.starts_with?("file://")
      uri[7..]
    end
  end
end
