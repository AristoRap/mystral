require "../../spec_helper"

private def ctx_at(text : String, line : Int32, char : Int32) : Mystral::CursorContext
  Mystral::CursorContext.at("file:///t.cr", Mystral::TextScanner.new(text), line, char)
end

describe Mystral::CursorContext do
  it "captures the word, receiver, and token-start in one pass" do
    ctx = ctx_at("@app.event", 0, 6) # cursor on `event`
    ctx.word.should eq("event")
    ctx.receiver.should eq("@app")
    ctx.identifier_start_col.should eq(5)
    ctx.ivar_kind.should be_nil
  end

  it "flags an ivar cursor" do
    ctx = ctx_at("@count", 0, 2)
    ctx.word.should eq("count")
    ctx.ivar_kind.should eq("ivar")
  end

  it "reports on_identifier? false inside a comment" do
    ctx = ctx_at("x = 1 # note", 0, 9)
    ctx.in_comment_or_string.should be_true
    ctx.on_identifier?.should be_false
  end

  it "reports on_identifier? true on a plain identifier" do
    ctx_at("value = 1", 0, 1).on_identifier?.should be_true
  end

  it "reports on_identifier? false on whitespace" do
    ctx_at("a   b", 0, 2).on_identifier?.should be_false
  end
end
