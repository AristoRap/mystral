module MystralCLI
  module Commands
    # `mystral check FILE` — runs the parser + index pipeline on a single file
    # and prints what Mystral would see, no editor in the loop. Same code path
    # as textDocument/didOpen, minus the LSP transport.
    class Check
      def initialize(@output : IO = STDOUT)
      end

      def run(file_path : String) : Nil
        text = File.read(file_path)
        uri = "file://#{File.expand_path(file_path)}"

        index = Mystral::Index.new
        error = index.reindex(uri, text)
        symbols = index.symbols_in(uri)

        @output << "file: " << file_path << "\n"
        @output << "  symbols (" << symbols.size << "):\n"
        if symbols.empty?
          @output << "    (none — parse failed; see diagnostics below)\n" if error
        else
          symbols.each do |s|
            kind_col = "[#{s.kind}]".ljust(10)
            loc = "#{(s.line + 1).to_s.rjust(4)}:#{(s.column + 1).to_s.ljust(3)}"
            sig = s.signature ? "  #{s.signature}" : ""
            @output << "    " << kind_col << " " << s.name.ljust(30) << " " << loc << sig << "\n"
          end
        end

        @output << "  diagnostics:\n"
        if error
          @output << "    [error] " << error.line_number << ":" << error.column_number << "  "
          @output << (error.message || "syntax error") << "\n"
        else
          @output << "    ok\n"
        end
      end

      def to_command : Argy::Command
        cmd = Argy::Command.new(
          use: "check FILE",
          short: "Parse FILE and print discovered symbols + diagnostics",
          long: "Runs Mystral's parser + symbol index on a single Crystal source file and prints what it found. Same code path as a real textDocument/didOpen, minus the LSP transport.",
        )
        cmd.on_run do |_cmd, args|
          if args.empty?
            STDERR.puts "mystral check: missing FILE argument"
            exit 2
          end
          run(args.first)
        end
        cmd
      end
    end
  end
end
