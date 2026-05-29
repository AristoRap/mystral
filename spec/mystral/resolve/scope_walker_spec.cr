require "../../spec_helper"

private URI = "file:///t.cr"

private def scope_walker(src : String) : Mystral::ScopeWalker
  index = Mystral::Index.new
  index.reindex(URI, src)
  Mystral::ScopeWalker.new(index, Mystral::TypeResolver.new(index))
end

describe Mystral::ScopeWalker do
  describe "#enclosing_containers" do
    it "returns the containers whose range holds the line, innermost first" do
      src = <<-CR
        module App
          class Page
            def go
            end
          end
        end
        CR
      # line 2 (def go) is inside App::Page and App
      scope_walker(src).enclosing_containers(URI, 2).should eq(["App::Page", "App"])
    end

    it "returns empty at top level" do
      scope_walker("x = 1").enclosing_containers(URI, 0).should be_empty
    end
  end

  describe "#chain_at" do
    it "expands the enclosing scope with its superclass" do
      src = <<-CR
        class Base
        end
        class Page < Base
          def go
          end
        end
        CR
      chain = scope_walker(src).chain_at(URI, 3) # inside Page#go
      chain.should contain("Page")
      chain.should contain("Base")
    end

    it "expands the enclosing scope with an included module" do
      src = <<-CR
        module Mix
        end
        class Page
          include Mix
          def go
          end
        end
        CR
      chain = scope_walker(src).chain_at(URI, 4) # inside Page#go
      chain.should contain("Page")
      chain.should contain("Mix")
    end
  end

  describe "#inheritance_chain" do
    it "lists a class plus its ancestors, closest first" do
      src = <<-CR
        class A
        end
        class B < A
        end
        class C < B
        end
        CR
      scope_walker(src).inheritance_chain("C").should eq(["C", "B", "A"])
    end

    it "falls back to reaped ancestry when AST parent resolution fails (generic super)" do
      # `class B < A(Int32)` — the generic super doesn't match any indexed `A`,
      # so resolve_ast_parent fails and the reaped ancestry fills the gap.
      sw = scope_walker("class B < A(Int32)\nend")
      sw.inheritance_chain("B").should eq(["B"]) # no ancestry source yet
      sw.ancestry_source = ->(fqn : String) { fqn == "B" ? ["A"] : nil }
      sw.inheritance_chain("B").should eq(["B", "A"])
    end
  end
end
