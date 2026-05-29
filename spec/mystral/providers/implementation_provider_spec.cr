require "../../spec_helper"

private URI = "file:///t.cr"

private def implementation(src : String, line : Int32, char : Int32) : Array(Mystral::LSP::Location)?
  index = Mystral::Index.new
  docs = Mystral::Documents.new
  docs.set(URI, src)
  index.reindex(URI, src)
  context = Mystral::ServerContext.new(index, docs, IO::Memory.new, false)
  provider = Mystral::ImplementationProvider.new(context)
  params = JSON.parse(%({"textDocument":{"uri":"#{URI}"},"position":{"line":#{line},"character":#{char}}}))
  provider.implementation(params)
end

private def positions(locs) : Array({Int32, Int32})
  locs.not_nil!.map do |loc|
    j = JSON.parse(loc.to_json)["range"]["start"]
    {j["line"].as_i, j["character"].as_i}
  end
end

describe Mystral::ImplementationProvider do
  it "finds a module method's implementation in an including type" do
    src = "module Greeter\n  def greet\n  end\nend\nclass Person\n  include Greeter\n  def greet\n  end\nend"
    # cursor on `greet` in the module (line 1) → Person's override at line 6.
    positions(implementation(src, 1, 6)).should eq([{6, 2}])
  end

  it "finds an abstract method's override in a subclass" do
    src = "abstract class Shape\n  abstract def area\nend\nclass Circle < Shape\n  def area\n  end\nend"
    # cursor on `area` in the abstract def (line 1) → Circle#area at line 4.
    positions(implementation(src, 1, 15)).should eq([{4, 2}])
  end

  it "finds the subtypes of a type" do
    src = "class Animal\nend\nclass Dog < Animal\nend"
    # cursor on `Animal` (line 0) → Dog at line 2 (class keyword column).
    positions(implementation(src, 0, 6)).should eq([{2, 0}])
  end

  it "returns nil for a type with no descendants" do
    implementation("class Lonely\nend", 0, 6).should be_nil
  end

  it "returns nil on an empty line" do
    implementation("class A\n\nend", 1, 0).should be_nil
  end
end
