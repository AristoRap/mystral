require "digest/sha256"
require "../index/entry"

module Mystral
  # Cold-start symbol cache. Parsing the stdlib at boot costs ~610ms;
  # deserializing the same parsed `Entry`s from a binary blob costs ~16ms. The
  # stdlib changes only on a toolchain upgrade, so we cache a rarely-changing
  # root's symbols to disk and reload them next boot.
  #
  # SOUNDNESS (current-truth-or-nothing): keyed on a digest of every .cr file's
  # (path, mtime, size) + Crystal version + the Mystral build id + the running
  # binary's mtime. The boot path recomputes it (stat-only) and serves the blob
  # ONLY on an exact match; any file/toolchain/parser change forces a re-scan
  # that rewrites the cache. Never on a request path — purely a startup
  # optimization; the hover hot path still reads the in-RAM index.
  class SymbolCache
    # Bump on any change to the on-disk LAYOUT or the Entry fields serialized.
    # (Changes to WHAT the visitor extracts are covered automatically by folding
    # the Mystral build id into the digest; this is the explicit layout lever.)
    FORMAT_VERSION = 3u32
    MAGIC          = "MYSC".to_slice

    private NIL_LEN = -1
    private NIL_I32 = Int32::MIN

    def initialize(@dir : String = SymbolCache.default_dir, @crystal_version : String = Crystal::VERSION)
    end

    # Per-user cache dir (XDG_CACHE_HOME, else ~/.cache). One dir across
    # projects — the stdlib blob is the same for all.
    def self.default_dir : String
      base = ENV["XDG_CACHE_HOME"]?
      base = File.join(Path.home.to_s, ".cache") if base.nil? || base.empty?
      File.join(base, "mystral")
    end

    # Digest of `root`'s on-disk state: Crystal version + Mystral build id +
    # running binary mtime + every .cr file's (path, mtime_ns, size), sorted.
    # Stat-only. The build id + binary mtime are in the key because the blob
    # stores the OUTPUT of Mystral's parser — a parser change makes an old blob
    # stale even when source bytes are identical, so every rebuild invalidates.
    def digest_for(root : String) : String
      fps = [] of String
      collect_fingerprints(root, fps)
      fps.sort!
      digest = Digest::SHA256.new
      digest << @crystal_version << "\0" << Mystral.build_version << "\0"
      if (exe = Process.executable_path) && (info = File.info?(exe))
        digest << (info.modification_time - Time::UNIX_EPOCH).total_nanoseconds.to_i64.to_s << "\0"
      end
      fps.each { |line| digest << line << "\n" }
      digest.hexfinal
    end

    private def collect_fingerprints(dir : String, acc : Array(String)) : Nil
      Dir.each_child(dir) do |child|
        next if Index::SCAN_SKIP_DIRS.includes?(child)
        full = File.join(dir, child)
        info = File.info?(full, follow_symlinks: false)
        next unless info
        if info.directory?
          collect_fingerprints(full, acc)
        elsif child.ends_with?(".cr")
          mtime_ns = (info.modification_time - Time::UNIX_EPOCH).total_nanoseconds.to_i64
          acc << "#{full}\0#{mtime_ns}\0#{info.size}"
        end
      end
    rescue
      # An unreadable dir shouldn't abort the digest — a miss is always safe.
    end

    # Grouped (uri → entries) for `root`, but only when the blob's digest equals
    # `digest`. nil on absence / mismatch / corruption (all safe re-scan
    # signals). Never raises.
    def load(root : String, digest : String) : Hash(String, Array(Entry))?
      path = cache_path(root)
      return nil unless File.exists?(path)
      File.open(path, "rb") do |io|
        magic = Bytes.new(MAGIC.size)
        return nil unless io.read_fully?(magic) && magic == MAGIC
        return nil unless io.read_bytes(UInt32, IO::ByteFormat::LittleEndian) == FORMAT_VERSION
        return nil unless read_str(io) == digest

        n_uris = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
        grouped = Hash(String, Array(Entry)).new(initial_capacity: n_uris)
        n_uris.times do
          uri = read_str(io).not_nil!
          n = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
          entries = Array(Entry).new(n)
          n.times { entries << read_entry(io) }
          grouped[uri] = entries
        end
        grouped
      end
    rescue
      nil
    end

    # Write `grouped`'s entries for `root` under `digest`. Atomic (temp +
    # rename). Best-effort: a write failure never breaks the scan.
    def store(root : String, digest : String, grouped : Hash(String, Array(Entry))) : Nil
      Dir.mkdir_p(@dir)
      path = cache_path(root)
      tmp = "#{path}.#{Process.pid}.tmp"
      File.open(tmp, "wb") do |io|
        io.write(MAGIC)
        io.write_bytes(FORMAT_VERSION, IO::ByteFormat::LittleEndian)
        write_str(io, digest)
        io.write_bytes(grouped.size, IO::ByteFormat::LittleEndian)
        grouped.each do |uri, entries|
          write_str(io, uri)
          io.write_bytes(entries.size, IO::ByteFormat::LittleEndian)
          entries.each { |e| write_entry(io, e) }
        end
      end
      File.rename(tmp, path)
    rescue
      File.delete?(tmp) rescue nil if tmp
    end

    # One cache file per root, named by a hash of its absolute path.
    private def cache_path(root : String) : String
      key = Digest::SHA256.hexdigest(File.expand_path(root))[0, 16]
      File.join(@dir, "syms-#{key}.bin")
    end

    private def write_entry(io : IO, e : Entry) : Nil
      write_str(io, e.name)
      write_str(io, e.kind)
      write_str(io, e.uri)
      io.write_bytes(e.line, IO::ByteFormat::LittleEndian)
      io.write_bytes(e.column, IO::ByteFormat::LittleEndian)
      write_str(io, e.signature)
      write_str(io, e.doc)
      write_str(io, e.container)
      io.write_byte(e.class_method? ? 1u8 : 0u8)
      write_i32n(io, e.end_line)
      write_str(io, e.visibility)
      write_str(io, e.parent)
      write_str(io, e.declared_type)
      io.write_bytes(e.annotations.size, IO::ByteFormat::LittleEndian)
      e.annotations.each { |a| write_str(io, a) }
      write_str(io, e.inferred_return)
      write_str(io, e.return_ivar)
    end

    private def read_entry(io : IO) : Entry
      name = read_str(io).not_nil!
      kind = read_str(io).not_nil!
      uri = read_str(io).not_nil!
      line = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
      column = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
      signature = read_str(io)
      doc = read_str(io)
      container = read_str(io)
      class_method = io.read_byte == 1u8
      end_line = read_i32n(io)
      visibility = read_str(io)
      parent = read_str(io)
      declared_type = read_str(io)
      n_ann = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
      annotations = n_ann.zero? ? [] of String : Array(String).new(n_ann) { read_str(io).not_nil! }
      inferred_return = read_str(io)
      return_ivar = read_str(io)
      Entry.new(name, kind, uri, line, column, signature, doc, container,
        class_method, end_line, visibility, parent, declared_type,
        annotations, inferred_return, return_ivar)
    end

    private def write_str(io : IO, s : String?) : Nil
      if s.nil?
        io.write_bytes(NIL_LEN, IO::ByteFormat::LittleEndian)
      else
        io.write_bytes(s.bytesize, IO::ByteFormat::LittleEndian)
        io.write(s.to_slice)
      end
    end

    private def read_str(io : IO) : String?
      n = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
      return nil if n == NIL_LEN
      buf = Bytes.new(n)
      io.read_fully(buf)
      String.new(buf)
    end

    private def write_i32n(io : IO, n : Int32?) : Nil
      io.write_bytes(n || NIL_I32, IO::ByteFormat::LittleEndian)
    end

    private def read_i32n(io : IO) : Int32?
      n = io.read_bytes(Int32, IO::ByteFormat::LittleEndian)
      n == NIL_I32 ? nil : n
    end
  end
end
