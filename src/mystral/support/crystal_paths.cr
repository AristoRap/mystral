require "./host_flags"

module Mystral
  # Resolves `crystal env CRYSTAL_PATH` into directories Mystral should also
  # index — typically workspace `lib` (shards deps) plus the absolute stdlib
  # path. Cached for the process lifetime.
  module CrystalPaths
    @@cached : Array(String)? = nil

    # Test seam: spec_helper primes this to [] so specs don't shell out to
    # `crystal env` and walk the whole stdlib on every scan test.
    def self.cached=(paths : Array(String)?) : Nil
      @@cached = paths
    end

    # Lazy shellout to `crystal env CRYSTAL_PATH`; empty array on any failure
    # (caller treats that as "skip stdlib indexing"). Cached.
    def self.discover : Array(String)
      if cached = @@cached
        return cached
      end
      output = IO::Memory.new
      status = Process.run("crystal", {"env", "CRYSTAL_PATH"}, output: output, error: Process::Redirect::Close)
      return @@cached = [] of String unless status.success?
      @@cached = parse_path_string(output.to_s.strip)
    rescue File::NotFoundError
      @@cached = [] of String
    end

    LIST_SEPARATOR = {% if flag?(:windows) %} ";" {% else %} ":" {% end %}

    def self.parse_path_string(s : String) : Array(String)
      s.split(LIST_SEPARATOR).reject(&.empty?)
    end

    # Resolve CRYSTAL_PATH entries against each workspace root: relative entries
    # (the typical `lib`) anchored to every root; absolute entries pass through.
    def self.resolve(paths : Enumerable(String), roots : Enumerable(String)) : Array(String)
      resolved = [] of String
      paths.each do |path|
        if Path.new(path).absolute?
          resolved << path
        else
          roots.each { |root| resolved << File.join(root, path) }
        end
      end
      resolved.uniq
    end

    # For each stdlib root, the host-target `lib_c/<target>` subdir if present —
    # so absolute requires from stdlib reach the platform-specific bindings and
    # reachability can keep just one. Empty target ⇒ no subdirs.
    def self.target_subdirs(paths : Enumerable(String)) : Array(String)
      target = HostFlags::HOST_TARGET
      return [] of String if target.empty?
      result = [] of String
      paths.each do |p|
        candidate = File.join(p, "lib_c", target)
        result << candidate if Dir.exists?(candidate)
      end
      result
    end
  end
end
