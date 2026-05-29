require "digest/sha256"

module Mystral
  # The open-buffer store: the authoritative text for every file the editor
  # has told us about via didOpen/didChange, plus a content-version per URI.
  #
  # `text_for` is the single source of truth the resolver/providers read:
  # a live (possibly-unsaved) buffer beats whatever is on disk, and an
  # unopened file falls back to a disk read so workspace-wide lookups still
  # see files the user hasn't opened in a tab.
  #
  # The content-version is a digest computed once per change (off the request
  # hot path) so the side-index read only ever compares two short strings,
  # never re-hashes the buffer per request.
  class Documents
    def initialize
      @buffers = {} of String => String
      @versions = {} of String => String
    end

    # didOpen / didChange: replace the live buffer and recompute its version.
    def set(uri : String, text : String) : Nil
      @buffers[uri] = text
      @versions[uri] = Documents.digest(text)
    end

    # didClose: drop the live buffer only. The symbol index represents
    # workspace-wide knowledge that outlives an editor tab — closing a tab
    # shouldn't make a file's symbols disappear; the file is still on disk and
    # text_for re-reads it on demand. The buffer-scoped version is released
    # here (bounded RAM).
    def close(uri : String) : Nil
      @buffers.delete(uri)
      @versions.delete(uri)
    end

    # The live buffer for `uri`, or nil if no didOpen has been seen for it.
    def buffer(uri : String) : String?
      @buffers[uri]?
    end

    def open?(uri : String) : Bool
      @buffers.has_key?(uri)
    end

    # Yield each open buffer as (uri, text). Used by the compile path to map
    # disk verdicts back to the editor's open files.
    def each_open(& : String, String ->) : Nil
      @buffers.each { |uri, text| yield uri, text }
    end

    # Live buffer if open; else the file's current disk contents. nil for a
    # non-file URI we don't have open, or an unreadable path.
    def text_for(uri : String) : String?
      if cached = @buffers[uri]?
        return cached
      end
      return nil unless uri.starts_with?("file://")
      path = uri[7..]
      return nil unless File.exists?(path)
      File.read(path)
    rescue
      nil
    end

    # Content-version of the open buffer for `uri`, or nil if not open.
    def version(uri : String) : String?
      @versions[uri]?
    end

    # The version key for a piece of text. A SHA256 hex digest: stable across
    # runs and collision-free for our purposes (gating cached compile facts).
    def self.digest(text : String) : String
      Digest::SHA256.hexdigest(text)
    end
  end
end
