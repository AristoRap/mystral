require "../../spec_helper"

private def scanner(text : String) : Mystral::TextScanner
  Mystral::TextScanner.new(text)
end

describe Mystral::TextScanner do
  describe "#word_at" do
    it "returns the identifier under the cursor" do
      scanner("foo_bar = 1").word_at(0, 2).should eq("foo_bar")
    end

    it "returns the word when the cursor is one past it (editor convention)" do
      # cursor at column 7 == just past `foo_bar`
      scanner("foo_bar").word_at(0, 7).should eq("foo_bar")
    end

    it "includes a trailing `!` or `?` method suffix" do
      scanner("save!").word_at(0, 1).should eq("save!")
      scanner("empty?").word_at(0, 1).should eq("empty?")
    end

    it "includes a setter `=` but not `==` or `=>`" do
      scanner("name = 1").word_at(0, 0).should eq("name") # `name =` is `name=`? no: space breaks it
      scanner("count= 1").word_at(0, 0).should eq("count=")
      scanner("a == b").word_at(0, 0).should eq("a")  # not `a=`
      scanner("k => v").word_at(0, 0).should eq("k")  # not `k=`
    end

    it "does NOT swallow `?` into CamelCase nilable shorthand (Foo?)" do
      scanner("x : Foo?").word_at(0, 4).should eq("Foo")
    end

    it "snaps onto the ivar name when the cursor is on the `@` sigil" do
      scanner("@count").word_at(0, 0).should eq("count")
    end

    it "snaps onto the cvar name when the cursor is on the `@@` sigil" do
      scanner("@@total").word_at(0, 0).should eq("total")
    end

    it "returns nil on whitespace" do
      scanner("a   b").word_at(0, 2).should be_nil
    end

    it "returns nil out of range" do
      scanner("abc").word_at(5, 0).should be_nil
    end
  end

  describe "#receiver_at" do
    it "extracts a CamelCase qualified receiver before `::`" do
      scanner("Foo::Bar.baz").receiver_at(0, 9).should eq("Foo::Bar")
    end

    it "normalizes a `.`-joined CamelCase prefix to `::`" do
      # cursor on `baz`; the prefix `Foo.Bar` normalizes to `Foo::Bar`
      scanner("Foo.Bar.baz").receiver_at(0, 9).should eq("Foo::Bar")
    end

    it "extracts a variable chain before `.`" do
      scanner("@app.event").receiver_at(0, 6).should eq("@app")
    end

    it "extracts a multi-segment variable chain" do
      scanner("foo.bar.baz").receiver_at(0, 9).should eq("foo.bar")
    end

    it "strips a generic tail so Set(String).new resolves as Set" do
      scanner("Set(String).new").receiver_at(0, 13).should eq("Set")
    end

    it "returns nil when the receiver is a keyword" do
      scanner("self.foo").receiver_at(0, 6).should be_nil
    end

    it "returns nil with no receiver" do
      scanner("bare").receiver_at(0, 2).should be_nil
    end
  end

  describe "#ivar_kind_at" do
    it "reports ivar for @field" do
      scanner("@field").ivar_kind_at(0, 3).should eq("ivar")
    end

    it "reports cvar for @@var" do
      scanner("@@var").ivar_kind_at(0, 3).should eq("cvar")
    end

    it "reports nil for a plain identifier" do
      scanner("field").ivar_kind_at(0, 2).should be_nil
    end
  end

  describe "#in_comment_or_string?" do
    it "is true inside a line comment" do
      scanner("x = 1 # note here").in_comment_or_string?(0, 12).should be_true
    end

    it "is true inside a string literal" do
      scanner(%(s = "hello")).in_comment_or_string?(0, 7).should be_true
    end

    it "is false inside string interpolation (it's real code)" do
      # literal source: s = "hi #{name}" — cursor on `name` (col 10)
      scanner(%q(s = "hi #{name}")).in_comment_or_string?(0, 10).should be_false
    end

    it "is false on ordinary code" do
      scanner("x = 1").in_comment_or_string?(0, 0).should be_false
    end
  end

  describe "scan_identifiers / word_at agreement (property)" do
    it "yields spans whose substring equals word_at for every interior cursor" do
      samples = [
        "foo.bar(baz, qux?)",
        "@app.event = handler!",
        "Foo::Bar.new(x : Int32)",
        "result = compute(a, b) # comment",
        "name= value",
      ]
      samples.each do |line|
        sc = scanner(line)
        Mystral::TextScanner.scan_identifiers(line) do |start_col, end_col, name|
          # The yielded substring is the name itself.
          line[start_col...end_col].should eq(name)
          # And word_at at every column inside the span returns that name.
          (start_col...end_col).each do |col|
            sc.word_at(0, col).should eq(name)
          end
        end
      end
    end
  end

  describe ".chain_expr_at_end" do
    it "returns the trailing chain expression" do
      Mystral::TextScanner.chain_expr_at_end("x = @app.event").should eq("@app.event")
      Mystral::TextScanner.chain_expr_at_end("Foo::Bar").should eq("Foo::Bar")
    end
  end
end
