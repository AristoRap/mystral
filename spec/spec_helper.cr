require "spec"
require "../src/mystral"

# Keep specs hermetic + fast: don't shell out to `crystal env CRYSTAL_PATH` and
# walk the whole system stdlib on every scan test. Tests that want stdlib
# resolution set CrystalPaths.cached themselves.
Mystral::CrystalPaths.cached = [] of String
