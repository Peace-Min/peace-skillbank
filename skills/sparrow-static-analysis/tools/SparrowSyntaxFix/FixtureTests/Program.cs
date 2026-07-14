// Fixture harness for SparrowSyntaxFix. Every case below is grounded in REAL Sparrow output (see the task
// brief / HANDOFF): the nullcast cases are actual `<Type> x = null;` findings; the parens cases are actual
// &&/|| conditions the MISSING_PARENTHESIS_IN_EXPRESSION checker flagged. Each case wraps the snippet in a
// method so it parses as a real LocalDeclarationStatement / if-condition, and asserts the FULL transformed
// text (which also proves nothing else in the file moved). Exit code: 0 = all pass, 1 = any failure.

using System;
using SparrowSyntaxFix;

namespace SparrowSyntaxFix.FixtureTests
{
    internal static class Program
    {
        private static int _passed;
        private static int _failed;

        private static int Main()
        {
            Console.WriteLine("SparrowSyntaxFix fixture harness");
            Console.WriteLine("================================");

            NullCastPositives();
            NullCastNegatives();
            ParensPositives();
            ParensNegatives();
            StringLiteralSafety();
            Idempotency();
            NewlinePreservation();

            Console.WriteLine("--------------------------------");
            Console.WriteLine("passed: " + _passed + "   failed: " + _failed);
            if (_failed > 0) { Console.WriteLine("RESULT: FAIL"); return 1; }
            Console.WriteLine("RESULT: PASS");
            return 0;
        }

        // --- wrappers so each snippet parses in a realistic context ---
        private static string Local(string stmt) =>
            "class C\n{\n    void M()\n    {\n        " + stmt + "\n    }\n}\n";

        private static string Cond(string expr) =>
            "class C\n{\n    void M()\n    {\n        if (" + expr + ")\n        {\n        }\n    }\n}\n";

        // ============================ Rule 1: nullcast ============================

        private static void NullCastPositives()
        {
            Console.WriteLine("[nullcast positive]");
            ExpectTransform("class type",
                Local("CComponentInfo clsComponentInfo = null;"),
                Local("var clsComponentInfo = (CComponentInfo)null;"),
                SyntaxRule.NullCast, expectNull: true, expectParens: false);

            ExpectTransform("sub-component type",
                Local("CSubComponentInfo clsSubComponentInfo = null;"),
                Local("var clsSubComponentInfo = (CSubComponentInfo)null;"),
                SyntaxRule.NullCast, true, false);

            ExpectTransform("generic List<PropData>",
                Local("List<PropData> lst = null;"),
                Local("var lst = (List<PropData>)null;"),
                SyntaxRule.NullCast, true, false);

            ExpectTransform("qualified name A.B.CThing",
                Local("A.B.CThing x = null;"),
                Local("var x = (A.B.CThing)null;"),
                SyntaxRule.NullCast, true, false);

            ExpectTransform("interface type (cast preserves it)",
                Local("IFoo c = null;"),
                Local("var c = (IFoo)null;"),
                SyntaxRule.NullCast, true, false);

            // Extra conservative cases (not in the brief's list but implied by "generics/qualified/arrays/nullable").
            ExpectTransform("nullable Foo?",
                Local("Foo? x = null;"),
                Local("var x = (Foo?)null;"),
                SyntaxRule.NullCast, true, false);

            ExpectTransform("array int[]",
                Local("int[] a = null;"),
                Local("var a = (int[])null;"),
                SyntaxRule.NullCast, true, false);
        }

        private static void NullCastNegatives()
        {
            Console.WriteLine("[nullcast negative — must stay byte-identical]");
            ExpectUnchanged("= new List<PropData>() (object creation)", Local("List<PropData> lst = new List<PropData>();"), SyntaxRule.All);
            ExpectUnchanged("= new Foo() (HARD rule: never touch)", Local("IFoo c = new Foo();"), SyntaxRule.All);
            ExpectUnchanged("= default", Local("CComponentInfo x = default;"), SyntaxRule.All);
            ExpectUnchanged("= default(T)", Local("CComponentInfo x = default(CComponentInfo);"), SyntaxRule.All);
            ExpectUnchanged("already var (invalid C#, must not crash/alter)", Local("var y = null;"), SyntaxRule.All);
            ExpectUnchanged("multi-declarator", Local("CComponentInfo a = null, b = null;"), SyntaxRule.All);
            ExpectUnchanged("non-null initializer", Local("int n = GetCount();"), SyntaxRule.All);
            ExpectUnchanged("const declaration", Local("const string s = null;"), SyntaxRule.All);
        }

        // ============================ Rule 2: parens ============================

        private static void ParensPositives()
        {
            Console.WriteLine("[parens positive]");
            ExpectTransform("relational group",
                Cond("nIndex > 0 && nIndex <= nCount - 1"),
                Cond("(nIndex > 0) && (nIndex <= nCount - 1)"),
                SyntaxRule.Parens, expectNull: false, expectParens: true);

            ExpectTransform("null-checks with &&",
                Cond("clsComponentInfo != null && clsDataTypeInfo != null"),
                Cond("(clsComponentInfo != null) && (clsDataTypeInfo != null)"),
                SyntaxRule.Parens, false, true);

            ExpectTransform("equality with ||",
                Cond("eNodeTag == ENodeTag.BSM || eNodeTag == ENodeTag.BSMPlayer"),
                Cond("(eNodeTag == ENodeTag.BSM) || (eNodeTag == ENodeTag.BSMPlayer)"),
                SyntaxRule.Parens, false, true);

            ExpectTransform("mixed &&/|| wraps only the && group",
                Cond("a || b && c"),
                Cond("a || (b && c)"),
                SyntaxRule.Parens, false, true);
        }

        private static void ParensNegatives()
        {
            Console.WriteLine("[parens negative — must stay byte-identical]");
            ExpectUnchanged("both operands are invocations",
                Cond("finfile.Name.Equals(\"x\") || finfile.Name.Equals(\"y\")"), SyntaxRule.All);
            ExpectUnchanged("already parenthesized (idempotent)",
                Cond("(a > 0) && (b < 1)"), SyntaxRule.All);
            ExpectUnchanged("identifiers only",
                Local("bool ok = a && b;"), SyntaxRule.All);
        }

        private static void StringLiteralSafety()
        {
            Console.WriteLine("[string/char literal safety]");
            // A string literal containing && / = null must be untouched (whole file byte-identical).
            ExpectUnchanged("string literal with && and = null inside",
                Local("string s = \"a && b = null\";"), SyntaxRule.All);

            // Real code around a string with && gets wrapped; the string's inner && is left alone.
            ExpectTransform("wrap real operands, not the && inside the string",
                Cond("a > 0 && msg == \"x && y\""),
                Cond("(a > 0) && (msg == \"x && y\")"),
                SyntaxRule.Parens, false, true);
        }

        // ============================ idempotency + newlines ============================

        private static void Idempotency()
        {
            Console.WriteLine("[idempotency — second run makes zero changes]");
            string[] inputs =
            {
                Local("CComponentInfo clsComponentInfo = null;"),
                Cond("nIndex > 0 && nIndex <= nCount - 1"),
                Cond("a || b && c"),
                Cond("a > 0 && msg == \"x && y\""),
            };
            foreach (string input in inputs)
            {
                RewriteResult first = RewriteEngine.Rewrite(input, SyntaxRule.All);
                RewriteResult second = RewriteEngine.Rewrite(first.NewText, SyntaxRule.All);
                bool ok = first.Changed
                          && !second.Changed
                          && second.NewText == first.NewText
                          && second.NullCastEdits == 0
                          && second.ParensEdits == 0;
                Report("idempotent: " + OneLine(input), ok, ok ? "" : "second run changed the text or reported edits");
            }
        }

        private static void NewlinePreservation()
        {
            Console.WriteLine("[CRLF preservation]");
            string crlf =
                "class C\r\n{\r\n    void M()\r\n    {\r\n" +
                "        CFoo x = null;\r\n" +
                "        if (a > 0 && b < 1)\r\n" +
                "        {\r\n        }\r\n    }\r\n}\r\n";

            RewriteResult r = RewriteEngine.Rewrite(crlf, SyntaxRule.All);
            bool ok = r.Changed
                      && r.NewText.Contains("var x = (CFoo)null;")
                      && r.NewText.Contains("(a > 0) && (b < 1)")
                      && r.NewText.Contains("\r\n")
                      && !HasLoneLf(r.NewText);
            Report("CRLF preserved through nullcast + parens edits", ok, ok ? "" : Escape(r.NewText));
        }

        private static bool HasLoneLf(string s)
        {
            for (int i = 0; i < s.Length; i++)
                if (s[i] == '\n' && (i == 0 || s[i - 1] != '\r')) return true;
            return false;
        }

        // ============================ assertion helpers ============================

        private static void ExpectTransform(string label, string input, string expected, SyntaxRule rules,
                                            bool expectNull, bool expectParens)
        {
            RewriteResult r = RewriteEngine.Rewrite(input, rules);
            bool textOk = r.NewText == expected;
            bool countOk = (r.NullCastEdits > 0) == expectNull && (r.ParensEdits > 0) == expectParens && r.Changed;
            Report(label, textOk && countOk, textOk ? "counts: nullcast=" + r.NullCastEdits + " parens=" + r.ParensEdits : Diff(expected, r.NewText));
        }

        private static void ExpectUnchanged(string label, string input, SyntaxRule rules)
        {
            RewriteResult r = RewriteEngine.Rewrite(input, rules);
            bool ok = !r.Changed && r.NewText == input && r.NullCastEdits == 0 && r.ParensEdits == 0;
            Report(label, ok, ok ? "" : "expected byte-identical; got: " + Escape(r.NewText));
        }

        private static void Report(string label, bool ok, string detail)
        {
            if (ok)
            {
                _passed++;
                Console.WriteLine("  [ok]   " + label);
            }
            else
            {
                _failed++;
                Console.WriteLine("  [FAIL] " + label);
                if (detail.Length > 0) Console.WriteLine("         " + detail.Replace("\n", "\n         "));
            }
        }

        private static string Diff(string expected, string actual) =>
            "expected: " + Escape(expected) + "\nactual:   " + Escape(actual);

        private static string Escape(string s) => s.Replace("\r", "\\r").Replace("\n", "\\n");

        private static string OneLine(string wrapped)
        {
            // Pull the inner statement/condition out of the wrapper for a compact idempotency label.
            string flat = wrapped.Replace("\n", " ").Replace("\r", " ");
            return flat.Length <= 60 ? flat.Trim() : flat.Substring(0, 60).Trim() + "...";
        }
    }
}
