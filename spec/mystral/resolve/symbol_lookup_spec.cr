require "../../spec_helper"

private URI = "file:///t.cr"

private def resolver_for(src : String) : Mystral::Resolver
  index = Mystral::Index.new
  index.reindex(URI, src)
  Mystral::Resolver.new(index)
end

# matches_at, returning the containers of the resolved symbols.
private def containers(src : String, name : String, line : Int32, receiver : String? = nil) : Array(String?)
  resolver_for(src).matches_at(name, URI, receiver, line).map(&.container)
end

describe Mystral::SymbolLookup do
  it "walks up the inheritance chain for a bare method call" do
    src = <<-CR
      class A
        def helper
        end
      end
      class B < A
        def go
          helper
        end
      end
      CR
    # cursor on `helper` (line 6) inside B#go resolves to A#helper
    containers(src, "helper", 6).should eq(["A"])
  end

  it "resolves a method mixed in via include" do
    src = <<-CR
      module Helpers
        def assist
        end
      end
      class Page
        include Helpers
        def render
          assist
        end
      end
      CR
    containers(src, "assist", 7).should eq(["Helpers"])
  end

  it "resolves a bare type receiver via the lexical name ladder" do
    src = <<-CR
      module App
        class Widget
          def build
          end
        end
        class Page
          def go
            Widget.build
          end
        end
      end
      CR
    # `Widget.build` inside App::Page → App::Widget#build
    containers(src, "build", 7, receiver: "Widget").should eq(["App::Widget"])
  end

  it "collapses class reopenings to one symbol (bare type reference)" do
    src = <<-CR
      class Foo
        def a
        end
      end
      class Foo
        def b
        end
      end
      CR
    matches = resolver_for(src).matches_at("Foo", URI, nil, 8)
    matches.size.should eq(1)
    matches.first.kind.should eq("class")
  end

  it "keeps N method overloads (does NOT dedupe defs)" do
    src = <<-CR
      class Calc
        def add(x : Int32)
        end
        def add(x : String)
        end
      end
      CR
    # `Calc.add` → both overloads
    resolver_for(src).matches_at("add", URI, "Calc", 1).size.should eq(2)
  end

  it "reaches a top-level def from inside a class (implicit Object)" do
    src = <<-CR
      def helper
      end
      class C
        def go
          helper
        end
      end
      CR
    containers(src, "helper", 4).should eq([nil])
  end

  it "does NOT resolve a bare identifier to an ivar" do
    src = <<-CR
      class C
        @count : Int32
        def go
          count
        end
      end
      CR
    containers(src, "count", 3).should be_empty
  end

  it "defers variable / chain receivers until the ReceiverResolver lands" do
    src = <<-CR
      class C
        def go
          app.event
        end
      end
      CR
    # @receivers is nil at this increment → variable/chain receivers resolve []
    resolver_for(src).matches_at("event", URI, "app", 2).should be_empty
    resolver_for(src).matches_at("dispatch", URI, "app.event", 2).should be_empty
  end
end
