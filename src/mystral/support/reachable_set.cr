require "compiler/crystal/syntax"
require "./flag_evaluator"

module Mystral
  # Walks the require graph from entry-point .cr files, producing the set of
  # paths Crystal would actually compile on this host — used to skip files
  # belonging to a different platform's `{% if flag?(:os) %}` branch. Relative
  # requires resolve against the requiring file's dir; absolute requires walk
  # `crystal_path` with Crystal's expansion order; macro-flag gates are
  # evaluated by FlagEvaluator (unknown ⇒ follow both). Glob requires expand to
  # every .cr in the matched dir. Returns absolute (expanded) paths.
  class ReachableSet
    def self.from(entries : Enumerable(String), crystal_path : Enumerable(String) = [] of String) : Set(String)
      walker = new(crystal_path)
      entries.each { |e| walker.add_entry(e) }
      walker.reachable
    end

    getter reachable : Set(String) = Set(String).new

    def initialize(crystal_path : Enumerable(String) = [] of String, exclude_dirs : Set(String) = Set(String).new)
      @crystal_path = crystal_path.to_a
      @exclude_dirs = exclude_dirs
    end

    def add_entry(path : String) : Nil
      walk_file(File.expand_path(path))
    end

    # Sweep a workspace root, including every .cr whose top-level ISN'T a
    # host-false macro guard (catches glob-required platform-split files the
    # require-walk misses).
    def add_workspace_root(root : String) : Nil
      return unless Dir.exists?(root)
      walk_workspace_dir(root)
    end

    # `spec/` holds test code: never in the program's reachable closure, so a
    # spec-only reopening shouldn't shadow the real definition. Spec files stay
    # INDEXED + DIAGNOSED; this only governs disambiguation preference.
    SWEEP_SKIP_DIRS = {"spec"}

    private def walk_workspace_dir(dir : String) : Nil
      Dir.each_child(dir) do |child|
        next if Mystral::Index::SCAN_SKIP_DIRS.includes?(child) || SWEEP_SKIP_DIRS.includes?(child) || @exclude_dirs.includes?(child)
        full = File.join(dir, child)
        if File.directory?(full)
          walk_workspace_dir(full)
        elsif child.ends_with?(".cr")
          abs = File.expand_path(full)
          next if @reachable.includes?(abs)
          @reachable << abs unless host_inactive_file?(abs)
        end
      end
    end

    # True iff the file's ENTIRE top-level is a MacroIf chain with no host-active
    # branch. Anything else (multiple top-level exprs, a non-MacroIf, an
    # unknown/true cond, a non-empty else) keeps it active. Unreadable / broken
    # files are active too (over-include rather than drop).
    private def host_inactive_file?(abs : String) : Bool
      text = begin
        File.read(abs)
      rescue
        return false
      end
      ast = begin
        ::Crystal::Parser.new(text).parse
      rescue ::Crystal::SyntaxException
        return false
      end

      nodes = case ast
              when ::Crystal::Expressions then ast.expressions
              else                             [ast]
              end
      return false unless nodes.size == 1
      node = nodes.first
      return false unless node.is_a?(::Crystal::MacroIf)
      macro_chain_inactive?(node)
    end

    private def macro_chain_inactive?(node : ::Crystal::MacroIf) : Bool
      cond_val = FlagEvaluator.evaluate(node.cond)
      return false unless cond_val == false
      case e = node.else
      when ::Crystal::MacroIf      then macro_chain_inactive?(e)
      when ::Crystal::Nop          then true
      when ::Crystal::MacroLiteral then e.value.strip.empty?
      when ::Crystal::Expressions
        e.expressions.all? do |c|
          case c
          when ::Crystal::Nop          then true
          when ::Crystal::MacroLiteral then c.value.strip.empty?
          else                              false
          end
        end
      else false
      end
    end

    private def walk_file(abs : String) : Nil
      return if @reachable.includes?(abs)
      return unless File.file?(abs)
      return if host_inactive_file?(abs)
      @reachable << abs

      text = begin
        File.read(abs)
      rescue
        return
      end
      ast = begin
        ::Crystal::Parser.new(text).parse
      rescue ::Crystal::SyntaxException
        return
      end

      requires = [] of String
      ast.accept(RequireWalker.new(requires))

      base_dir = File.dirname(abs)
      requires.each do |req|
        resolve(req, base_dir).each { |target| walk_file(target) }
      end
    end

    private def resolve(req : String, base_dir : String) : Array(String)
      if req.ends_with?("/*") || req.ends_with?("/**")
        return resolve_glob(req, base_dir)
      end
      if req.starts_with?("./") || req.starts_with?("../")
        path = resolve_relative(req, base_dir)
        return path ? [path] : [] of String
      end
      path = resolve_absolute(req)
      path ? [path] : [] of String
    end

    private def resolve_glob(req : String, base_dir : String) : Array(String)
      recursive = req.ends_with?("/**")
      stem = recursive ? req[0..-4] : req[0..-3]
      return [] of String unless stem.starts_with?("./") || stem.starts_with?("../")
      dir = File.expand_path(File.join(base_dir, stem))
      return [] of String unless Dir.exists?(dir)
      results = [] of String
      gather_cr_files(dir, results, recursive)
      results
    end

    private def gather_cr_files(dir : String, results : Array(String), recursive : Bool) : Nil
      Dir.each_child(dir) do |child|
        full = File.join(dir, child)
        if File.directory?(full)
          gather_cr_files(full, results, recursive) if recursive
        elsif child.ends_with?(".cr")
          results << File.expand_path(full)
        end
      end
    end

    private def resolve_relative(req : String, base_dir : String) : String?
      candidate = File.expand_path(File.join(base_dir, "#{req}.cr"))
      return candidate if File.file?(candidate)
      basename = File.basename(req)
      nested = File.expand_path(File.join(base_dir, req, "#{basename}.cr"))
      return nested if File.file?(nested)
      nil
    end

    private def resolve_absolute(req : String) : String?
      @crystal_path.each do |path|
        if found = try_path_expansions(req, path)
          return found
        end
      end
      nil
    end

    private def try_path_expansions(req : String, path : String) : String?
      shard_name, _, shard_path = req.partition('/')
      shard_path = shard_path.presence

      try = ->(candidate : String) {
        abs = File.expand_path(candidate)
        File.file?(abs) ? abs : nil
      }

      if hit = try.call(File.join(path, "#{req}.cr"))
        return hit
      end

      if shard_path
        shard_src = File.join(path, shard_name, "src")
        stem = shard_path.rchop(".cr")
        if hit = try.call(File.join(shard_src, "#{stem}.cr"))
          return hit
        end
        if hit = try.call(File.join(shard_src, shard_name, "#{stem}.cr"))
          return hit
        end
        basename = File.basename(req)
        if hit = try.call(File.join(path, req, "#{basename}.cr"))
          return hit
        end
        if hit = try.call(File.join(shard_src, shard_path, "#{stem}.cr"))
          return hit
        end
        if hit = try.call(File.join(shard_src, shard_name, shard_path, "#{stem}.cr"))
          return hit
        end
      else
        basename = File.basename(req)
        if hit = try.call(File.join(path, req, "#{basename}.cr"))
          return hit
        end
        if hit = try.call(File.join(path, req, "src", "#{basename}.cr"))
          return hit
        end
      end

      nil
    end

    # Collects top-level `Require` strings, honoring macro gates (walks only the
    # matching branch, both if unknown).
    private class RequireWalker < ::Crystal::Visitor
      def initialize(@requires : Array(String))
      end

      def visit(node : ::Crystal::Require) : Bool
        @requires << node.string
        false
      end

      def visit(node : ::Crystal::MacroIf) : Bool
        case FlagEvaluator.evaluate(node.cond)
        when true  then process_macro_body(node.then)
        when false then process_macro_body(node.else)
        when nil
          process_macro_body(node.then)
          process_macro_body(node.else)
        end
        false
      end

      # MacroIf branches arrive as raw MacroLiteral text; reconstruct + parse +
      # walk so nested requires come through. An `elsif` leaves a MacroIf in the
      # else slot — recurse via the visitor instead of reparsing.
      private def process_macro_body(body : ::Crystal::ASTNode) : Nil
        if body.is_a?(::Crystal::MacroIf)
          body.accept(self)
          return
        end
        text = String.build { |io| collect_macro_text(body, io) }
        return if text.strip.empty?
        inner = begin
          ::Crystal::Parser.new(text).parse
        rescue ::Crystal::SyntaxException
          return
        end
        inner.accept(self)
      end

      private def collect_macro_text(node : ::Crystal::ASTNode, io : IO) : Nil
        case node
        when ::Crystal::MacroLiteral then io << node.value
        when ::Crystal::Expressions  then node.expressions.each { |e| collect_macro_text(e, io) }
        when ::Crystal::Nop          then nil
        end
      end

      def visit(node : ::Crystal::ClassDef) : Bool
        false
      end

      def visit(node : ::Crystal::ModuleDef) : Bool
        false
      end

      def visit(node : ::Crystal::Def) : Bool
        false
      end

      def visit(node : ::Crystal::ASTNode) : Bool
        true
      end
    end
  end
end
