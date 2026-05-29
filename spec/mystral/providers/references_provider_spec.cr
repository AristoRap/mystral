require "../../spec_helper"

# Context with several files, each opened (live buffer) and indexed.
private def context_with(files : Hash(String, String)) : Mystral::ServerContext
  index = Mystral::Index.new
  docs = Mystral::Documents.new
  files.each do |uri, text|
    docs.set(uri, text)
    index.reindex(uri, text)
  end
  Mystral::ServerContext.new(index, docs, IO::Memory.new, false)
end

private def references(context, uri, line, char, include_decl = true) : Array(Mystral::LSP::Location)?
  provider = Mystral::ReferencesProvider.new(context)
  ctx = include_decl ? "" : %(,"context":{"includeDeclaration":false})
  params = JSON.parse(%({"textDocument":{"uri":"#{uri}"},"position":{"line":#{line},"character":#{char}}#{ctx}}))
  provider.references(params)
end

private def uris_of(locations) : Array(String)
  locations.not_nil!.map(&.uri)
end

describe Mystral::ReferencesProvider do
  it "finds occurrences of a type across the whole workspace" do
    ctx = context_with({
      "file:///a.cr" => "class Widget\nend",
      "file:///b.cr" => "w = Widget.new",
    })
    locs = references(ctx, "file:///a.cr", 0, 6) # cursor on `Widget`
    uris_of(locs).sort.should eq(["file:///a.cr", "file:///b.cr"])
  end

  it "scans bare lowercase names too (no same-file suppression)" do
    ctx = context_with({
      "file:///a.cr" => "def helper\nend",
      "file:///b.cr" => "helper",
    })
    locs = references(ctx, "file:///b.cr", 0, 0) # cursor on the `helper` call
    uris_of(locs).should contain("file:///a.cr")
    uris_of(locs).should contain("file:///b.cr")
  end

  it "honors includeDeclaration=false by dropping the cursor's own occurrence" do
    ctx = context_with({"file:///a.cr" => "thing\nthing"})
    with_decl = references(ctx, "file:///a.cr", 0, 0, include_decl: true).not_nil!
    without_decl = references(ctx, "file:///a.cr", 0, 0, include_decl: false).not_nil!
    with_decl.size.should eq(2)
    without_decl.size.should eq(1)
  end

  it "includes an open buffer not yet in the index" do
    index = Mystral::Index.new
    docs = Mystral::Documents.new
    docs.set("file:///fresh.cr", "alpha\nalpha") # opened but never reindexed
    ctx = Mystral::ServerContext.new(index, docs, IO::Memory.new, false)
    locs = references(ctx, "file:///fresh.cr", 0, 0)
    locs.not_nil!.size.should eq(2)
  end

  it "returns nil when the cursor is not on an identifier" do
    ctx = context_with({"file:///a.cr" => "a   b"})
    references(ctx, "file:///a.cr", 0, 2).should be_nil
  end
end
