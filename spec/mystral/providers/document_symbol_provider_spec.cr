require "../../spec_helper"

private URI = "file:///t.cr"

private def document_symbols(src : String) : Array(Mystral::LSP::SymbolInformation)
  index = Mystral::Index.new
  index.reindex(URI, src)
  context = Mystral::ServerContext.new(index, Mystral::Documents.new, IO::Memory.new, false)
  provider = Mystral::DocumentSymbolProvider.new(context)
  params = JSON.parse(%({"textDocument":{"uri":"#{URI}"}}))
  provider.document_symbol(params)
end

# Serialize one SymbolInformation and pull its range back as plain values.
private def range_of(info : Mystral::LSP::SymbolInformation) : {Int32, Int32}
  json = JSON.parse(info.to_json)
  range = json["location"]["range"]
  {range["start"]["line"].as_i, range["end"]["line"].as_i}
end

describe Mystral::DocumentSymbolProvider do
  it "returns an empty list with no params" do
    index = Mystral::Index.new
    context = Mystral::ServerContext.new(index, Mystral::Documents.new, IO::Memory.new, false)
    Mystral::DocumentSymbolProvider.new(context).document_symbol(nil).should be_empty
  end

  it "lists every indexed symbol in the file" do
    infos = document_symbols("class Foo\n  def bar\n  end\nend")
    infos.map(&.name).should contain("Foo")
    infos.map(&.name).should contain("bar")
  end

  it "spans a container's range over its full body (breadcrumb/sticky-scroll fix)" do
    infos = document_symbols("class Foo\n  def bar\n  end\nend")
    foo = infos.find { |s| s.name == "Foo" }.not_nil!
    start_line, end_line = range_of(foo)
    start_line.should eq(0)
    end_line.should eq(3) # spans down to the closing `end`, not a point range
  end

  it "maps kinds to LSP SymbolKind values" do
    infos = document_symbols("class Foo\nend\nmodule Bar\nend\ndef baz; end")
    kind_of = ->(name : String) { infos.find { |s| s.name == name }.not_nil!.kind }
    kind_of.call("Foo").should eq(Mystral::LSP::SymbolKind::CLASS)
    kind_of.call("Bar").should eq(Mystral::LSP::SymbolKind::MODULE)
    kind_of.call("baz").should eq(Mystral::LSP::SymbolKind::METHOD)
  end
end
