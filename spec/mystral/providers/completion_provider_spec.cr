require "../../spec_helper"

private URI = "file:///t.cr"

# Sources are kept parse-valid (a name follows the separator) so the index is
# populated; the cursor sits right after the separator, so the completion
# prefix is empty — exactly the state when the editor requests completion.
private def complete(src : String, line : Int32, char : Int32) : Array(Mystral::LSP::CompletionItem)
  index = Mystral::Index.new
  index.reindex(URI, src)
  docs = Mystral::Documents.new
  docs.set(URI, src)
  ctx = Mystral::ServerContext.new(index, docs, IO::Memory.new, false)
  Mystral::CompletionProvider.new(ctx).completion(
    JSON.parse(%({"textDocument":{"uri":"#{URI}"},"position":{"line":#{line},"character":#{char}}}))
  )
end

private def labels(items) : Array(String)
  items.map(&.label)
end

describe Mystral::CompletionProvider do
  it "lists class methods and `new` (not instance methods) after `Foo.`" do
    src = "class Foo\n  def self.make\n  end\n  def inst\n  end\n  def initialize\n  end\n  class Inner\n  end\nend\nFoo.x"
    ls = labels(complete(src, 10, 4)) # cursor right after `Foo.`
    ls.should contain("make")
    ls.should contain("new")  # initialize surfaced as new
    ls.should_not contain("inst")
    ls.should_not contain("initialize")
  end

  it "lists nested types after `Foo::`" do
    src = "class Foo\n  def self.make\n  end\n  class Inner\n  end\nend\nFoo::Inner"
    ls = labels(complete(src, 6, 5)) # cursor right after `Foo::`
    ls.should contain("Inner")
    ls.should_not contain("make")
  end

  it "attaches a .→:: text edit when a nested type is completed after a dot" do
    src = "class Foo\n  class Inner\n  end\nend\nFoo.x"
    inner = complete(src, 4, 4).find { |i| i.label == "Inner" }.not_nil!
    inner.additional_text_edits.should_not be_nil
    inner.additional_text_edits.not_nil!.first.new_text.should eq("::")
  end

  it "lists instance methods (not class methods) after an instance receiver" do
    src = "class Widget\n  def render\n  end\n  def self.build\n  end\nend\nclass App\n  @w : Widget\n  def go\n    @w.render\n  end\nend"
    ls = labels(complete(src, 9, 7)) # cursor right after `@w.`
    ls.should contain("render")
    ls.should_not contain("build")
  end

  it "filters out private methods" do
    src = "class Foo\n  def self.pub\n  end\n  private def self.priv\n  end\nend\nFoo.x"
    ls = labels(complete(src, 6, 4))
    ls.should contain("pub")
    ls.should_not contain("priv")
  end

  it "filters by the typed prefix" do
    src = "class Foo\n  def self.make\n  end\n  def self.made\n  end\n  def self.zip\n  end\nend\nFoo.ma"
    ls = labels(complete(src, 8, 6)) # cursor after `Foo.ma`
    ls.should contain("make")
    ls.should contain("made")
    ls.should_not contain("zip")
  end

  it "returns nothing for bare-prefix completion (no receiver)" do
    src = "class Foo\nend\nFo"
    complete(src, 2, 2).should be_empty
  end
end
