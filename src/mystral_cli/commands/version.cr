module MystralCLI
  module Commands
    class Version
      def to_command : Argy::Command
        command = Argy::Command.new(
          use: "version",
          short: "Print the Mystral version",
          long: "Print the Mystral version and exit."
        )
        command.on_run do |_cmd, _args|
          puts "mystral #{Mystral.build_version}"
        end
        command
      end
    end
  end
end
