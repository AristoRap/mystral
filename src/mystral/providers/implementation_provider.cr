require "../server_context"
require "../resolve/text_scanner"
require "../resolve/type_resolver"
require "../lsp/types"
require "../lsp/entry_locations"

module Mystral
  # textDocument/implementation — from an abstraction, jump to its concrete
  # realizations: on a module/abstract method, the overriding defs in the types
  # that include/inherit it; on a type, its subtypes and includers.
  #
  # Parser-only: it resolves the symbol at the cursor through the shared
  # Resolver, then inverts the scope walker's lookup chain (which expands a type
  # into its supers + includes) to find every type that descends from the
  # target. Name+ancestry based, so it can over-list slightly — fine, the editor
  # shows a picker, exactly as for an ambiguous definition. Answers null when
  # nothing descends (allowed for navigation).
  class ImplementationProvider
    def initialize(@context : ServerContext)
    end

    def implementation(params : JSON::Any?) : Array(LSP::Location)?
      return nil unless params
      uri = params["textDocument"]["uri"].as_s
      pos = params["position"]
      line = pos["line"].as_i
      character = pos["character"].as_i

      text = @context.documents.text_for(uri)
      return nil unless text
      scanner = TextScanner.new(text)
      return nil if scanner.in_comment_or_string?(line, character)
      name = scanner.word_at(line, character)
      return nil unless name

      receiver = scanner.receiver_at(line, character)
      matches = @context.resolver.matches_at(name, uri, receiver, line)

      results = [] of ::Mystral::Entry
      matches.each do |m|
        if TypeResolver.type_kind?(m.kind)
          results.concat(subtypes_of(entry_fqn(m)))
        elsif m.kind == "def" && (container = m.container)
          results.concat(overrides_of(m.name, container))
        end
      end

      locations = results.uniq.map { |s| LSP::EntryLocations.name_range(s) }
      return nil if locations.empty?
      locations
    end

    # Defs named `method_name` declared on a type that descends from
    # `container` — the concrete overrides of an abstract/module method. The
    # declaration on `container` itself is the definition, not an implementation.
    private def overrides_of(method_name : String, container : String) : Array(::Mystral::Entry)
      @context.index.find_by_name(method_name).select do |s|
        next false unless s.kind == "def"
        c = s.container
        next false unless c
        c != container && descends_from?(c, container)
      end
    end

    # Every indexed type that descends from `target` (excluding `target`).
    private def subtypes_of(target : String) : Array(::Mystral::Entry)
      out = [] of ::Mystral::Entry
      @context.index.each_symbol do |s|
        next unless TypeResolver.container_kind?(s.kind)
        fqn = entry_fqn(s)
        out << s if fqn != target && descends_from?(fqn, target)
      end
      out
    end

    # Does `fqn`'s ancestry (superclasses + included/extended modules,
    # transitively) contain `target`? The scope walker's lookup chain already
    # computes that expansion — the first element is `fqn` itself, so a hit
    # anywhere after it means descent.
    private def descends_from?(fqn : String, target : String) : Bool
      @context.resolver.scope_walker.lookup_chain([fqn]).any? do |ancestor|
        ancestor == target && ancestor != fqn
      end
    end

    private def entry_fqn(s : ::Mystral::Entry) : String
      (c = s.container) ? "#{c}::#{s.name}" : s.name
    end
  end
end
