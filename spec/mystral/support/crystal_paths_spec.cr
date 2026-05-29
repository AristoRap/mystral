require "../../spec_helper"

describe Mystral::CrystalPaths do
  describe ".parse_path_string" do
    it "splits the list and drops empty entries" do
      sep = Mystral::CrystalPaths::LIST_SEPARATOR
      Mystral::CrystalPaths.parse_path_string("lib#{sep}/usr/stdlib#{sep}").should eq(["lib", "/usr/stdlib"])
    end
  end

  describe ".resolve" do
    it "anchors relative entries to each root and passes absolute ones through" do
      resolved = Mystral::CrystalPaths.resolve(["lib", "/abs/stdlib"], ["/work/a", "/work/b"])
      resolved.should contain("/work/a/lib")
      resolved.should contain("/work/b/lib")
      resolved.should contain("/abs/stdlib")
    end

    it "deduplicates" do
      Mystral::CrystalPaths.resolve(["/abs", "/abs"], [] of String).should eq(["/abs"])
    end
  end
end
