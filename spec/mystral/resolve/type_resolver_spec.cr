require "../../spec_helper"

private def type_resolver(src : String) : Mystral::TypeResolver
  index = Mystral::Index.new
  index.reindex("file:///t.cr", src)
  Mystral::TypeResolver.new(index)
end

describe Mystral::TypeResolver do
  describe "pure helpers" do
    it "splits an FQN into {simple, container}" do
      Mystral::TypeResolver.split_fqn("Foo::Bar::Baz").should eq({"Baz", "Foo::Bar"})
      Mystral::TypeResolver.split_fqn("Foo").should eq({"Foo", nil})
    end

    it "lists lexical ancestors inner-first" do
      Mystral::TypeResolver.lexical_ancestors("App::Page").should eq(["App::Page", "App"])
    end

    it "strips generics to the base type" do
      Mystral::TypeResolver.base_type("Array(String)").should eq("Array")
      Mystral::TypeResolver.base_type("Foo::Bar(T)").should eq("Foo::Bar")
      Mystral::TypeResolver.base_type("Plain").should eq("Plain")
    end

    it "classifies receiver shapes" do
      Mystral::TypeResolver.variable_receiver?("@app").should be_true
      Mystral::TypeResolver.variable_receiver?("app").should be_true
      Mystral::TypeResolver.variable_receiver?("Foo").should be_false
      Mystral::TypeResolver.chain_like?("a.b").should be_true
      Mystral::TypeResolver.chain_like?("Foo::Bar").should be_true
      Mystral::TypeResolver.chain_like?("plain").should be_false
      Mystral::TypeResolver.type_shaped?("Foo").should be_true
      Mystral::TypeResolver.type_shaped?("foo").should be_false
    end
  end

  describe "#resolve_receiver" do
    it "resolves a name against the lexical scope, innermost first" do
      tr = type_resolver("module App\n  class Widget\n  end\nend")
      tr.resolve_receiver("Widget", ["App::Page", "App"]).should eq("App::Widget")
    end

    it "returns nil for an unknown type" do
      tr = type_resolver("class Foo\nend")
      tr.resolve_receiver("Bar", [] of String).should be_nil
    end
  end

  describe "#follow_alias" do
    it "follows an alias to its target" do
      tr = type_resolver("class Real\nend\nalias Nick = Real")
      tr.follow_alias("Nick", [] of String).should eq("Real")
    end

    it "is idempotent for a non-alias" do
      tr = type_resolver("class Real\nend")
      tr.follow_alias("Real", [] of String).should eq("Real")
    end
  end
end
