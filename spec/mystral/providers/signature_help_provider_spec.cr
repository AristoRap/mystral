require "../../spec_helper"

private URI = "file:///t.cr"

private def sig_help(src : String, line : Int32, char : Int32) : Mystral::LSP::SignatureHelp?
  index = Mystral::Index.new
  index.reindex(URI, src)
  docs = Mystral::Documents.new
  docs.set(URI, src)
  ctx = Mystral::ServerContext.new(index, docs, IO::Memory.new, false)
  Mystral::SignatureHelpProvider.new(ctx).signature_help(
    JSON.parse(%({"textDocument":{"uri":"#{URI}"},"position":{"line":#{line},"character":#{char}}}))
  )
end

describe Mystral::SignatureHelpProvider do
  it "shows the signature with two parameters and active param 0 at the open paren" do
    src = "class C\n  def greet(a : Int32, b : String)\n  end\n  def go\n    greet(1, \"x\")\n  end\nend"
    help = sig_help(src, 4, 10).not_nil! # cursor just after `greet(`
    help.signatures.size.should eq(1)
    help.signatures.first.label.should contain("greet")
    help.signatures.first.parameters.size.should eq(2)
    help.active_parameter.should eq(0)
  end

  it "advances the active parameter past a depth-0 comma" do
    src = "class C\n  def greet(a : Int32, b : String)\n  end\n  def go\n    greet(1, \"x\")\n  end\nend"
    help = sig_help(src, 4, 13).not_nil! # cursor after `greet(1, `
    help.active_parameter.should eq(1)
  end

  it "resolves `.new(` to the type's initialize" do
    src = "class Point\n  def initialize(x : Int32, y : Int32)\n  end\nend\nPoint.new(0, 0)"
    help = sig_help(src, 4, 10).not_nil! # cursor after `Point.new(`
    help.signatures.first.label.should contain("initialize")
    help.signatures.first.parameters.size.should eq(2)
  end

  it "returns nil when the cursor isn't inside a call" do
    sig_help("x = 1", 0, 0).should be_nil
  end
end
