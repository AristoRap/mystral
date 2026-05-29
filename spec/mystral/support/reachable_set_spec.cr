require "../../spec_helper"
require "file_utils"

private def with_tree(&)
  root = File.join(Dir.tempdir, "mystral_reach_#{Process.pid}_#{Time.utc.to_unix_ns}")
  Dir.mkdir_p(root)
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe Mystral::ReachableSet do
  it "follows relative requires from an entry point" do
    with_tree do |root|
      File.write(File.join(root, "a.cr"), "require \"./b\"\nclass A\nend")
      File.write(File.join(root, "b.cr"), "class B\nend")
      reachable = Mystral::ReachableSet.from([File.join(root, "a.cr")])
      reachable.should contain(File.join(root, "a.cr"))
      reachable.should contain(File.join(root, "b.cr"))
    end
  end

  it "excludes a file whose entire top-level is a host-false macro guard" do
    with_tree do |root|
      File.write(File.join(root, "live.cr"), "class Live\nend")
      # `:fake_os` is unknown → flag? is false → the whole file is host-inactive.
      File.write(File.join(root, "dead.cr"), "{% if flag?(:fake_os) %}\nclass Dead\nend\n{% end %}")
      walker = Mystral::ReachableSet.new
      walker.add_workspace_root(root)
      walker.reachable.should contain(File.join(root, "live.cr"))
      walker.reachable.should_not contain(File.join(root, "dead.cr"))
    end
  end
end
