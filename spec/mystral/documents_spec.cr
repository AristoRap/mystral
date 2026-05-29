require "../spec_helper"

describe Mystral::Documents do
  it "serves the live buffer for an open URI" do
    docs = Mystral::Documents.new
    docs.set("file:///a.cr", "live text")
    docs.text_for("file:///a.cr").should eq("live text")
    docs.open?("file:///a.cr").should be_true
  end

  it "prefers the live buffer over what's on disk" do
    file = File.tempfile("mystral", ".cr") { |f| f.print "disk text" }
    uri = "file://#{file.path}"
    begin
      docs = Mystral::Documents.new
      docs.text_for(uri).should eq("disk text") # not open → reads disk
      docs.set(uri, "buffer text")
      docs.text_for(uri).should eq("buffer text") # open → live buffer wins
    ensure
      file.delete
    end
  end

  it "falls back to disk after close (symbols outlive the tab)" do
    file = File.tempfile("mystral", ".cr") { |f| f.print "disk text" }
    uri = "file://#{file.path}"
    begin
      docs = Mystral::Documents.new
      docs.set(uri, "buffer text")
      docs.close(uri)
      docs.open?(uri).should be_false
      docs.text_for(uri).should eq("disk text")
    ensure
      file.delete
    end
  end

  it "returns nil for an unopened, non-existent file" do
    Mystral::Documents.new.text_for("file:///does/not/exist.cr").should be_nil
  end

  describe "content version" do
    it "is stable for identical text and changes when content changes" do
      docs = Mystral::Documents.new
      docs.set("file:///a.cr", "one")
      v1 = docs.version("file:///a.cr")
      docs.set("file:///a.cr", "one") # same content
      docs.version("file:///a.cr").should eq(v1)
      docs.set("file:///a.cr", "two") # changed
      docs.version("file:///a.cr").should_not eq(v1)
    end

    it "is released on close (bounded RAM)" do
      docs = Mystral::Documents.new
      docs.set("file:///a.cr", "x")
      docs.close("file:///a.cr")
      docs.version("file:///a.cr").should be_nil
    end
  end
end
