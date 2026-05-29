require "yaml"

module Mystral
  # Discovers the .cr files Crystal treats as compilation entry points for a
  # workspace root: shard.yml's `name:` (entry `src/<name>.cr`) and every
  # `targets.*.main:`, falling back to `src/<basename>.cr`. The compile path
  # compiles these so a file's cross-file references resolve; the reachability
  # walker (a later increment) starts from them. Best-effort — missing /
  # malformed shard.yml yields empty rather than raising.
  module WorkspaceEntries
    extend self

    # Just the executable entry points (`targets.*.main`) — the files that RUN
    # the code, so `crystal tool context` has type info for what they reach.
    # The library `name:` entry compiles but never *calls* anything. Empty for
    # a pure library with no executable target.
    def executable_mains(root : String) : Array(String)
      mains = [] of String
      shard_yml = File.join(root, "shard.yml")
      return mains unless File.file?(shard_yml)
      data = begin
        YAML.parse(File.read(shard_yml))
      rescue
        return mains
      end
      if targets = data["targets"]?
        targets.as_h?.try &.each_value do |target|
          main = target["main"]?.try(&.as_s?)
          next unless main
          candidate = File.expand_path(File.join(root, main))
          mains << candidate if File.file?(candidate) && !mains.includes?(candidate)
        end
      end
      mains
    end

    def discover(root : String) : Array(String)
      entries = [] of String
      shard_yml = File.join(root, "shard.yml")
      add_from_shard_yml(shard_yml, root, entries) if File.file?(shard_yml)

      basename_entry = File.expand_path(File.join(root, "src", "#{File.basename(root)}.cr"))
      entries << basename_entry if File.file?(basename_entry) && !entries.includes?(basename_entry)
      entries
    end

    private def add_from_shard_yml(yml_path : String, root : String, entries : Array(String)) : Nil
      data = begin
        YAML.parse(File.read(yml_path))
      rescue
        return
      end

      if name = data["name"]?.try(&.as_s?)
        candidate = File.expand_path(File.join(root, "src", "#{name}.cr"))
        entries << candidate if File.file?(candidate) && !entries.includes?(candidate)
      end

      if targets = data["targets"]?
        targets.as_h?.try &.each_value do |target|
          main = target["main"]?.try(&.as_s?)
          next unless main
          candidate = File.expand_path(File.join(root, main))
          entries << candidate if File.file?(candidate) && !entries.includes?(candidate)
        end
      end
    end
  end
end
