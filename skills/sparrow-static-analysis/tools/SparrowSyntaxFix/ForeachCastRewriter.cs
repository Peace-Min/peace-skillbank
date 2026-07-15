using System.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace SparrowSyntaxFix
{
    // foreachcast: foreach (T x in expr) -> foreach (var x in System.Linq.Enumerable.Cast<T>(expr)).
    internal sealed class ForeachCastRewriter : CSharpSyntaxRewriter
    {
        public int Count { get; private set; }

        public override SyntaxNode? VisitForEachStatement(ForEachStatementSyntax node)
        {
            ForEachStatementSyntax visited = (ForEachStatementSyntax)base.VisitForEachStatement(node)!;
            // Skip when the loop already uses `var` (nothing to widen) or when the source is already a
            // Cast<T>(...) / OfType<T>(...) invocation (idempotent — a second pass must be a no-op).
            if (VarRewriteHelpers.IsVarType(visited.Type)) return visited;
            if (IsAlreadyCastOrOfType(visited.Expression)) return visited;
            if (visited.Expression == null) return visited;

            // Generalized beyond XmlNode: `foreach (T x in expr)` already casts EACH element to the explicit
            // type T per iteration, so `Enumerable.Cast<T>(expr)` is semantics-equivalent for ANY collection
            // expression (identifier, member access, invocation) whether the collection is generic
            // (List<T>) or non-generic (XmlNodeList, DataColumnCollection, UIElementCollection, ItemCollection).
            // Fully-qualified System.Linq.Enumerable.Cast needs no `using`. Remains review-needed + build-gated.
            TypeSyntax oldType = visited.Type;
            TypeSyntax varType = VarRewriteHelpers.VarLike(oldType);

            ExpressionSyntax castExpression = SyntaxFactory.InvocationExpression(
                    SyntaxFactory.MemberAccessExpression(
                        SyntaxKind.SimpleMemberAccessExpression,
                        SyntaxFactory.ParseName("System.Linq.Enumerable"),
                        SyntaxFactory.GenericName("Cast")
                            .WithTypeArgumentList(SyntaxFactory.TypeArgumentList(
                                SyntaxFactory.SingletonSeparatedList(oldType.WithoutTrivia())))))
                .WithArgumentList(SyntaxFactory.ArgumentList(
                    SyntaxFactory.SingletonSeparatedList(
                        SyntaxFactory.Argument(visited.Expression.WithoutTrivia()))))
                .WithLeadingTrivia(visited.Expression.GetLeadingTrivia())
                .WithTrailingTrivia(visited.Expression.GetTrailingTrivia());

            Count++;
            return visited.WithType(varType).WithExpression(castExpression);
        }

        private static bool IsAlreadyCastOrOfType(ExpressionSyntax expression)
        {
            if (expression is not InvocationExpressionSyntax invocation) return false;
            ExpressionSyntax invoked = invocation.Expression;
            if (invoked is MemberAccessExpressionSyntax member)
            {
                string name = member.Name switch
                {
                    GenericNameSyntax generic => generic.Identifier.ValueText,
                    IdentifierNameSyntax id => id.Identifier.ValueText,
                    _ => "",
                };
                return name == "Cast" || name == "OfType";
            }
            return false;
        }
    }
}
