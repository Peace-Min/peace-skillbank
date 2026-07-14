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
            if (VarRewriteHelpers.IsVarType(visited.Type)) return visited;
            if (IsAlreadyCastOrOfType(visited.Expression)) return visited;
            if (!IsSafeXmlNodeListPattern(visited)) return visited;

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

        private static bool IsSafeXmlNodeListPattern(ForEachStatementSyntax node)
        {
            if (!VarRewriteHelpers.TypeMatchesAny(node.Type, "XmlNode", "System.Xml.XmlNode")) return false;
            if (HasUserDefinedXmlNodeNames(node)) return false;
            if (node.Expression is not IdentifierNameSyntax id) return false;
            string collectionName = id.Identifier.ValueText;
            BlockSyntax? block = node.Parent as BlockSyntax;
            if (block == null) return false;

            foreach (StatementSyntax statement in block.Statements)
            {
                if (statement.SpanStart >= node.SpanStart) break;
                if (statement is not LocalDeclarationStatementSyntax local) continue;
                if (!VarRewriteHelpers.TypeMatchesAny(local.Declaration.Type, "XmlNodeList", "System.Xml.XmlNodeList"))
                    continue;
                foreach (VariableDeclaratorSyntax variable in local.Declaration.Variables)
                {
                    if (variable.Identifier.ValueText == collectionName) return true;
                }
            }
            return false;
        }

        private static bool HasUserDefinedXmlNodeNames(SyntaxNode node)
        {
            SyntaxNode root = node.SyntaxTree.GetRoot();
            foreach (TypeDeclarationSyntax type in root.DescendantNodes().OfType<TypeDeclarationSyntax>())
            {
                string name = type.Identifier.ValueText;
                if (name == "XmlNode" || name == "XmlNodeList") return true;
            }
            return false;
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
