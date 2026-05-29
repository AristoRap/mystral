require "../../spec_helper"
require "compiler/crystal/syntax"

private def eval_cond(src : String) : Bool?
  Mystral::FlagEvaluator.evaluate(::Crystal::Parser.new(src).parse)
end

describe Mystral::FlagEvaluator do
  it "evaluates boolean literals and operators (host-independent)" do
    eval_cond("true").should be_true
    eval_cond("false").should be_false
    eval_cond("!true").should be_false
    eval_cond("true && false").should be_false
    eval_cond("true || false").should be_true
  end

  it "treats an unknown flag as not present" do
    eval_cond("flag?(:some_made_up_flag_xyz)").should be_false
  end

  it "returns nil for a condition it can't model (so callers follow both)" do
    eval_cond("some_method_call").should be_nil
  end

  it "absorbs with three-valued logic (false && unknown = false)" do
    eval_cond("flag?(:some_made_up_flag_xyz) && some_unknown").should be_false
    eval_cond("flag?(:some_made_up_flag_xyz) || some_unknown").should be_nil
  end
end

describe Mystral::HostFlags do
  it "matches a recognized host flag and rejects an unknown one" do
    # This binary is built for some real OS, so at least one of these is true.
    {"darwin", "linux", "windows", "freebsd", "openbsd"}.any? { |f| Mystral::HostFlags.matches?(f) }.should be_true
    Mystral::HostFlags.matches?("not_a_real_flag").should be_false
  end
end
