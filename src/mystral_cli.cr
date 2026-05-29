require "argy"
require "./mystral"
require "./mystral_cli/root"

# The command-line surface: `mystral` (run the LSP server on stdio),
# `mystral check FILE`, `mystral version`.
module MystralCLI
  def self.root_command : Argy::Command
    Root.build
  end

  def self.execute(argv : Array(String) = ARGV.to_a) : Nil
    root_command.execute(argv)
  end
end
