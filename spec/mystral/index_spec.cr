require "../spec_helper"
require "file_utils"

private URI = "file:///t.cr"

private def symbols_for(src : String) : Array(Mystral::Entry)
  index = Mystral::Index.new
  index.reindex(URI, src)
  index.symbols_in(URI)
end

# First symbol matching name (+ optional kind).
private def sym(src : String, name : String, kind : String? = nil) : Mystral::Entry
  symbols_for(src).find { |s| s.name == name && (kind.nil? || s.kind == kind) }.not_nil!
end

describe Mystral::Index do
  describe "container / scope tracking" do
    it "nests symbols under their enclosing module::class" do
      defn = sym("module A\n  class B\n    def c\n    end\n  end\nend", "c")
      defn.container.should eq("A::B")
      defn.kind.should eq("def")
    end

    it "records a top-level symbol with no container" do
      sym("def free; end", "free").container.should be_nil
    end

    it "honors `class Foo::Bar` shorthand as a leaf under its leading segment" do
      leaf = sym("class IO::Memory\nend", "Memory", "class")
      leaf.container.should eq("IO")
    end

    it "pops the scope so following siblings are not mis-nested" do
      syms = symbols_for("class A\nend\ndef sibling; end")
      syms.find { |s| s.name == "sibling" }.not_nil!.container.should be_nil
    end
  end

  describe "classes / modules / structs" do
    it "indexes a class with its superclass as parent" do
      cls = sym("class Foo < Bar\nend", "Foo")
      cls.kind.should eq("class")
      cls.signature.should eq("class Foo < Bar")
      cls.parent.should eq("Bar")
    end

    it "indexes a struct via the `struct` keyword" do
      sym("struct Point\nend", "Point").kind.should eq("struct")
    end

    it "captures the end_line spanning the body" do
      sym("class Foo\n\nend", "Foo").end_line.should eq(2)
    end
  end

  describe "defs" do
    it "renders the full signature with declared return type" do
      d = sym("def greet(name : String) : String\nend", "greet")
      d.signature.should eq("def greet(name : String) : String")
      d.declared_type.should eq("String")
    end

    it "marks `def self.x` as a class method" do
      d = sym("class C\n  def self.make\n  end\nend", "make")
      d.class_method?.should be_true
      d.signature.should eq("def self.make()")
    end

    it "records a private def's visibility" do
      d = sym("private def helper\nend", "helper")
      d.visibility.should eq("private")
      d.signature.should eq("private def helper()")
    end

    it "infers a single-literal body's return type without lying" do
      sym("def label; \"boxed\"; end", "label").inferred_return.should eq("String")
      sym("def n; 7_i64; end", "n").inferred_return.should eq("Int64")
    end

    it "records a bare ivar-read body for hover-time resolution" do
      d = sym("class C\n  def name\n    @name\n  end\nend", "name")
      d.return_ivar.should eq("name")
    end
  end

  describe "constants / enums / aliases" do
    it "indexes a top-level constant with its assignment" do
      c = sym("FOO = 42", "FOO")
      c.kind.should eq("const")
      c.signature.should eq("FOO = 42")
    end

    it "renders an enum as a scannable block" do
      e = sym("enum Color\n  Red\n  Green\nend", "Color")
      e.kind.should eq("enum")
      e.signature.should eq("enum Color\n  Red\n  Green\nend")
    end

    it "indexes an alias" do
      a = sym("alias ID = Int32", "ID")
      a.kind.should eq("alias")
      a.signature.should eq("alias ID = Int32")
    end
  end

  describe "instance / class variables" do
    it "indexes a declared ivar with its type" do
      v = sym("class C\n  @count : Int32\nend", "count", "ivar")
      v.declared_type.should eq("Int32")
      v.signature.should eq("@count : Int32")
    end

    it "indexes a class var assignment, inferring the type from `X.new`" do
      v = sym("class C\n  @@conf = Config.new\nend", "conf", "cvar")
      v.declared_type.should eq("Config")
    end
  end

  describe "accessor macros" do
    it "synthesizes a reader def and a backing ivar for `getter`" do
      syms = symbols_for("class C\n  getter title : String\nend")
      reader = syms.find { |s| s.name == "title" && s.kind == "def" }.not_nil!
      reader.declared_type.should eq("String")
      reader.signature.should eq("def title : String")
      ivar = syms.find { |s| s.name == "title" && s.kind == "ivar" }.not_nil!
      ivar.declared_type.should eq("String")
    end

    it "synthesizes a setter for `property`" do
      syms = symbols_for("class C\n  property size : Int32\nend")
      syms.any? { |s| s.name == "size=" && s.kind == "def" }.should be_true
    end
  end

  describe "the `record` macro" do
    it "indexes the struct and a synthetic initialize" do
      syms = symbols_for("record Point, x : Int32, y : Int32")
      struct_sym = syms.find { |s| s.name == "Point" && s.kind == "struct" }.not_nil!
      struct_sym.signature.not_nil!.should contain("x : Int32")
      init = syms.find { |s| s.name == "initialize" }.not_nil!
      init.container.should eq("Point")
      init.signature.should eq("def initialize(x : Int32, y : Int32)")
    end
  end

  describe "lib bindings" do
    it "indexes a lib and its fun under the lib container" do
      syms = symbols_for("lib LibC\n  fun getpid : Int32\nend")
      syms.find { |s| s.name == "LibC" && s.kind == "lib" }.should_not be_nil
      fun_sym = syms.find { |s| s.name == "getpid" && s.kind == "fun" }.not_nil!
      fun_sym.container.should eq("LibC")
      fun_sym.signature.should eq("fun getpid() : Int32")
    end
  end

  describe "annotations" do
    it "attaches preceding annotations to the next symbol" do
      d = sym("@[MyAnno]\ndef decorated\nend", "decorated")
      d.annotations.should eq(["@[MyAnno]"])
    end

    it "leaves undecorated symbols with no annotations" do
      sym("def plain\nend", "plain").annotations.should be_empty
    end
  end

  describe "reindex resilience" do
    it "returns the SyntaxException and KEEPS prior symbols on a parse failure" do
      index = Mystral::Index.new
      index.reindex(URI, "def good\nend").should be_nil
      error = index.reindex(URI, "def oops(")
      error.should_not be_nil
      index.symbols_in(URI).map(&.name).should contain("good")
    end

    it "swaps symbols atomically on a successful reindex" do
      index = Mystral::Index.new
      index.reindex(URI, "def old_name; end")
      index.reindex(URI, "def new_name; end")
      names = index.symbols_in(URI).map(&.name)
      names.should contain("new_name")
      names.should_not contain("old_name")
    end

    it "keeps the name index in sync (find_by_name reflects the latest parse)" do
      index = Mystral::Index.new
      index.reindex(URI, "def old_name; end")
      index.reindex(URI, "def new_name; end")
      index.find_by_name("old_name").should be_empty
      index.find_by_name("new_name").size.should eq(1)
    end
  end

  describe "reachability filter" do
    it "is off when workspace_reachable is empty (returns all matches)" do
      index = Mystral::Index.new
      index.reindex("file:///a.cr", "struct File\n  def open\n  end\nend")
      index.reindex("file:///b.cr", "struct File\n  def open\n  end\nend")
      index.find_by_name("open").size.should eq(2)
    end

    it "prefers reachable matches per-container, with independent fallback (the LibC rule)" do
      index = Mystral::Index.new
      index.reindex("file:///a.cr", "struct File\n  def open\n  end\nend")  # File, reachable
      index.reindex("file:///b.cr", "struct File\n  def open\n  end\nend")  # File, NOT reachable
      index.reindex("file:///c.cr", "module LibC\n  def open\n  end\nend")  # LibC, NOT reachable
      index.workspace_reachable = Set{"/a.cr"}

      open = index.find_by_name("open")
      by_container = open.group_by(&.container)
      # File has a reachable match → the unreachable File#open is dropped.
      by_container["File"].map(&.uri).should eq(["file:///a.cr"])
      # LibC has NO reachable match → it falls back to keeping its own.
      by_container["LibC"].map(&.uri).should eq(["file:///c.cr"])
    end
  end

  describe "#scan_directory" do
    it "indexes every .cr under a directory" do
      dir = File.join(Dir.tempdir, "mystral_scan_#{Process.pid}_#{Time.utc.to_unix_ns}")
      Dir.mkdir_p(File.join(dir, "nested"))
      begin
        File.write(File.join(dir, "a.cr"), "class Alpha\nend")
        File.write(File.join(dir, "nested", "b.cr"), "class Beta\nend")
        index = Mystral::Index.new
        index.scan_directory(dir)
        names = [] of String
        index.each_symbol { |s| names << s.name }
        names.should contain("Alpha")
        names.should contain("Beta")
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "skips dependency/artifact dirs (lib, .git, …)" do
      dir = File.join(Dir.tempdir, "mystral_skip_#{Process.pid}_#{Time.utc.to_unix_ns}")
      Dir.mkdir_p(File.join(dir, "lib"))
      begin
        File.write(File.join(dir, "real.cr"), "class Real\nend")
        File.write(File.join(dir, "lib", "dep.cr"), "class Dep\nend")
        index = Mystral::Index.new
        index.scan_directory(dir)
        names = [] of String
        index.each_symbol { |s| names << s.name }
        names.should contain("Real")
        names.should_not contain("Dep")
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe "normalize_type_str (the IO? → IO | Nil rule)" do
    it "strips a leading absolute-path :: but keeps namespaced paths" do
      Mystral::SignatureRenderer.normalize_type_str("IO | ::Nil").should eq("IO | Nil")
      Mystral::SignatureRenderer.normalize_type_str("::String").should eq("String")
      Mystral::SignatureRenderer.normalize_type_str("Foo::Bar").should eq("Foo::Bar")
    end
  end
end
