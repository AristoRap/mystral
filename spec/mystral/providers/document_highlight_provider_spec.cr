require "../../spec_helper"

private def context_with(uri : String, text : String) : Mystral::ServerContext
  index = Mystral::Index.new
  docs = Mystral::Documents.new
  docs.set(uri, text)
  index.reindex(uri, text)
  Mystral::ServerContext.new(index, docs, IO::Memory.new, false)
end

private def highlight(uri, text, line, char) : Array(Mystral::LSP::DocumentHighlight)?
  provider = Mystral::DocumentHighlightProvider.new(context_with(uri, text))
  params = JSON.parse(%({"textDocument":{"uri":"#{uri}"},"position":{"line":#{line},"character":#{char}}}))
  provider.document_highlight(params)
end

# Pull the (line, start, end) tuples out of the serialized highlights.
private def ranges(highlights) : Array({Int32, Int32, Int32})
  highlights.not_nil!.map do |h|
    j = JSON.parse(h.to_json)["range"]
    {j["start"]["line"].as_i, j["start"]["character"].as_i, j["end"]["character"].as_i}
  end
end

describe Mystral::DocumentHighlightProvider do
  it "highlights every occurrence of the cursor's identifier in the file" do
    text = "x = 1\nputs x\nx = x + 1"
    result = ranges(highlight("file:///t.cr", text, 0, 0)) # cursor on first `x`
    result.should contain({0, 0, 1})
    result.should contain({1, 5, 6})
    result.should contain({2, 0, 1})
    result.should contain({2, 4, 5})
  end

  it "returns nil when the cursor is not on an identifier" do
    highlight("file:///t.cr", "a   b", 0, 2).should be_nil
  end

  it "uses word_at-faithful spans including a ? suffix" do
    result = ranges(highlight("file:///t.cr", "empty?\nempty?", 0, 1))
    result.should contain({0, 0, 6})
    result.should contain({1, 0, 6})
  end
end
