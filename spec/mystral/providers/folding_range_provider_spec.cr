require "../../spec_helper"

private URI = "file:///t.cr"

private def folds(src : String) : Array(Mystral::LSP::FoldingRange)
  docs = Mystral::Documents.new
  docs.set(URI, src)
  ctx = Mystral::ServerContext.new(Mystral::Index.new, docs, IO::Memory.new, false)
  Mystral::FoldingRangeProvider.new(ctx).folding_range(
    JSON.parse(%({"textDocument":{"uri":"#{URI}"}}))
  )
end

private def ranges(folds) : Array({Int32, Int32})
  folds.map { |f| {f.start_line, f.end_line} }
end

describe Mystral::FoldingRangeProvider do
  it "emits a fold spanning a multi-line container and its def" do
    rs = ranges(folds("class Foo\n  def bar\n  end\nend"))
    rs.should contain({0, 3}) # class Foo ... end
    rs.should contain({1, 2}) # def bar ... end
  end

  it "does not fold a single-line construct" do
    ranges(folds("class Foo; end")).should be_empty
  end

  it "returns empty on a syntax error" do
    folds("class Foo").should be_empty
  end

  # NOTE: that foldingRange is NOT advertised in the capability set is enforced
  # by the Router spec ("never advertises foldingRange") — the handler here is
  # wired only so a client that asks anyway gets a correct answer.
end
