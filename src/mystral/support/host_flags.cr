module Mystral
  # Compile-time snapshot of the host's Crystal platform flags. Reachability
  # filtering on `{% if flag?(:darwin) %}`-style require gates compares against
  # this set: a require branch is "live" iff its `flag?(...)` matches a flag here.
  #
  # The recognised flag names are hand-maintained (Crystal exposes no runtime
  # flag enumerator); unknown flags read as "not present" rather than crashing.
  module HostFlags
    KNOWN_FLAGS = {
      "darwin", "linux", "win32", "windows", "freebsd", "openbsd",
      "netbsd", "dragonfly", "solaris", "android", "bsd", "unix", "posix",
      "x86_64", "i386", "arm", "aarch64", "wasm32",
      "bits32", "bits64",
      "gnu", "musl", "apple", "msvc",
      "little_endian", "big_endian",
      "release", "debug",
    }

    # Macros disallow dynamic flag names inside `flag?(...)`, so this is
    # hand-unrolled. Add to both KNOWN_FLAGS and this block for a new flag.
    SYMBOLS = begin
      set = Set(String).new
      {% if flag?(:darwin) %}        set << "darwin"        {% end %}
      {% if flag?(:linux) %}         set << "linux"         {% end %}
      {% if flag?(:win32) %}         set << "win32"         {% end %}
      {% if flag?(:windows) %}       set << "windows"       {% end %}
      {% if flag?(:freebsd) %}       set << "freebsd"       {% end %}
      {% if flag?(:openbsd) %}       set << "openbsd"       {% end %}
      {% if flag?(:netbsd) %}        set << "netbsd"        {% end %}
      {% if flag?(:dragonfly) %}     set << "dragonfly"     {% end %}
      {% if flag?(:solaris) %}       set << "solaris"       {% end %}
      {% if flag?(:android) %}       set << "android"       {% end %}
      {% if flag?(:bsd) %}           set << "bsd"           {% end %}
      {% if flag?(:unix) %}          set << "unix"          {% end %}
      {% if flag?(:posix) %}         set << "posix"         {% end %}
      {% if flag?(:x86_64) %}        set << "x86_64"        {% end %}
      {% if flag?(:i386) %}          set << "i386"          {% end %}
      {% if flag?(:arm) %}           set << "arm"           {% end %}
      {% if flag?(:aarch64) %}       set << "aarch64"       {% end %}
      {% if flag?(:wasm32) %}        set << "wasm32"        {% end %}
      {% if flag?(:bits32) %}        set << "bits32"        {% end %}
      {% if flag?(:bits64) %}        set << "bits64"        {% end %}
      {% if flag?(:gnu) %}           set << "gnu"           {% end %}
      {% if flag?(:musl) %}          set << "musl"          {% end %}
      {% if flag?(:apple) %}         set << "apple"         {% end %}
      {% if flag?(:msvc) %}          set << "msvc"          {% end %}
      {% if flag?(:little_endian) %} set << "little_endian" {% end %}
      {% if flag?(:big_endian) %}    set << "big_endian"    {% end %}
      {% if flag?(:release) %}       set << "release"       {% end %}
      {% if flag?(:debug) %}         set << "debug"         {% end %}
      set
    end

    def self.symbols : Set(String)
      SYMBOLS
    end

    # Host target triple in `<arch>-<os>` form, matching the `lib_c/<target>`
    # subdir names inside the stdlib. Empty when no usable pair is configured.
    HOST_TARGET = begin
      arch = {% if flag?(:aarch64) %}"aarch64"{% elsif flag?(:x86_64) %}"x86_64"{% elsif flag?(:i386) %}"i386"{% elsif flag?(:arm) %}"arm"{% elsif flag?(:wasm32) %}"wasm32"{% else %}""{% end %}
      os = {% if flag?(:darwin) %}"darwin"{% elsif flag?(:android) && flag?(:linux) %}"linux-android"{% elsif flag?(:musl) && flag?(:linux) %}"linux-musl"{% elsif flag?(:linux) %}"linux-gnu"{% elsif flag?(:freebsd) %}"freebsd"{% elsif flag?(:openbsd) %}"openbsd"{% elsif flag?(:netbsd) %}"netbsd"{% elsif flag?(:dragonfly) %}"dragonfly"{% elsif flag?(:solaris) %}"solaris"{% elsif flag?(:msvc) && flag?(:win32) %}"windows-msvc"{% elsif flag?(:gnu) && flag?(:win32) %}"windows-gnu"{% elsif flag?(:wasm32) %}"wasi"{% else %}""{% end %}
      arch.empty? || os.empty? ? "" : "#{arch}-#{os}"
    end

    # True iff `name` (with or without a leading `:`) is a host flag.
    def self.matches?(name : String) : Bool
      stripped = name.starts_with?(':') ? name[1..] : name
      SYMBOLS.includes?(stripped)
    end
  end
end
