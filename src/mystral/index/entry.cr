module Mystral
  # A discovered declaration from parsing a `.cr` file. Named `Entry` rather
  # than `Symbol` so it doesn't shadow Crystal's built-in `Symbol` type inside
  # `module Mystral`. Locations are 0-indexed line/column (LSP convention).
  struct Entry
    getter name : String
    getter kind : String
    getter uri : String
    getter line : Int32
    getter column : Int32
    getter signature : String?
    getter doc : String?
    # Enclosing module/class/struct/enum scope, joined by `::`. nil for
    # top-level. e.g. `"Lune::Error"` for a method inside that class.
    getter container : String?
    # True for `def self.foo` (or `def Foo.bar`) — affects whether hover shows
    # the qualified name with `.` (class method) or `#` (instance).
    getter? class_method : Bool
    # 0-indexed line of the matching `end`. Captured for containers plus
    # defs/macros — used by scope walk-up ("which container encloses this
    # cursor?") and foldingRange. nil when the parser pinned no end_location.
    getter end_line : Int32?
    # "private" / "protected" for defs wrapped in the matching visibility
    # modifier; nil otherwise (public). On the Entry so callers (completion)
    # can filter without parsing the signature string.
    getter visibility : String?
    # Superclass for class symbols, as written at the def site (e.g. "Error"
    # or "Lune::Error"). Resolved against the enclosing scope at lookup time,
    # the way Crystal does. nil for non-classes / no explicit superclass.
    getter parent : String?
    # The declared type carried by this entry, captured from the AST at index
    # time so chain resolution doesn't re-parse `signature` per request. For
    # defs it's the `: T` return type; for ivar/cvar declarations the var's
    # annotated type; for getters synthesized from `getter foo : T` it's `T`.
    # nil when no type was declared (or the kind carries none).
    getter declared_type : String?
    # Annotations (`@[Foo]`, `@[Bar(x: 1)]`) lexically preceding this
    # declaration, in source order, each as its full `@[...]` text. Part of
    # the decorated thing's public API, so hover renders them above the
    # signature. Empty for undecorated symbols.
    getter annotations : Array(String)
    # Return type inferred PURELY from the AST when a def carries no explicit
    # `: T` and its body is a single literal — e.g. `def label; "boxed"; end`
    # -> "String". Conservative (single-literal bodies only), so never a lie.
    # nil when nothing safe could be inferred. Hover marks it as "inferred",
    # never folded into the signature (which would imply the user wrote it).
    getter inferred_return : String?
    # For a def whose entire body is a bare instance/class-var READ
    # (`def name; @name; end`) with no explicit return type: the variable's
    # name (sigil stripped). The type isn't knowable at index time (the ivar's
    # declared type may be parsed later, or live in an included module), so we
    # record the source var and resolve it against the indexed ivar/cvar at
    # hover time. Still never a lie — one leaf read, no branch/dispatch/macro.
    getter return_ivar : String?

    def initialize(@name, @kind, @uri, @line, @column, @signature = nil, @doc = nil,
                   @container = nil, @class_method = false, @end_line = nil,
                   @visibility = nil, @parent = nil, @declared_type = nil,
                   @annotations = [] of String, @inferred_return = nil, @return_ivar = nil)
    end
  end
end
