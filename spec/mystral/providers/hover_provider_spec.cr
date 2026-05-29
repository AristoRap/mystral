require "../../spec_helper"

private URI = "file:///t.cr"

# The rendered hover markdown at (line, char), or nil.
private def hover_md(src : String, line : Int32, char : Int32) : String?
  index = Mystral::Index.new
  index.reindex(URI, src)
  docs = Mystral::Documents.new
  docs.set(URI, src)
  ctx = Mystral::ServerContext.new(index, docs, IO::Memory.new, false)
  enrichment = Mystral::EnrichmentRequester.new(ctx)
  result = Mystral::HoverProvider.new(ctx, enrichment).hover(
    JSON.parse(%({"textDocument":{"uri":"#{URI}"},"position":{"line":#{line},"character":#{char}}}))
  )
  result.try { |m| JSON.parse(m.to_json)["value"].as_s }
end

describe Mystral::HoverProvider do
  it "renders a method definition's signature" do
    src = "class Greeter\n  def greet(name : String) : String\n  end\nend"
    md = hover_md(src, 1, 6).not_nil! # cursor on `greet`
    md.should contain("def greet(name : String) : String")
  end

  it "renders a parameter, which shadows a same-named method" do
    src = "class C\n  def value\n  end\n  def go(value : Int32)\n    value\n  end\nend"
    md = hover_md(src, 4, 4).not_nil! # cursor on `value` usage inside go
    md.should contain("(parameter)")
    md.should contain("value")
  end

  it "renders nothing for an @ivar that has no declaration — never a param lie" do
    # `@log` is NOT a declared ivar; the same-named param `log` must NOT leak.
    src = "class C\n  def initialize(log : IO)\n    @log\n  end\nend"
    hover_md(src, 2, 5).should be_nil
  end

  it "renders a declared instance variable" do
    src = "class C\n  @count : Int32\n  def go\n    @count\n  end\nend"
    md = hover_md(src, 3, 5).not_nil! # cursor on `@count` usage
    md.should contain("(instance variable)")
    md.should contain("@count")
    md.should contain("Int32")
  end

  it "renders a local variable's inferred type" do
    src = "class Thing\nend\ndef f\n  x = Thing.new\n  x\nend"
    md = hover_md(src, 4, 2).not_nil! # cursor on `x` usage
    md.should contain("(local)")
    md.should contain("Thing")
  end

  it "renders a method reached through a typed receiver chain" do
    src = "class Result\n  def value : Result\n  end\nend\nclass App\n  @r : Result\n  def go\n    @r.value\n  end\nend"
    md = hover_md(src, 7, 8).not_nil! # cursor on `value` after `@r.`
    md.should contain("def value")
  end

  it "renders a block parameter's type from the call's signature" do
    src = "class Event\nend\nclass Bus\n  def on(&block : Event ->)\n  end\nend\nclass App\n  @bus : Bus\n  def go\n    @bus.on do |e|\n    end\n  end\nend"
    md = hover_md(src, 9, 16).not_nil! # cursor on `e` inside |e|
    md.should contain("(block parameter)")
    md.should contain("Event")
  end

  it "renders the synthesized reader for a `getter?` property's declaration name" do
    # The reader is synthesized as `debug?`; hovering the declaration token
    # `debug` must still resolve (it would otherwise find nothing — the bare
    # name isn't a method and the ivar is reachable only via `@debug`).
    src = "class C\n  getter? debug : Bool\nend"
    md = hover_md(src, 1, 10).not_nil! # cursor on `debug`
    md.should contain("def debug? : Bool")
  end

  it "suppresses hover inside a comment" do
    hover_md("x = 1 # greet", 0, 9).should be_nil
  end

  it "returns nil on an empty line" do
    hover_md("class A\n\nend", 1, 0).should be_nil
  end
end
