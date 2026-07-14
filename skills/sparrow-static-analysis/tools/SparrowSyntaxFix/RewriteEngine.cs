// SparrowSyntaxFix: deterministic Roslyn source rewriter for two Sparrow (파수 정적분석) checkers that
// `dotnet format` cannot autofix on the legacy OSTES (.NET Framework 4.7.2) project:
//   1) PRACTICE.OBVIOUS_VARIABLE_TYPE.NOT_USED_IMPLICIT_TYPING  ->  var x = (<Type>)null;
//   2) MISSING_PARENTHESIS_IN_EXPRESSION                        ->  parenthesize &&/|| operands
//
// RewriteEngine is the pure, IO-free core: parse source text with Roslyn syntax APIs, apply the enabled
// CSharpSyntaxRewriter(s), and return the round-tripped text + per-rule edit counts. Roslyn guarantees
// ToFullString() reproduces the source byte-for-byte when nothing matched, so an unmatched file reports
// as unchanged and is never rewritten. This is a syntax-level transform: never string/regex replacement.

using System;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;

namespace SparrowSyntaxFix
{
    // Which deterministic rewrite rules to apply.
    [Flags]
    internal enum SyntaxRule
    {
        None = 0,
        NullCast = 1 << 0,
        Parens = 1 << 1,
        All = NullCast | Parens,
    }

    // Result of a single-file rewrite: the new full text + per-rule edit counts + whether text changed.
    internal sealed class RewriteResult
    {
        public RewriteResult(string newText, int nullCastEdits, int parensEdits, bool changed)
        {
            NewText = newText;
            NullCastEdits = nullCastEdits;
            ParensEdits = parensEdits;
            Changed = changed;
        }

        public string NewText { get; }
        public int NullCastEdits { get; }
        public int ParensEdits { get; }
        public bool Changed { get; }
    }

    internal static class RewriteEngine
    {
        // Latest lang version parses a superset of the C# 7.x OSTES sources; we only read syntax, never compile.
        private static readonly CSharpParseOptions ParseOpts = new CSharpParseOptions(LanguageVersion.Latest);

        public static RewriteResult Rewrite(string source, SyntaxRule rules)
        {
            SyntaxNode root = CSharpSyntaxTree.ParseText(source, ParseOpts).GetRoot();
            SyntaxNode current = root;

            int nullCast = 0;
            int parens = 0;

            if ((rules & SyntaxRule.NullCast) != 0)
            {
                var rw = new NullCastRewriter();
                current = rw.Visit(current) ?? current;
                nullCast = rw.Count;
            }

            if ((rules & SyntaxRule.Parens) != 0)
            {
                var rw = new ParensRewriter();
                current = rw.Visit(current) ?? current;
                parens = rw.Count;
            }

            string newText = current.ToFullString();
            bool changed = !string.Equals(newText, source, StringComparison.Ordinal);
            return new RewriteResult(newText, nullCast, parens, changed);
        }
    }
}
