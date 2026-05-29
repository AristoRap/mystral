require "../spec_helper"

describe Mystral::InferenceIndex do
  describe "position facts (version-gated)" do
    it "serves a fact only when the version matches the live buffer" do
      idx = Mystral::InferenceIndex.new
      idx.put("file:///a.cr", "v1", { {0, 0} => Mystral::InferenceIndex::Fact.new("String") })
      idx.fact_at("file:///a.cr", "v1", 0, 0).not_nil!.type.should eq("String")
    end

    it "returns nil AND drops the bucket on a version mismatch (never stale)" do
      idx = Mystral::InferenceIndex.new
      idx.put("file:///a.cr", "v1", { {0, 0} => Mystral::InferenceIndex::Fact.new("String") })
      idx.fact_at("file:///a.cr", "v2", 0, 0).should be_nil # stale → evicted
      idx.fact_at("file:///a.cr", "v1", 0, 0).should be_nil # bucket was dropped
    end
  end

  describe "scope-local types" do
    it "serves a whole scope's locals at the matching version" do
      idx = Mystral::InferenceIndex.new
      idx.set_scope_locals("file:///a.cr", "v1", 3, {"x" => "Int32", "y" => "String"})
      idx.scope_local_type("file:///a.cr", "v1", 3, "x").should eq("Int32")
      idx.scope_local_type("file:///a.cr", "v1", 3, "y").should eq("String")
    end

    it "evicts on a version mismatch" do
      idx = Mystral::InferenceIndex.new
      idx.set_scope_locals("file:///a.cr", "v1", 3, {"x" => "Int32"})
      idx.scope_local_type("file:///a.cr", "v2", 3, "x").should be_nil
      idx.scope_local_type("file:///a.cr", "v1", 3, "x").should be_nil
    end
  end

  describe "ancestry" do
    it "stores and serves reaped ancestors, wholesale-replaced" do
      idx = Mystral::InferenceIndex.new
      idx.set_ancestry({"B" => ["A"]})
      idx.ancestors_of("B").should eq(["A"])
      idx.ancestors_of("Z").should be_nil
      idx.set_ancestry({"C" => ["D"]}) # replaces, not merges
      idx.ancestors_of("B").should be_nil
      idx.ancestors_of("C").should eq(["D"])
    end
  end

  describe "memory bounds (RAM stays bounded, never session-growing)" do
    max = Mystral::InferenceIndex::MAX_URIS

    it "coarse-clears position facts when a new URI overflows MAX_URIS" do
      idx = Mystral::InferenceIndex.new
      max.times do |i|
        idx.put("file:///f#{i}.cr", "v", { {0, 0} => Mystral::InferenceIndex::Fact.new("T") })
      end
      idx.fact_at("file:///f0.cr", "v", 0, 0).should_not be_nil # full, still present

      # The (max+1)-th distinct URI triggers a coarse clear, not unbounded growth.
      idx.put("file:///overflow.cr", "v", { {0, 0} => Mystral::InferenceIndex::Fact.new("T") })
      idx.fact_at("file:///f0.cr", "v", 0, 0).should be_nil           # prior facts dropped
      idx.fact_at("file:///overflow.cr", "v", 0, 0).should_not be_nil # newest kept
    end

    it "coarse-clears scope-locals when a new URI overflows MAX_URIS" do
      idx = Mystral::InferenceIndex.new
      max.times do |i|
        idx.set_scope_locals("file:///f#{i}.cr", "v", 0, {"x" => "Int32"})
      end
      idx.scope_local_type("file:///f0.cr", "v", 0, "x").should eq("Int32")

      idx.set_scope_locals("file:///overflow.cr", "v", 0, {"x" => "Int32"})
      idx.scope_local_type("file:///f0.cr", "v", 0, "x").should be_nil
      idx.scope_local_type("file:///overflow.cr", "v", 0, "x").should eq("Int32")
    end

    it "re-putting an already-tracked URI never triggers a clear" do
      idx = Mystral::InferenceIndex.new
      max.times do |i|
        idx.put("file:///f#{i}.cr", "v", { {0, 0} => Mystral::InferenceIndex::Fact.new("T") })
      end
      # Updating an existing key (has_key? == true) stays at the cap, no clear.
      idx.put("file:///f0.cr", "v", { {0, 0} => Mystral::InferenceIndex::Fact.new("U") })
      idx.fact_at("file:///f1.cr", "v", 0, 0).should_not be_nil
      idx.fact_at("file:///f0.cr", "v", 0, 0).not_nil!.type.should eq("U")
    end
  end

  it "forgetting one URI leaves another's facts intact" do
    idx = Mystral::InferenceIndex.new
    idx.put("file:///a.cr", "v1", { {0, 0} => Mystral::InferenceIndex::Fact.new("A") })
    idx.put("file:///b.cr", "v1", { {0, 0} => Mystral::InferenceIndex::Fact.new("B") })
    idx.set_scope_locals("file:///b.cr", "v1", 3, {"x" => "Int32"})
    idx.forget("file:///a.cr")
    idx.fact_at("file:///a.cr", "v1", 0, 0).should be_nil
    idx.fact_at("file:///b.cr", "v1", 0, 0).not_nil!.type.should eq("B")
    idx.scope_local_type("file:///b.cr", "v1", 3, "x").should eq("Int32")
  end

  it "forgets a URI's facts on close" do
    idx = Mystral::InferenceIndex.new
    idx.put("file:///a.cr", "v1", { {0, 0} => Mystral::InferenceIndex::Fact.new("X") })
    idx.set_scope_locals("file:///a.cr", "v1", 3, {"x" => "Int32"})
    idx.forget("file:///a.cr")
    idx.fact_at("file:///a.cr", "v1", 0, 0).should be_nil
    idx.scope_local_type("file:///a.cr", "v1", 3, "x").should be_nil
  end
end
