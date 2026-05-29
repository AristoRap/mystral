require "./commands/version"
require "./commands/check"
require "./compile_processor"

module MystralCLI
  module Root
    def self.build : Argy::Command
      root = Argy::Command.new(
        use: "mystral",
        short: "Index-driven LSP for Crystal",
        long: "Runs the Mystral language server on stdio by default."
      )
      # Persistent --debug/-d (inherited by subcommands); also honored via the
      # MYSTRAL_DEBUG env var. Turns on the verbose log_debug lines.
      root.persistent_flags.bool("debug", 'd', false, "verbose debug logging")

      root.on_run do |cmd, _args|
        server = Mystral::Server.new(debug: cmd.bool_flag("debug"))
        # Build the compile processor with access to the server's shared state
        # (workspace_roots is shared by reference, so the closure sees roots
        # once the LSP `initialize` handler populates them) and inject it.
        processor = MystralCLI::CompileProcessor.build(server.context, server.log, debug: server.debug?)
        server.use_compile_processor(processor)
        server.log.puts "[#{Time.local.to_s("%H:%M:%S.%L")}] root: compile processor wired (debug=#{server.debug?})"
        server.run
      end

      root.add_command(
        Commands::Version.new.to_command,
        Commands::Check.new.to_command
      )
      root
    end
  end
end
