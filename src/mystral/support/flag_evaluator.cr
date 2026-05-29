require "compiler/crystal/syntax"
require "./host_flags"

module Mystral
  # Three-valued evaluator for `{% if ... %}` macro-gate conditions, used by the
  # reachability walker to pick which branch of a gated require to follow.
  #   true  — definitely true on this host
  #   false — definitely false
  #   nil   — uses something we don't model (callers follow BOTH branches, so we
  #           never silently drop reachable code).
  # Supports `flag?(:sym)` / `flag?("sym")`, `&&`, `||`, `!`, bool literals.
  module FlagEvaluator
    extend self

    def evaluate(node : ::Crystal::ASTNode) : Bool?
      case node
      when ::Crystal::Call        then eval_call(node)
      when ::Crystal::And         then eval_and(node)
      when ::Crystal::Or          then eval_or(node)
      when ::Crystal::Not         then eval_not(node)
      when ::Crystal::BoolLiteral then node.value
      when ::Crystal::Expressions
        node.expressions.size == 1 ? evaluate(node.expressions.first) : nil
      else
        nil
      end
    end

    private def eval_call(node : ::Crystal::Call) : Bool?
      return nil unless node.obj.nil?
      return nil unless node.name == "flag?"
      return nil unless node.args.size == 1
      case arg = node.args.first
      when ::Crystal::SymbolLiteral then HostFlags.matches?(arg.value)
      when ::Crystal::StringLiteral then HostFlags.matches?(arg.value)
      else                               nil
      end
    end

    # Three-valued AND: false is absorbing; otherwise unknown propagates.
    private def eval_and(node : ::Crystal::And) : Bool?
      left = evaluate(node.left)
      return false if left == false
      right = evaluate(node.right)
      return false if right == false
      return true if left == true && right == true
      nil
    end

    # Three-valued OR: true is absorbing.
    private def eval_or(node : ::Crystal::Or) : Bool?
      left = evaluate(node.left)
      return true if left == true
      right = evaluate(node.right)
      return true if right == true
      return false if left == false && right == false
      nil
    end

    private def eval_not(node : ::Crystal::Not) : Bool?
      inner = evaluate(node.exp)
      inner.nil? ? nil : !inner
    end
  end
end
