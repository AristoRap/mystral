require "./spec_helper"

describe Mystral do
  it "exposes a version string" do
    Mystral::VERSION.should_not be_empty
  end
end
