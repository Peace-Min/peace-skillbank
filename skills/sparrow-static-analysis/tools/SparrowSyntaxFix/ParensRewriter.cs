// Rule 2 (parens): for a logical &&/|| expression, wrap each operand in parentheses when the operand is
//   (a) a comparison/relational/equality binary expr:  <  >  <=  >=  ==  != , OR
//   (b) an arithmetic/shift/bitwise binary expr:        +  -  *  /  %  <<  >>  >>>  &  |  ^ , OR
//   (c) a logical binary expr of the OTHER operator (an `&&` operand under `||`, or vice versa),
// UNLESS the operand is already a ParenthesizedExpression.
//
// Atomic operands (identifiers, literals, member access `a.b.c`, invocations `f()`, element access,
// `this`, unary `!x`/`-x`, casts) are left alone: they are not what MISSING_PARENTHESIS_IN_EXPRESSION
// targets, and wrapping a complete subexpression in parens is always semantics-preserving anyway.
// Idempotent: an already-`(a > 0)` operand is a ParenthesizedExpression and is never re-wrapped.

using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace SparrowSyntaxFix
{
    internal sealed class ParensRewriter : CSharpSyntaxRewriter
    {
        public int Count { get; private set; }

        public override SyntaxNode? VisitBinaryExpression(BinaryExpressionSyntax node)
        {
            // Recurse first so nested &&/|| operands are processed before we wrap at this level.
            var visited = (BinaryExpressionSyntax)base.VisitBinaryExpression(node)!;

            SyntaxKind parentKind = node.Kind();
            if (parentKind != SyntaxKind.LogicalAndExpression && parentKind != SyntaxKind.LogicalOrExpression)
                return visited;

            ExpressionSyntax newLeft = visited.Left;
            ExpressionSyntax newRight = visited.Right;

            if (ShouldWrap(visited.Left, parentKind)) { newLeft = Wrap(visited.Left); Count++; }
            if (ShouldWrap(visited.Right, parentKind)) { newRight = Wrap(visited.Right); Count++; }

            if (newLeft != visited.Left || newRight != visited.Right)
                return visited.WithLeft(newLeft).WithRight(newRight);
            return visited;
        }

        // The inserted `(` takes the operand's leading trivia and `)` its trailing trivia, so surrounding
        // whitespace/newlines (multi-line conditions) are preserved; the operand's inner trivia is kept.
        private static ExpressionSyntax Wrap(ExpressionSyntax operand) =>
            SyntaxFactory.ParenthesizedExpression(operand.WithoutTrivia())
                .WithLeadingTrivia(operand.GetLeadingTrivia())
                .WithTrailingTrivia(operand.GetTrailingTrivia());

        private static bool ShouldWrap(ExpressionSyntax operand, SyntaxKind parentKind)
        {
            if (operand is ParenthesizedExpressionSyntax) return false;   // already parenthesized
            if (operand is not BinaryExpressionSyntax bin) return false;  // atomic w.r.t. precedence -> skip

            SyntaxKind k = bin.Kind();
            if (IsComparison(k) || IsArithmeticOrBitwise(k)) return true;

            // (c) a logical binary expr of the OTHER operator.
            if (parentKind == SyntaxKind.LogicalAndExpression && k == SyntaxKind.LogicalOrExpression) return true;
            if (parentKind == SyntaxKind.LogicalOrExpression && k == SyntaxKind.LogicalAndExpression) return true;

            // Same-operator chains (a && b && c) are associative -> no redundant parens. Other binary kinds
            // (?? / is / as) are out of this checker's scope -> left alone.
            return false;
        }

        private static bool IsComparison(SyntaxKind k) =>
            k == SyntaxKind.LessThanExpression ||
            k == SyntaxKind.GreaterThanExpression ||
            k == SyntaxKind.LessThanOrEqualExpression ||
            k == SyntaxKind.GreaterThanOrEqualExpression ||
            k == SyntaxKind.EqualsExpression ||
            k == SyntaxKind.NotEqualsExpression;

        private static bool IsArithmeticOrBitwise(SyntaxKind k) =>
            k == SyntaxKind.AddExpression ||
            k == SyntaxKind.SubtractExpression ||
            k == SyntaxKind.MultiplyExpression ||
            k == SyntaxKind.DivideExpression ||
            k == SyntaxKind.ModuloExpression ||
            k == SyntaxKind.LeftShiftExpression ||
            k == SyntaxKind.RightShiftExpression ||
            k == SyntaxKind.UnsignedRightShiftExpression ||
            k == SyntaxKind.BitwiseAndExpression ||
            k == SyntaxKind.BitwiseOrExpression ||
            k == SyntaxKind.ExclusiveOrExpression;
    }
}
