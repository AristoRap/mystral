require "../../spec_helper"

private URI = "file:///t.cr"

# A context + hover provider sharing one EnrichmentRequester (as the Router
# wires them). Returns {provider, context, enrichment}.
private def build(src : String)
  index = Mystral::Index.new
  index.reindex(URI, src)
  docs = Mystral::Documents.new
  docs.set(URI, src)
  ctx = Mystral::ServerContext.new(index, docs, IO::Memory.new, false)
  enrichment = Mystral::EnrichmentRequester.new(ctx)
  {Mystral::HoverProvider.new(ctx, enrichment), ctx, enrichment}
end

private def hover_md(provider, line, char) : String?
  result = provider.hover(JSON.parse(%({"textDocument":{"uri":"#{URI}"},"position":{"line":#{line},"character":#{char}}})))
  result.try { |m| JSON.parse(m.to_json)["value"].as_s }
end

describe "hover enrichment + side-index" do
  it "serves a scope-local type from the side-index before any AST work" do
    src = "def go\n  x = something\n  x\nend"
    provider, ctx, _ = build(src)
    version = ctx.documents.version(URI).not_nil!
    # def go starts on line 0 → scope key 0; seed the reaped local type.
    ctx.inference.set_scope_locals(URI, version, 0, {"x" => "Widget"})

    md = hover_md(provider, 2, 2).not_nil! # cursor on `x`
    md.should contain("(inferred)")
    md.should contain("Widget")
  end

  it "does not serve a stale side-index fact after the version changes" do
    src = "def go\n  x = something\n  x\nend"
    provider, ctx, _ = build(src)
    ctx.inference.set_scope_locals(URI, "stale-version", 0, {"x" => "Widget"})
    # The live buffer's version differs from "stale-version" → no inferred hover.
    md = hover_md(provider, 2, 2)
    (md.nil? || !md.includes?("Widget")).should be_true
  end

  it "fires enrichment and shows a resolving hint for an untyped local" do
    fired = [] of {String, Int32}
    src = "def go\n  x = mystery_call\n  x\nend"
    provider, ctx, _ = build(src)
    ctx.use_enricher(->(uri : String, line : Int32, _c : Int32, scope : Int32) { fired << {uri, scope}; nil })

    md = hover_md(provider, 2, 2).not_nil! # cursor on `x`, AST can't type it
    md.should contain("resolving")
    fired.size.should eq(1)
    fired.first[1].should eq(0) # enclosing def `go` starts on line 0
  end

  it "does not fire enrichment for a non-local (typo'd method) name" do
    fired = 0
    src = "def go\n  totally_undefined_thing\nend"
    provider, ctx, _ = build(src)
    ctx.use_enricher(->(_u : String, _l : Int32, _c : Int32, _s : Int32) { fired += 1; nil })
    hover_md(provider, 1, 2)
    fired.should eq(0) # no `name =` assignment → not a local → no compile
  end
end
