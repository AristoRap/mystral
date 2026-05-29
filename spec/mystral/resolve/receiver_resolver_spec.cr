require "../../spec_helper"

private URI = "file:///t.cr"

private def receiver_resolver_for(src : String) : Mystral::ReceiverResolver
  index = Mystral::Index.new
  index.reindex(URI, src)
  docs = Mystral::Documents.new
  docs.set(URI, src)
  Mystral::Resolver.new(index, docs).receiver_resolver
end

describe Mystral::ReceiverResolver do
  describe "#resolve_variable" do
    it "types an ivar receiver from its declaration" do
      src = "class Widget\nend\nclass App\n  @widget : Widget\n  def go\n  end\nend"
      rr = receiver_resolver_for(src)
      rr.resolve_variable("@widget", ["App"], URI, 4).should eq("Widget")
    end

    it "types a getter-backed variable receiver" do
      src = "class Widget\nend\nclass App\n  getter widget : Widget\n  def go\n  end\nend"
      rr = receiver_resolver_for(src)
      rr.resolve_variable("widget", ["App"], URI, 4).should eq("Widget")
    end
  end

  describe "#resolve_chain" do
    it "follows a method-return chain to the final type" do
      src = <<-CR
        class Result
        end
        class Widget
          def build : Result
          end
        end
        class App
          @w : Widget
          def go
          end
        end
        CR
      rr = receiver_resolver_for(src)
      # @w : Widget, Widget#build : Result  →  @w.build is a Result
      rr.resolve_chain("@w.build", ["App"], URI, 8).should eq("Result")
    end

    it "resolves a qualified type prefix" do
      src = "module App\n  class Widget\n  end\nend"
      rr = receiver_resolver_for(src)
      rr.resolve_chain("App::Widget", ([] of String), URI, 0).should eq("App::Widget")
    end

    it "returns nil when a step doesn't resolve" do
      src = "class C\n  def go\n  end\nend"
      rr = receiver_resolver_for(src)
      rr.resolve_chain("mystery.thing", ["C"], URI, 1).should be_nil
    end
  end

  describe "#value_type" do
    it "types a local from a `Type.new` assignment" do
      src = "class Thing\nend\ndef f\n  x = Thing.new\nend"
      rr = receiver_resolver_for(src)
      rr.value_type("x", URI, 3).should eq("Thing")
    end

    it "types a local from a typed parameter (no local assignment)" do
      src = "class Thing\nend\nclass C\n  def go(item : Thing)\n    item\n  end\nend"
      rr = receiver_resolver_for(src)
      rr.value_type("item", URI, 4).should eq("Thing")
    end

    it "lets a local assignment shadow a same-named parameter" do
      src = "class A\nend\nclass B\nend\ndef f(x : A)\n  x = B.new\nend"
      rr = receiver_resolver_for(src)
      # the `x = B.new` reassignment wins over the `x : A` param
      rr.value_type("x", URI, 5).should eq("B")
    end
  end
end
