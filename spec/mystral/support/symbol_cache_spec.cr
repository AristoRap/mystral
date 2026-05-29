require "../../spec_helper"
require "file_utils"

private def with_temp_tree(&)
  root = File.join(Dir.tempdir, "mystral_cache_#{Process.pid}_#{Time.utc.to_unix_ns}")
  cache_dir = "#{root}-cache"
  Dir.mkdir_p(root)
  File.write(File.join(root, "a.cr"), "class Alpha\nend")
  begin
    yield root, Mystral::SymbolCache.new(cache_dir)
  ensure
    FileUtils.rm_rf(root)
    FileUtils.rm_rf(cache_dir)
  end
end

describe Mystral::SymbolCache do
  it "round-trips grouped entries via a real index scan" do
    with_temp_tree do |root, cache|
      digest = cache.digest_for(root)

      # Scan once with the cache → stores the blob.
      idx1 = Mystral::Index.new
      idx1.scan_directory(root, cache)
      idx1.find_by_name("Alpha").size.should eq(1)

      # A fresh index + same digest → loads from disk (no re-parse needed).
      loaded = cache.load(root, digest).not_nil!
      loaded.values.flatten.map(&.name).should contain("Alpha")
    end
  end

  it "returns nil on a digest mismatch (forces a re-scan)" do
    with_temp_tree do |root, cache|
      idx = Mystral::Index.new
      idx.scan_directory(root, cache) # writes the blob
      cache.load(root, "a-different-digest").should be_nil
    end
  end

  it "invalidates when a source file changes (digest shifts)" do
    with_temp_tree do |root, cache|
      d1 = cache.digest_for(root)
      sleep 10.milliseconds # ensure a distinct mtime
      File.write(File.join(root, "a.cr"), "class Alpha\n  def added\n  end\nend")
      cache.digest_for(root).should_not eq(d1)
    end
  end
end
