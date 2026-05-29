require "json"

module MystralCLI
  # Reaps ground-truth superclass ancestry from `crystal tool hierarchy -f
  # json` — the cases the parser's name-resolution can't reach (generic
  # supers, macro-derived types). A SEPARATE compile from diagnostics (the
  # tool doesn't surface type errors), so the caller runs it sparingly (once
  # per program). Never raises — a failure yields nil/empty (the worker fiber
  # must not die); the worst case is AST-only resolution.
  module Hierarchy
    extend self

    # One node of the hierarchy tree: a type plus its subtypes (nesting encodes
    # parent → children). Other keys are ignored.
    struct Node
      include JSON::Serializable
      getter name : String
      getter sub_types : Array(Node) = [] of Node
    end

    # Run the tool on one target; the raw JSON object string or nil on failure.
    def json_for(target : String) : String?
      stdout = IO::Memory.new
      stderr = IO::Memory.new
      status = Process.run(
        "crystal",
        ["tool", "hierarchy", "--no-color", "-f", "json", target],
        output: stdout, error: stderr,
      )
      return nil unless status.success?
      raw = stdout.to_s.strip
      raw.starts_with?("{") ? raw : nil
    end

    # Parse into `type FQN → ancestor FQNs (closest-first)`, keeping only
    # `workspace_fqns` types as KEYS (stdlib/dep ancestry resolves via the
    # indexed types; the stdlib spine still appears as ANCESTOR values).
    # Generic args normalized off every name so `A(Int32)` matches indexed `A`.
    def parse(json : String, workspace_fqns : Set(String)) : Hash(String, Array(String))
      acc = {} of String => Array(String)
      walk(Node.from_json(json), [] of String, workspace_fqns, acc)
      acc
    rescue JSON::ParseException
      {} of String => Array(String)
    end

    private def walk(node : Node, path : Array(String), workspace_fqns : Set(String), acc : Hash(String, Array(String))) : Nil
      name = normalize_type_name(node.name)
      # `path` is root-first (Object, Reference, …); ancestry wants
      # closest-first, so reverse.
      acc[name] = path.reverse if workspace_fqns.includes?(name)
      next_path = path + [name]
      node.sub_types.each { |child| walk(child, next_path, workspace_fqns, acc) }
    end

    # Strip generic type args at any depth: `A(Int32)` → `A`, `Hash(K, V)` →
    # `Hash`. The index records `class A(T)` under `A`.
    def normalize_type_name(name : String) : String
      String.build do |io|
        depth = 0
        name.each_char do |c|
          case c
          when '(' then depth += 1
          when ')' then depth -= 1 if depth > 0
          else          io << c if depth == 0
          end
        end
      end
    end
  end
end
