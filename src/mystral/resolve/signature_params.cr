require "./text_scanner"

module Mystral
  # Pure parsing of a rendered def/macro signature string into its parameters.
  # No index, no cursor — just string structure. Shared by ReceiverResolver
  # (typing a param) and the hover provider (parameter hover), so both read
  # parameters the same way.
  module SignatureParams
    extend self

    # Iterate the top-level parameters of a signature, yielding each as a
    # `(start, finish)` substring range. "Top-level" = depth-1 inside the
    # outermost parens, so nested `Hash(K, V)` args, paren'd defaults, and
    # proc-arrow returns are stepped over. Yields nothing without a `(`.
    def each_top_level_param(signature : String, &block : Int32, Int32 ->) : Nil
      open = signature.index('(')
      return unless open
      depth = 1
      pos = open + 1
      start = pos
      while pos < signature.size
        case signature[pos]
        when '(', '[', '{'
          depth += 1
        when ')', ']', '}'
          depth -= 1
          if depth == 0
            yield start, pos
            return
          end
        when ','
          if depth == 1
            yield start, pos
            start = pos + 1
          end
        end
        pos += 1
      end
    end

    # The `name : Type [= default]` label for parameter `name` in a signature,
    # or nil when there's no such param / no arglist.
    def parameter_label_for(signature : String?, name : String) : String?
      return nil unless signature
      each_top_level_param(signature) do |start, finish|
        seg = signature[start...finish].strip
        return seg if param_label_matches?(seg, name)
      end
      nil
    end

    # Does `label` (one `name : T` / `@name : T` / `*name : T` segment) declare
    # a parameter called `name`? Strips leading splat / `&` / `@`/`@@` markers
    # before comparing the leading identifier.
    def param_label_matches?(label : String, name : String) : Bool
      head = label
      head = head[1..] if head.starts_with?('*') # *splat or **double_splat
      head = head[1..] if head.starts_with?('*')
      head = head[1..] if head.starts_with?('&') # &block
      head = head[2..] if head.starts_with?("@@")
      head = head[1..] if head.starts_with?('@')
      head = head.lstrip
      m = head.match(/\A([A-Za-z_][A-Za-z0-9_]*[!?=]?)/)
      !!(m && m[1] == name)
    end
  end
end
