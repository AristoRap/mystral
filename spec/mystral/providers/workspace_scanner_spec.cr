require "../../spec_helper"
require "file_utils"

private def with_project(&)
  root = File.join(Dir.tempdir, "mystral_ws_#{Process.pid}_#{Time.utc.to_unix_ns}")
  Dir.mkdir_p(File.join(root, "src"))
  File.write(File.join(root, "shard.yml"), "name: proj\n")
  File.write(File.join(root, "src", "proj.cr"), "require \"./helper\"\nclass Proj\nend")
  File.write(File.join(root, "src", "helper.cr"), "class Helper\nend")
  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe Mystral::WorkspaceScanner do
  it "indexes the workspace and builds the reachability set" do
    with_project do |root|
      ctx = Mystral::ServerContext.new(Mystral::Index.new, Mystral::Documents.new, IO::Memory.new, false)
      scanner = Mystral::WorkspaceScanner.new(ctx)
      params = JSON.parse(%({"workspaceFolders":[{"uri":"file://#{root}"}],"capabilities":{}}))

      scanner.scan(params)

      names = [] of String
      ctx.index.each_symbol { |s| names << s.name }
      names.should contain("Proj")
      names.should contain("Helper")

      ctx.workspace_roots.should eq([root])
      ctx.index.workspace_reachable.should_not be_empty
    end
  end

  it "is a no-op with no workspace folders" do
    ctx = Mystral::ServerContext.new(Mystral::Index.new, Mystral::Documents.new, IO::Memory.new, false)
    Mystral::WorkspaceScanner.new(ctx).scan(JSON.parse(%({"capabilities":{}})))
    ctx.workspace_roots.should be_empty
  end
end
