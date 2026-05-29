require "../../spec_helper"

private URI = "file:///t.cr"

private def definition(src : String, line : Int32, char : Int32) : Array(Mystral::LSP::Location)?
  index = Mystral::Index.new
  docs = Mystral::Documents.new
  docs.set(URI, src)
  index.reindex(URI, src)
  context = Mystral::ServerContext.new(index, docs, IO::Memory.new, false)
  provider = Mystral::DefinitionProvider.new(context)
  params = JSON.parse(%({"textDocument":{"uri":"#{URI}"},"position":{"line":#{line},"character":#{char}}}))
  provider.definition(params)
end

# The (line, character) start of the first returned location.
private def first_pos(locs) : {Int32, Int32}
  j = JSON.parse(locs.not_nil!.first.to_json)["range"]["start"]
  {j["line"].as_i, j["character"].as_i}
end

describe Mystral::DefinitionProvider do
  it "jumps to an inherited method's definition" do
    src = "class A\n  def helper\n  end\nend\nclass B < A\n  def go\n    helper\n  end\nend"
    # cursor on `helper` call (line 6); the def's recorded position is the
    # `def` keyword on line 1, col 2 (2-space indent).
    locs = definition(src, 6, 6)
    first_pos(locs).should eq({1, 2})
  end

  it "jumps to a type definition through a receiver" do
    src = "class Widget\n  def build\n  end\nend\nWidget.build"
    # cursor on `build` after `Widget.` (line 4, char 9)
    locs = definition(src, 4, 9)
    first_pos(locs).should eq({1, 2})
  end

  it "returns nil when the cursor is not on a known symbol" do
    definition("x = 1", 0, 0).should be_nil
  end

  it "returns nil when the cursor is on an empty line" do
    definition("class A\n\nend", 1, 0).should be_nil
  end
end
