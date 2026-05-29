require "../../spec_helper"
require "../../../src/mystral_cli"

describe MystralCLI::Commands::Check do
  it "prints discovered symbols and an ok diagnostic for valid source" do
    file = File.tempfile("check", ".cr") { |f| f.print "class Greeter\n  def greet\n  end\nend\n" }
    begin
      io = IO::Memory.new
      MystralCLI::Commands::Check.new(io).run(file.path)
      out = io.to_s
      out.should contain("Greeter")
      out.should contain("greet")
      out.should contain("ok")
    ensure
      file.delete
    end
  end

  it "reports the syntax error for invalid source" do
    file = File.tempfile("check", ".cr") { |f| f.print "def oops(\n" }
    begin
      io = IO::Memory.new
      MystralCLI::Commands::Check.new(io).run(file.path)
      io.to_s.should contain("[error]")
    ensure
      file.delete
    end
  end
end
