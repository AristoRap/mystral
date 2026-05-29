require "../spec_helper"
require "../../src/mystral_cli/missing_requires"

private def grouped(*messages : String) : Hash(String, Array(MystralCLI::CompileRunner::CrystalError))
  errs = messages.map do |m|
    MystralCLI::CompileRunner::CrystalError.from_json(%({"file":"x.cr","line":1,"column":1,"size":1,"message":#{m.to_json}}))
  end
  {"x.cr" => errs.to_a}
end

describe MystralCLI::MissingRequires do
  describe ".detect" do
    it "pulls unresolved require names from the error messages" do
      g = grouped("can't find file 'radix'", "can't find file 'kemal/foo'")
      MystralCLI::MissingRequires.detect(g).should eq(Set{"radix", "kemal/foo"})
    end

    it "is empty when nothing is a require failure" do
      MystralCLI::MissingRequires.detect(grouped("undefined method 'foo'")).should be_empty
    end
  end

  describe ".shard_yml_diagnostics" do
    it "anchors the diagnostic on the declaring dependency line" do
      file = File.tempfile("shard", ".yml") do |f|
        f.print "name: app\ndependencies:\n  radix:\n    github: foo/radix\n"
      end
      begin
        diags = MystralCLI::MissingRequires.shard_yml_diagnostics(file.path, Set{"radix"})
        diags.size.should eq(1)
        json = JSON.parse(diags.first.to_json)
        json["range"]["start"]["line"].as_i.should eq(2) # the `  radix:` line
        json["message"].as_s.should contain("radix")
      ensure
        file.delete
      end
    end

    it "anchors at the top of shard.yml when the dep isn't declared" do
      file = File.tempfile("shard", ".yml") { |f| f.print "name: app\n" }
      begin
        diags = MystralCLI::MissingRequires.shard_yml_diagnostics(file.path, Set{"ghost"})
        JSON.parse(diags.first.to_json)["range"]["start"]["line"].as_i.should eq(0)
      ensure
        file.delete
      end
    end
  end
end
