require "compiler/crystal/syntax"
require "../server_context"
require "../lsp/types"

module Mystral
  # textDocument/foldingRange — AST-driven folding.
  #
  # The capability is intentionally NOT advertised in initialize_result.
  # VSCode's built-in indentation folder handles comments, heredocs, and
  # indent-based fallback this visitor doesn't model, and advertising would
  # REPLACE that with our (narrower) output — a net regression (e.g. an inline
  # def…rescue…end puts a phantom fold on a plain assignment). The handler
  # stays wired so the response is correct if a client asks anyway; flip the
  # capability on once the visitor is a strict superset of indentation folding.
  class FoldingRangeProvider
    def initialize(@context : ServerContext)
    end

    def folding_range(params : JSON::Any?) : Array(LSP::FoldingRange)
      empty = [] of LSP::FoldingRange
      return empty unless params
      uri = params["textDocument"]["uri"].as_s
      text = @context.documents.text_for(uri)
      return empty unless text

      ast = ::Crystal::Parser.new(text).parse
      folds = [] of LSP::FoldingRange
      ast.accept(FoldVisitor.new(folds))
      folds
    rescue ::Crystal::SyntaxException
      [] of LSP::FoldingRange
    end

    # One fold per "block-like" node spanning more than one line.
    private class FoldVisitor < ::Crystal::Visitor
      def initialize(@folds : Array(LSP::FoldingRange))
      end

      {% for kind in %w[ClassDef ModuleDef EnumDef LibDef CStructOrUnionDef
                         Def Macro Annotation
                         If Unless While Until Case ExceptionHandler
                         ArrayLiteral HashLiteral TupleLiteral NamedTupleLiteral
                         MacroIf MacroFor] %}
        def visit(node : ::Crystal::{{kind.id}}) : Bool
          emit(node)
          true
        end
      {% end %}

      # Any multi-line Call — covers `foo do |x| ... end` and wrapped arg
      # lists. The Block shares the Call's range, so we don't fold it twice.
      def visit(node : ::Crystal::Call) : Bool
        emit(node)
        true
      end

      def visit(node : ::Crystal::ASTNode) : Bool
        true
      end

      private def emit(node : ::Crystal::ASTNode) : Nil
        loc = node.location
        eloc = node.end_location
        return unless loc && eloc
        start_line = loc.line_number - 1
        end_line = eloc.line_number - 1
        return if end_line <= start_line
        @folds << LSP::FoldingRange.new(start_line: start_line, end_line: end_line)
      end
    end
  end
end
