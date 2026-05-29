require "../../spec_helper"

private URI = "file:///t.cr"

private def type_definition(src : String, line : Int32, char : Int32) : Array(Mystral::LSP::Location)?
  index = Mystral::Index.new
  docs = Mystral::Documents.new
  docs.set(URI, src)
  index.reindex(URI, src)
  context = Mystral::ServerContext.new(index, docs, IO::Memory.new, false)
  provider = Mystral::TypeDefinitionProvider.new(context)
  params = JSON.parse(%({"textDocument":{"uri":"#{URI}"},"position":{"line":#{line},"character":#{char}}}))
  provider.type_definition(params)
end

private def first_pos(locs) : {Int32, Int32}
  j = JSON.parse(locs.not_nil!.first.to_json)["range"]["start"]
  {j["line"].as_i, j["character"].as_i}
end

describe Mystral::TypeDefinitionProvider do
  it "jumps to the type of a local inferred from `.new`" do
    src = "class User\nend\nuser = User.new\nputs user"
    # cursor on `user` in `puts user` → type User, defined at the `class`
    # keyword on line 0 (definitions anchor on the keyword column).
    locs = type_definition(src, 3, 5)
    first_pos(locs).should eq({0, 0})
  end

  it "jumps to the type of a typed parameter" do
    src = "class User\nend\ndef greet(u : User)\n  u\nend"
    # cursor on `u` in the body → param type User.
    locs = type_definition(src, 3, 2)
    first_pos(locs).should eq({0, 0})
  end

  it "jumps to the declared type of an instance variable" do
    src = "class User\nend\nclass App\n  @user : User\n  def go\n    @user\n  end\nend"
    # cursor on `@user` read in the method body.
    locs = type_definition(src, 5, 5)
    first_pos(locs).should eq({0, 0})
  end

  it "returns nil when the value reference can't be typed" do
    type_definition("puts unknown_thing", 0, 8).should be_nil
  end

  it "returns nil when the inferred type isn't in the index (e.g. stdlib)" do
    # `n` infers to Int32, which isn't indexed here — no location, no crash.
    type_definition("n = 1\nputs n", 1, 5).should be_nil
  end

  it "returns nil on an empty line" do
    type_definition("class A\n\nend", 1, 0).should be_nil
  end
end
