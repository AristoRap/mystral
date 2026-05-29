require "../../spec_helper"

private URI = "file:///t.cr"

private def format(src : String) : Array(Mystral::LSP::TextEdit)?
  docs = Mystral::Documents.new
  docs.set(URI, src)
  ctx = Mystral::ServerContext.new(Mystral::Index.new, docs, IO::Memory.new, false)
  Mystral::FormattingProvider.new(ctx).formatting(
    JSON.parse(%({"textDocument":{"uri":"#{URI}"}}))
  )
end

describe Mystral::FormattingProvider do
  it "returns a full-document edit for unformatted source" do
    edits = format("class   Foo\nend").not_nil!
    edits.size.should eq(1)
    edits.first.new_text.should eq("class Foo\nend\n")
    # the edit starts at the top of the document
    JSON.parse(edits.first.to_json)["range"]["start"]["line"].as_i.should eq(0)
  end

  it "returns an empty edit list when already formatted" do
    format("class Foo\nend\n").not_nil!.should be_empty
  end

  it "returns nil on a syntax error (keeps the user's text)" do
    format("class Foo").should be_nil
  end
end
