// SparrowCommentFix: deterministic CLI that fixes COMMENT-TRIVIA-ONLY style issues flagged by the Sparrow
// (파수) static analyzer, WITHOUT loading any project. It operates on .cs TEXT files directly, so legacy
// non-SDK .csproj / .NET Framework 4.7.2 targets are irrelevant. Purpose: take the deterministic comment
// clean-ups out of a weak local LLM's hands in an air-gapped environment (Track B of the pipeline).
//
// SCOPE = ACTIVE COMMENT + LAYOUT RULES (validated against the REAL Sparrow output,
// issues_OSTES_6827.xls / 6855.xls, plus the checker descriptions):
//   flatten  (Doxygen/block comment -> line comments for simple @brief/@param/@returns blocks)
//   trailing (inline `code; //comment` -> preceding normalized line comment)
//   space    (FORMATTING.COMMENT.MISSING_SPACE_AFTER_DELIMITER, "//와 주석 사이 공백")
//   period   (FORMATTING.COMMENT.MISSING_PERIOD, "주석 문장 끝 종결부호")
//   capitalize (FORMATTING.COMMENT.LOWERCASE_FIRST_LETTER, "주석 첫 글자 대문자")
//   memberblank / onedeclaration / onestatement / linqalign / continuation
//
// TWO RULES ARE INTENTIONALLY NOT ACTIVE (removed/deferred per that same real-data analysis). This is the
// "code-fix-only" decision: deterministically-unfixable items are simply left unhandled rather than mis-edited.
//   capitalize (FORMATTING.COMMENT.LOWERCASE_FIRST_LETTER) -- ACTIVE. A comment's text must start with an
//               UPPERCASE letter. Real findings start with a special char (`<` XML markup, `.`, `[`, `(`) or an
//               ASCII lowercase letter in PLAIN `//` line and `/* */` block comments. Contract: skip the standard
//               single space, strip ONLY leading punctuation/symbol chars (stop at the first letter/digit; abort
//               if whitespace or region end is reached first), then uppercase an ASCII a-z first letter. HARD
//               GUARDS: `///` doc comments and `/**` Doxygen blocks are skipped; Korean/CJK (non-ASCII) leading
//               letters are never stripped or "uppercased" (Hangul has no case); `/* */` is edited in place and
//               NEVER converted to `//` (that would comment out trailing code). Idempotent.
//   blankline  (MISSING_BLANK_LINE_BEFORE_COMMENT) -- REMOVED. The real rule flags TRAILING/inline comments
//               (`code; //c`) and wants them on their OWN line; the old implementation instead inserted a blank
//               line before comments that already began a line -- the opposite target. Re-targeting is a risky
//               structural rewrite for only ~10 real hits, so it was pulled rather than shipped wrong.
//   asterisk   (FORMATTING.COMMENT.BLOCK_OF_ASTERISK) -- DEFERRED. Removing Doxygen `/** * */` blocks is a style
//               judgment, not a safe mechanical edit.
// Each can be re-added later as a SMALL DIFF (one rule key + one rewrite method) once a correct, real-data-backed
// contract is defined -- the clean rule-registry architecture below is preserved for exactly that.
//
// Design points baked in:
//  - ROSLYN, NOT REGEX. Each file is parsed with CSharpSyntaxTree.ParseText and edits are confined to spans
//    that Roslyn identifies as comment trivia. CORRECTNESS GUARANTEE: a `//` or `/*` inside a string or char
//    literal is a StringLiteral/CharacterLiteral token, never a comment trivia, so it is NEVER edited. This
//    guarantee is non-negotiable and is covered by the SAFETY fixtures.
//  - Parse with DocumentationMode.None so `///` doc comments are lexed as ordinary SingleLineCommentTrivia
//    (text `///...`) and `/**...*/` as ordinary MultiLineCommentTrivia. That keeps every rule a simple,
//    total text transform on the comment's delimiter+content -- no structured-XML trivia to reason about.
//  - CLEAN RULE REGISTRY (AllRuleKeys + per-comment/layout dispatch): active rules each slot in by key.
//    blankline / asterisk are intentionally not active (see SCOPE above);
//    passing either of them -- or an unknown key -- exits 2 with a message naming the valid keys and the reason.
//  - TEXT rules are comment-trivia rewrites; layout rules are narrow span rewrites with parse/overlap guards.
//  - Every rule is IDEMPOTENT: a second run is a no-op (verified by fixtures).
//  - PER-CHECKER COMMITS: run ONE rule at a time (e.g. `--rules period`) so that run's diff == that one
//    Sparrow checker's fixes, matching the "규칙/체커별 커밋" gate.
//  - Encoding/newline preservation: each edited file keeps its original UTF-8-BOM-presence and its existing
//    newlines. Files whose bytes do not round-trip as UTF-8 are skipped with a WARN (never risk corrupting
//    non-UTF-8 bytes). Writes are atomic (temp file in the same directory, then replace) and only happen when
//    the bytes actually change.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace SparrowCommentFix
{
    internal static class Program
    {
        // Canonical order the active text rules are applied in (selection order is irrelevant; application is fixed).
        private static readonly string[] AllRuleKeys =
        {
            "flatten", "trailing", "space", "period", "capitalize",
            "memberblank", "onestatement", "onedeclaration", "continuation", "linqalign"
        };

        private static int Main(string[] args)
        {
            try { Console.OutputEncoding = new UTF8Encoding(false); } catch { /* stdout may be redirected */ }

            var positional = new List<string>();
            string? filesFrom = null;
            string? root = null;
            string? rulesArg = null;
            bool dryRun = false;
            bool includeGenerated = false;

            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i];
                switch (a)
                {
                    case "--files-from": if (!TryNext(args, ref i, out filesFrom)) return Usage("--files-from requires a value"); break;
                    case "--root": if (!TryNext(args, ref i, out root)) return Usage("--root requires a value"); break;
                    case "--rules": if (!TryNext(args, ref i, out rulesArg)) return Usage("--rules requires a value"); break;
                    case "--dry-run": dryRun = true; break;
                    case "--include-generated": includeGenerated = true; break;
                    default:
                        if (a.StartsWith("--", StringComparison.Ordinal)) return Usage("unknown option: " + a);
                        positional.Add(a);
                        break;
                }
            }

            if (rulesArg == null) return Usage("--rules is required");

            var enabled = new HashSet<string>(StringComparer.Ordinal);
            foreach (string tokenRaw in rulesArg.Split(','))
            {
                string token = tokenRaw.Trim();
                if (token.Length == 0) continue;
                if (string.Equals(token, "all", StringComparison.Ordinal))
                {
                    foreach (string k in AllRuleKeys) enabled.Add(k);
                    continue;
                }
                if (Array.IndexOf(AllRuleKeys, token) >= 0) { enabled.Add(token); continue; }
                return Usage(InvalidRuleMessage(token));
            }
            if (enabled.Count == 0) return Usage("--rules selected no rules");

            try
            {
                return Run(positional, filesFrom, root, enabled, dryRun, includeGenerated);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("error: " + ex.Message);
                return 1;   // runtime error: IO failure / unreadable index / etc.
            }
        }

        private static int Run(List<string> positional, string? filesFrom, string? root,
                               HashSet<string> enabled, bool dryRun, bool includeGenerated)
        {
            string rootDir = Path.GetFullPath(root ?? Directory.GetCurrentDirectory());

            // Union positional files + --files-from files, de-duplicated by full path (Ordinal), order-stable.
            var ordered = new List<string>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            void Add(string p)
            {
                string full = Path.IsPathRooted(p) ? Path.GetFullPath(p) : Path.GetFullPath(Path.Combine(rootDir, p));
                if (seen.Add(full)) ordered.Add(full);
            }
            foreach (string p in positional) Add(p);
            if (filesFrom != null)
            {
                foreach (string p in ReadFilesFrom(filesFrom)) Add(p);
            }

            if (ordered.Count == 0) return Usage("no input files (pass .cs paths and/or --files-from)");

            // Keep only files that exist on disk; a missing one is a WARN + skip, not a fatal error.
            var targets = new List<string>();
            foreach (string full in ordered)
            {
                if (File.Exists(full)) targets.Add(full);
                else Console.Error.WriteLine("WARN: input file not found, skipping: " + full);
            }
            if (targets.Count == 0) return Usage("no valid input files found on disk");

            var ruleCounts = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (string k in AllRuleKeys) ruleCounts[k] = 0;

            int scanned = 0, changed = 0, skippedNonUtf8 = 0;
            foreach (string full in targets)
            {
                scanned++;
                FileResult r = ProcessFile(full, enabled, dryRun, includeGenerated);
                if (r.SkippedNonUtf8) { skippedNonUtf8++; Console.Error.WriteLine("WARN: not lossless UTF-8, skipping: " + full); continue; }
                if (r.Changed) changed++;
                foreach (var kv in r.RuleCounts) ruleCounts[kv.Key] += kv.Value;
            }

            int total = AllRuleKeys.Where(enabled.Contains).Sum(k => ruleCounts[k]);

            Console.WriteLine("root:            " + rootDir);
            Console.WriteLine("rules:           " + string.Join(",", AllRuleKeys.Where(enabled.Contains)));
            Console.WriteLine("files scanned:   " + scanned.ToString(CultureInfo.InvariantCulture));
            Console.WriteLine("files changed:   " + changed.ToString(CultureInfo.InvariantCulture));
            foreach (string k in AllRuleKeys)
            {
                if (!enabled.Contains(k)) continue;
                Console.WriteLine(("rule " + k + ":").PadRight(17) + ruleCounts[k].ToString(CultureInfo.InvariantCulture));
            }
            Console.WriteLine("total changes:   " + total.ToString(CultureInfo.InvariantCulture));
            if (skippedNonUtf8 > 0) Console.WriteLine("skipped (non-UTF-8): " + skippedNonUtf8.ToString(CultureInfo.InvariantCulture));
            Console.WriteLine("dry-run:         " + (dryRun ? "true" : "false"));
            return 0;
        }

        // ---------------------------------------------------------------------------------------------------
        // Per-file processing
        // ---------------------------------------------------------------------------------------------------

        private sealed class FileResult
        {
            public bool Changed;
            public bool SkippedNonUtf8;
            public Dictionary<string, int> RuleCounts = new(StringComparer.Ordinal);
        }

        private static FileResult ProcessFile(string fullPath, HashSet<string> enabled, bool dryRun, bool includeGenerated)
        {
            var result = new FileResult();
            foreach (string k in AllRuleKeys) result.RuleCounts[k] = 0;
            if (!includeGenerated && IsGeneratedOrBackupPath(fullPath)) return result;

            byte[] raw = File.ReadAllBytes(fullPath);
            bool hasBom = raw.Length >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF;
            int contentOffset = hasBom ? 3 : 0;
            int contentLength = raw.Length - contentOffset;

            var enc = new UTF8Encoding(false, false);   // no BOM, no throw on decode
            string text = enc.GetString(raw, contentOffset, contentLength);
            if (!includeGenerated && HasAutoGeneratedHeader(text)) return result;

            // Round-trip guard: if the bytes are not valid/lossless UTF-8, refuse to rewrite (we could
            // corrupt bytes outside the comment regions on re-encode). Skip with a WARN.
            byte[] reencoded = enc.GetBytes(text);
            if (reencoded.Length != contentLength) { result.SkippedNonUtf8 = true; return result; }
            for (int i = 0; i < contentLength; i++)
            {
                if (reencoded[i] != raw[contentOffset + i]) { result.SkippedNonUtf8 = true; return result; }
            }

            string newText = ComputeNewText(text, enabled, result.RuleCounts);
            if (string.Equals(newText, text, StringComparison.Ordinal)) return result;   // no change

            result.Changed = true;
            if (dryRun) return result;

            byte[] outContent = enc.GetBytes(newText);
            byte[] outBytes = hasBom ? Prepend(new byte[] { 0xEF, 0xBB, 0xBF }, outContent) : outContent;
            AtomicWrite(fullPath, outBytes);
            return result;
        }

        // Parse, collect edits from the enabled rules, and splice them into the source text.
        private static string ComputeNewText(string text, HashSet<string> enabled, Dictionary<string, int> ruleCounts)
        {
            var parseOptions = new CSharpParseOptions(languageVersion: LanguageVersion.Latest,
                                                      documentationMode: DocumentationMode.None);
            SyntaxTree tree = CSharpSyntaxTree.ParseText(text, parseOptions);
            int oldErrorCount = tree.GetDiagnostics().Count(d => d.Severity == DiagnosticSeverity.Error);
            if (oldErrorCount > 0) return text;
            SyntaxNode root = tree.GetRoot();

            var comments = root.DescendantTrivia().Where(t => IsComment(t.Kind())).ToList();

            var edits = new List<Edit>();
            var stagedCounts = new Dictionary<string, int>(ruleCounts, StringComparer.Ordinal);

            foreach (SyntaxTrivia t in comments)
            {
                string original = t.ToFullString();
                string cur = original;
                if (IsProtectedCommentTrivia(cur)) continue;

                if (enabled.Contains("flatten") && IsBlock(cur) && TryFlattenBlockComment(text, t, cur, out string flat))
                {
                    stagedCounts["flatten"]++;
                    edits.Add(new Edit(t.SpanStart, t.Span.Length, flat));
                    continue;
                }

                if (enabled.Contains("trailing") && IsSingleLine(cur) && TryMoveTrailingComment(text, t, cur, out Edit trailingEdit))
                {
                    stagedCounts["trailing"]++;
                    edits.Add(trailingEdit);
                    continue;
                }

                if (enabled.Contains("space"))
                {
                    string next = RewriteSpace(cur);
                    if (!string.Equals(next, cur, StringComparison.Ordinal)) { stagedCounts["space"]++; cur = next; }
                }
                if (enabled.Contains("period"))
                {
                    string next = RewritePeriod(cur);
                    if (!string.Equals(next, cur, StringComparison.Ordinal)) { stagedCounts["period"]++; cur = next; }
                }
                if (enabled.Contains("capitalize"))
                {
                    string next = RewriteCapitalize(cur);
                    if (!string.Equals(next, cur, StringComparison.Ordinal)) { stagedCounts["capitalize"]++; cur = next; }
                }

                if (!string.Equals(cur, original, StringComparison.Ordinal))
                    edits.Add(new Edit(t.SpanStart, t.Span.Length, cur));
            }

            string current = text;
            if (edits.Count > 0)
            {
                if (HasOverlappingEdits(edits)) return text;
                string rewritten = ApplyEdits(text, edits);
                SyntaxTree newTree = CSharpSyntaxTree.ParseText(rewritten, parseOptions);
                if (newTree.GetDiagnostics().Count(d => d.Severity == DiagnosticSeverity.Error) <= oldErrorCount)
                {
                    foreach (var kv in stagedCounts) ruleCounts[kv.Key] = kv.Value;
                    current = rewritten;
                }
            }

            foreach (string rule in new[] { "onedeclaration", "onestatement", "memberblank", "linqalign", "continuation" })
            {
                if (enabled.Contains(rule))
                    current = ApplyLayoutRule(current, parseOptions, rule, ruleCounts);
            }
            return current;
        }

        private static string ApplyLayoutRule(string text, CSharpParseOptions parseOptions, string rule, Dictionary<string, int> ruleCounts)
        {
            SyntaxTree tree = CSharpSyntaxTree.ParseText(text, parseOptions);
            int oldErrorCount = tree.GetDiagnostics().Count(d => d.Severity == DiagnosticSeverity.Error);
            if (oldErrorCount > 0) return text;
            SyntaxNode root = tree.GetRoot();
            var edits = new List<Edit>();
            var stagedCounts = new Dictionary<string, int>(ruleCounts, StringComparer.Ordinal);

            switch (rule)
            {
                case "memberblank": AddMemberBlankLineEdits(text, root, edits, stagedCounts); break;
                case "onestatement": AddOneStatementPerLineEdits(text, root, edits, stagedCounts); break;
                case "onedeclaration": AddOneDeclarationPerLineEdits(text, root, edits, stagedCounts); break;
                case "continuation": AddContinuationIndentEdits(text, root, edits, stagedCounts); break;
                case "linqalign": AddLinqAlignmentEdits(text, root, edits, stagedCounts); break;
            }
            if (edits.Count == 0) return text;

            if (HasOverlappingEdits(edits)) return text;
            string rewritten = ApplyEdits(text, edits);
            SyntaxTree newTree = CSharpSyntaxTree.ParseText(rewritten, parseOptions);
            if (newTree.GetDiagnostics().Count(d => d.Severity == DiagnosticSeverity.Error) > oldErrorCount)
                return text;
            foreach (var kv in stagedCounts) ruleCounts[kv.Key] = kv.Value;
            return rewritten;
        }

        // ---------------------------------------------------------------------------------------------------
        // Text rules
        // ---------------------------------------------------------------------------------------------------

        // FORMATTING.COMMENT.BLOCK_OF_ASTERISK + LOWERCASE_FIRST_LETTER + MISSING_PERIOD:
        // Doxygen/block comments are flattened line-by-line into ordinary `// ...` comments.
        private static bool TryFlattenBlockComment(string source, SyntaxTrivia trivia, string text, out string replacement)
        {
            replacement = "";
            if (!IsBlock(text)) return false;
            if (!IsStandaloneTriviaLine(source, trivia.SpanStart, trivia.Span.End)) return false;

            string nl = DetectNewline(text);
            string indent = IndentBefore(source, trivia.SpanStart);
            string inner = text.Substring(2, text.Length - 4);
            string normalized = inner.Replace("\r\n", "\n").Replace("\r", "\n");
            var output = new List<string>();

            foreach (string rawLine in normalized.Split('\n'))
            {
                string line = rawLine.Trim();
                while (line.StartsWith("*", StringComparison.Ordinal)) line = line.Substring(1).TrimStart();
                if (line.StartsWith("@", StringComparison.Ordinal) && !IsAllowedDoxygenLine(line)) return false;
                if (line.StartsWith("\\", StringComparison.Ordinal)) return false;
                if (line.IndexOf("@", StringComparison.Ordinal) > 0) return false;
                line = NormalizeCommentContent(line);
                if (line.Length == 0) continue;
                output.Add("// " + line);
            }

            if (output.Count == 0) return false;
            replacement = string.Join(nl + indent, output);
            return !string.Equals(replacement, text, StringComparison.Ordinal);
        }

        // MISSING_BLANK_LINE_BEFORE_COMMENT real target: move trailing comments to their own line above code,
        // while also normalizing delimiter spacing, first letter, and terminal punctuation.
        private static bool TryMoveTrailingComment(string source, SyntaxTrivia trivia, string text, out Edit edit)
        {
            edit = default;
            int lineStart = LineStart(source, trivia.SpanStart);
            string before = source.Substring(lineStart, trivia.SpanStart - lineStart);
            if (before.Trim().Length == 0) return false;
            if (before.TrimStart().StartsWith("//", StringComparison.Ordinal)) return false;
            if (!before.TrimEnd().EndsWith(";", StringComparison.Ordinal)) return false;
            if (text.IndexOf("suppress", StringComparison.OrdinalIgnoreCase) >= 0
                || text.IndexOf("NOSONAR", StringComparison.OrdinalIgnoreCase) >= 0
                || text.IndexOf("ReSharper", StringComparison.OrdinalIgnoreCase) >= 0
                || text.IndexOf("NOLINT", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return false;
            }

            string content = NormalizeCommentContent(text.Substring(SlashRun(text)));
            if (content.Length == 0) return false;

            string indent = LeadingWhitespace(before);
            string code = before.TrimEnd();
            string nl = NewlineAtOrDefault(source, trivia.Span.End);
            string replacement = indent + "// " + content + nl + code;
            edit = new Edit(lineStart, trivia.Span.End - lineStart, replacement);
            return true;
        }

        // FORMATTING.COMMENT.MISSING_SPACE_AFTER_DELIMITER: `//x`->`// x`, `///x`->`/// x`, `/*x*/`->`/* x*/`.
        private static string RewriteSpace(string text)
        {
            if (IsSingleLine(text))
            {
                int s = SlashRun(text);
                if (s < text.Length)
                {
                    char c = text[s];
                    if (!char.IsWhiteSpace(c) && c != '/')
                        return text.Substring(0, s) + " " + text.Substring(s);
                }
                return text;
            }
            if (IsBlock(text) && text.Length > 4)   // > 4 so inner (text[2..len-2]) is non-empty
            {
                char c = text[2];
                if (!char.IsWhiteSpace(c) && c != '*')
                    return text.Substring(0, 2) + " " + text.Substring(2);
                return text;
            }
            return text;
        }

        // FORMATTING.COMMENT.MISSING_PERIOD: append `.` when the last content char is a letter/digit.
        private static string RewritePeriod(string text)
        {
            if (IsSingleLine(text)) return PeriodAt(text, SlashRun(text), text.Length);
            if (IsBlock(text)) return PeriodAt(text, 2, text.Length - 2);
            return text;
        }

        // FORMATTING.COMMENT.LOWERCASE_FIRST_LETTER: a comment's text should start with an UPPERCASE letter.
        // Strip ONLY leading punctuation/symbol chars (`<`, `.`, `[`, `(`, `-`, `=`, ...) then uppercase an ASCII
        // a-z first letter. HARD GUARDS: `///` doc comments and `/**` Doxygen blocks are skipped (functional/
        // flatten's domain); the `/* */` block is edited IN PLACE, never converted to `//`. See CapitalizeInRegion.
        private static string RewriteCapitalize(string text)
        {
            if (IsSingleLine(text))
            {
                // Only PLAIN `//` line comments. `///` (doc) and `////`+ (dividers) are left byte-identical.
                if (SlashRun(text) != 2) return text;
                return CapitalizeInRegion(text, 2, text.Length);
            }
            if (IsBlock(text))
            {
                // `/**...*/` Doxygen/XML doc block comments are flatten's domain -> skip.
                if (text.StartsWith("/**", StringComparison.Ordinal)) return text;
                // Region excludes the closing `*/`, so stripping/uppercasing never touches the delimiter and the
                // comment stays a block comment (never converted to `//`).
                return CapitalizeInRegion(text, 2, text.Length - 2);
            }
            return text;
        }

        // Within the comment content region [regionStart, regionEnd) (right after the opening delimiter, up to but
        // excluding any closing delimiter): skip the leading standard single space, strip a CONTIGUOUS run of
        // leading punctuation/symbol chars, and uppercase the first ASCII lowercase letter. Returns the input
        // unchanged (byte-identical) when nothing qualifies -- guaranteeing idempotency and the hard guards.
        private static string CapitalizeInRegion(string text, int regionStart, int regionEnd)
        {
            if (regionStart < 0 || regionEnd > text.Length || regionStart >= regionEnd) return text;

            // Skip leading whitespace (the standard single space after the delimiter, plus any incidental ws).
            int i = regionStart;
            while (i < regionEnd && (text[i] == ' ' || text[i] == '\t')) i++;

            // Strip ONLY leading punctuation/symbols. Stop at the first letter (ASCII or Unicode/Korean) or digit.
            // If whitespace or the region end is reached before any letter/digit, the leading symbols form a
            // standalone token (e.g. `// ==== divider`, `// ----`, pure symbols) -> skip (leave byte-identical).
            int j = i;
            while (j < regionEnd)
            {
                char c = text[j];
                if (char.IsWhiteSpace(c)) return text;   // symbols are a standalone token -> no reachable letter
                if (char.IsLetterOrDigit(c)) break;      // reached the word/number start
                j++;                                     // strip this punctuation/symbol char
            }
            if (j >= regionEnd) return text;             // pure symbols / no content -> skip

            char first = text[j];
            // Only an ASCII lowercase letter is uppercased. A digit, an already-uppercase ASCII letter, or a
            // non-ASCII letter (Hangul/CJK, which has no uppercase) -> skip. This keeps `// 한글주석`, `// 3)`,
            // and `// Already capitalized` byte-identical, and makes a second run a no-op.
            if (!(first >= 'a' && first <= 'z')) return text;

            // Keep the delimiter + leading whitespace [0, i); DROP the stripped punctuation [i, j); uppercase the
            // first letter; keep the remainder (including any closing `*/`).
            return text.Substring(0, i) + char.ToUpperInvariant(first) + text.Substring(j + 1);
        }

        private static string NormalizeCommentContent(string content)
        {
            string s = content.Trim();
            if (s.Length == 0) return "";

            s = StripKnownTag(s, "@brief", "");
            s = StripKnownTag(s, "@param", "Param");
            s = StripKnownTag(s, "@returns", "Returns");
            s = StripKnownTag(s, "@return", "Returns");
            s = StripKnownTag(s, "@details", "");
            s = s.Trim();
            while (s.StartsWith("@", StringComparison.Ordinal)) s = s.Substring(1).TrimStart();
            if (s.Length == 0) return "";
            if (!ContainsPeriodChar(s)) return "";

            s = CapitalizeFirstAsciiLetter(s);
            if (NeedsPeriod(s)) s += ".";
            return s;
        }

        private static bool IsProtectedCommentTrivia(string text)
        {
            if (text.IndexOf("NOSONAR", StringComparison.OrdinalIgnoreCase) >= 0
                || text.IndexOf("ReSharper", StringComparison.OrdinalIgnoreCase) >= 0
                || text.IndexOf("NOLINT", StringComparison.OrdinalIgnoreCase) >= 0
                || text.IndexOf("suppress", StringComparison.OrdinalIgnoreCase) >= 0
                || text.IndexOf("@code", StringComparison.OrdinalIgnoreCase) >= 0
                || text.IndexOf("@endcode", StringComparison.OrdinalIgnoreCase) >= 0
                || text.IndexOf("@ref", StringComparison.OrdinalIgnoreCase) >= 0
                || text.IndexOf("\\code", StringComparison.OrdinalIgnoreCase) >= 0
                || text.IndexOf("\\endcode", StringComparison.OrdinalIgnoreCase) >= 0
                || text.IndexOf("\\param", StringComparison.OrdinalIgnoreCase) >= 0
                || text.IndexOf("\\ref", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                return true;
            }
            if (IsSingleLine(text))
            {
                string line = text.Substring(SlashRun(text)).Trim();
                if (line.StartsWith("@", StringComparison.Ordinal) && !IsAllowedDoxygenLine(line)) return true;
                if (!line.StartsWith("@", StringComparison.Ordinal) && line.IndexOf("@", StringComparison.Ordinal) >= 0) return true;
                if (line.StartsWith("\\", StringComparison.Ordinal)) return true;
                if (line.IndexOf("\\", StringComparison.Ordinal) >= 0) return true;
            }
            if (IsBlock(text))
            {
                string inner = text.Substring(2, text.Length - 4).Replace("\r\n", "\n").Replace("\r", "\n");
                foreach (string raw in inner.Split('\n'))
                {
                    string line = raw.Trim();
                    while (line.StartsWith("*", StringComparison.Ordinal)) line = line.Substring(1).TrimStart();
                    if (line.Length == 0) continue;
                    if (line.StartsWith("@", StringComparison.Ordinal) && !IsAllowedDoxygenLine(line)) return true;
                    if (line.StartsWith("\\", StringComparison.Ordinal)) return true;
                    if (line.IndexOf("@", StringComparison.Ordinal) > 0) return true;
                    if (line.IndexOf("\\", StringComparison.Ordinal) > 0) return true;
                }
            }
            return false;
        }

        private static bool ContainsPeriodChar(string text)
        {
            foreach (char c in text)
                if (IsPeriodChar(c)) return true;
            return false;
        }

        private static bool IsAllowedDoxygenLine(string line)
        {
            return IsExactTagOrTagWithSpace(line, "@brief")
                   || IsExactTagOrTagWithSpace(line, "@param")
                   || IsExactTagOrTagWithSpace(line, "@returns")
                   || IsExactTagOrTagWithSpace(line, "@return")
                   || IsExactTagOrTagWithSpace(line, "@details");
        }

        private static bool IsExactTagOrTagWithSpace(string text, string tag)
        {
            if (!text.StartsWith(tag, StringComparison.OrdinalIgnoreCase)) return false;
            return text.Length == tag.Length || char.IsWhiteSpace(text[tag.Length]);
        }

        private static string StripKnownTag(string text, string tag, string replacement)
        {
            if (!IsExactTagOrTagWithSpace(text, tag)) return text;
            string rest = text.Substring(tag.Length).TrimStart();
            if (replacement.Length == 0) return rest;
            return replacement + (rest.Length == 0 ? "" : " " + rest);
        }

        private static string CapitalizeFirstAsciiLetter(string text)
        {
            for (int i = 0; i < text.Length; i++)
            {
                char c = text[i];
                if (c >= 'a' && c <= 'z')
                    return text.Substring(0, i) + char.ToUpperInvariant(c) + text.Substring(i + 1);
                if (char.IsLetterOrDigit(c)) return text;
            }
            return text;
        }

        private static bool NeedsPeriod(string text)
        {
            int last = text.Length - 1;
            while (last >= 0 && char.IsWhiteSpace(text[last])) last--;
            if (last < 0) return false;
            char c = text[last];
            return IsPeriodChar(c);
        }

        private static void AddMemberBlankLineEdits(string text, SyntaxNode root, List<Edit> edits, Dictionary<string, int> ruleCounts)
        {
            foreach (TypeDeclarationSyntax type in root.DescendantNodes().OfType<TypeDeclarationSyntax>())
            {
                SyntaxList<MemberDeclarationSyntax> members = type.Members;
                // Loop from i=1 so the FIRST member (right after `{`) never gets a blank before it. Insert one
                // blank between EVERY consecutive method/property pair -- not just some.
                for (int i = 1; i < members.Count; i++)
                {
                    MemberDeclarationSyntax prev = members[i - 1];
                    MemberDeclarationSyntax next = members[i];
                    if (!IsBlankLineTarget(prev) || !IsBlankLineTarget(next)) continue;
                    // Only directives / disabled / skipped tokens between the two members are unsafe. A comment
                    // (or comment run / attribute list) preceding `next` is part of `next` -- it must NOT block
                    // the edit; the blank goes BEFORE that comment block (handled by MemberBlockStart below).
                    if (HasRiskyBetween(prev, next)) continue;
                    if (LineStart(text, prev.SpanStart) == LineStart(text, next.SpanStart)) continue;

                    // The blank belongs before `next`'s leading comment/attribute block, never between the
                    // comment and its member. Attributes live inside next.Span (so next.SpanStart already
                    // precedes them); own-line leading comments live in leading trivia, handled explicitly.
                    int blockStart = MemberBlockStart(text, next);
                    int gapStart = prev.Span.End;
                    if (gapStart >= blockStart) continue;
                    // Idempotent: a blank line already sits before the block (>=2 newlines from prev's end).
                    if (NewlineCount(text, gapStart, blockStart) >= 2) continue;
                    edits.Add(new Edit(blockStart, 0, DetectNewline(text)));
                    ruleCounts["memberblank"]++;
                }
            }
        }

        // Start of `next`'s member block = the line start of its FIRST own-line leading comment (that comment
        // run belongs to the member below it), or the line start of the member token itself when it has no
        // leading comment. Attributes are children of the member node (inside next.SpanStart), so they need no
        // special handling here.
        private static int MemberBlockStart(string text, MemberDeclarationSyntax next)
        {
            foreach (SyntaxTrivia trivia in next.GetLeadingTrivia())
            {
                if (trivia.IsKind(SyntaxKind.SingleLineCommentTrivia)
                    || trivia.IsKind(SyntaxKind.MultiLineCommentTrivia)
                    || trivia.IsKind(SyntaxKind.SingleLineDocumentationCommentTrivia)
                    || trivia.IsKind(SyntaxKind.MultiLineDocumentationCommentTrivia))
                {
                    return LineStart(text, trivia.FullSpan.Start);
                }
            }
            return LineStart(text, next.SpanStart);
        }

        // Directive / disabled-text / skipped-tokens trivia between two members makes a blank-line insertion
        // unsafe. Comments do NOT count -- they legitimately precede a member. Only the gap trivia matters, so
        // we inspect prev's trailing trivia and next's leading trivia (which together span the between-region).
        private static bool HasRiskyBetween(MemberDeclarationSyntax prev, MemberDeclarationSyntax next)
        {
            foreach (SyntaxTrivia trivia in prev.GetTrailingTrivia())
                if (IsRiskyGapTrivia(trivia)) return true;
            foreach (SyntaxTrivia trivia in next.GetLeadingTrivia())
                if (IsRiskyGapTrivia(trivia)) return true;
            return false;
        }

        private static bool IsRiskyGapTrivia(SyntaxTrivia trivia)
        {
            return trivia.IsDirective
                   || trivia.IsKind(SyntaxKind.DisabledTextTrivia)
                   || trivia.IsKind(SyntaxKind.SkippedTokensTrivia);
        }

        private static bool IsBlankLineTarget(MemberDeclarationSyntax member)
        {
            return member is MethodDeclarationSyntax
                   || member is PropertyDeclarationSyntax
                   || member is IndexerDeclarationSyntax
                   || member is EventDeclarationSyntax
                   || member is ConstructorDeclarationSyntax
                   || member is DestructorDeclarationSyntax
                   || member is OperatorDeclarationSyntax
                   || member is ConversionOperatorDeclarationSyntax;
        }

        private static void AddOneStatementPerLineEdits(string text, SyntaxNode root, List<Edit> edits, Dictionary<string, int> ruleCounts)
        {
            foreach (IfStatementSyntax ifStatement in root.DescendantNodes().OfType<IfStatementSyntax>())
            {
                if (ifStatement.Statement is not BlockSyntax ifBlock) continue;
                if (ifBlock.Statements.Count < 2) continue;
                if (HasRiskyTrivia(ifBlock)) continue;
                if (ifBlock.DescendantNodes().OfType<IfStatementSyntax>().Any()) continue;
                if (LineStart(text, ifBlock.OpenBraceToken.SpanStart) != LineStart(text, ifBlock.CloseBraceToken.SpanStart)) continue;

                string indent = IndentBefore(text, ifStatement.SpanStart);
                string childIndent = indent + "    ";
                string nl = DetectNewline(text);
                var lines = new List<string> { "{" };
                foreach (StatementSyntax statement in ifBlock.Statements)
                    lines.Add(childIndent + statement.WithoutTrivia().ToFullString());
                lines.Add(indent + "}");
                edits.Add(new Edit(ifBlock.SpanStart, ifBlock.Span.Length, string.Join(nl, lines)));
                ruleCounts["onestatement"]++;
            }

            foreach (BlockSyntax block in root.DescendantNodes().OfType<BlockSyntax>())
            {
                if (block.Parent is IfStatementSyntax ifs && ifs.Statement == block) continue;
                SyntaxList<StatementSyntax> statements = block.Statements;
                for (int i = 1; i < statements.Count; i++)
                {
                    StatementSyntax prev = statements[i - 1];
                    StatementSyntax next = statements[i];
                    if (prev is LocalDeclarationStatementSyntax local && local.Declaration.Variables.Count > 1) continue;
                    if (LineStart(text, prev.Span.End) != LineStart(text, next.SpanStart)) continue;
                    if (HasCommentOrDirectiveBetween(text, prev.Span.End, next.SpanStart)) continue;
                    string indent = IndentBefore(text, block.OpenBraceToken.SpanStart) + "    ";
                    edits.Add(new Edit(prev.Span.End, next.SpanStart - prev.Span.End, DetectNewline(text) + indent));
                    ruleCounts["onestatement"]++;
                }
            }
        }

        private static void AddOneDeclarationPerLineEdits(string text, SyntaxNode root, List<Edit> edits, Dictionary<string, int> ruleCounts)
        {
            foreach (LocalDeclarationStatementSyntax local in root.DescendantNodes().OfType<LocalDeclarationStatementSyntax>())
            {
                SeparatedSyntaxList<VariableDeclaratorSyntax> vars = local.Declaration.Variables;
                if (vars.Count <= 1) continue;
                if (HasRiskyTrivia(local)) continue;
                if (local.UsingKeyword.IsKind(SyntaxKind.UsingKeyword)) continue;

                int start = LineStart(text, local.SpanStart);
                if (text.Substring(start, local.SpanStart - start).Trim().Length != 0) continue;
                string indent = LeadingWhitespace(text.Substring(start, local.SpanStart - start));
                string nl = DetectNewline(text);
                string mods = ModifiersText(local.Modifiers);
                string type = local.Declaration.Type.WithoutTrivia().ToFullString();
                var lines = new List<string>();
                foreach (VariableDeclaratorSyntax variable in vars)
                {
                    lines.Add(indent + mods + type + " " + variable.WithoutTrivia().ToFullString() + ";");
                }
                edits.Add(new Edit(start, local.Span.End - start, string.Join(nl, lines)));
                ruleCounts["onedeclaration"]++;
            }

            foreach (FieldDeclarationSyntax field in root.DescendantNodes().OfType<FieldDeclarationSyntax>())
            {
                SeparatedSyntaxList<VariableDeclaratorSyntax> vars = field.Declaration.Variables;
                if (vars.Count <= 1) continue;
                if (HasRiskyTrivia(field)) continue;
                if (field.AttributeLists.Count > 0) continue;
                int start = LineStart(text, field.SpanStart);
                if (text.Substring(start, field.SpanStart - start).Trim().Length != 0) continue;
                string indent = LeadingWhitespace(text.Substring(start, field.SpanStart - start));
                string nl = DetectNewline(text);
                string mods = ModifiersText(field.Modifiers);
                string type = field.Declaration.Type.WithoutTrivia().ToFullString();
                var lines = new List<string>();
                foreach (VariableDeclaratorSyntax variable in vars)
                    lines.Add(indent + mods + type + " " + variable.WithoutTrivia().ToFullString() + ";");
                edits.Add(new Edit(start, field.Span.End - start, string.Join(nl, lines)));
                ruleCounts["onedeclaration"]++;
            }
        }

        private static void AddContinuationIndentEdits(string text, SyntaxNode root, List<Edit> edits, Dictionary<string, int> ruleCounts)
        {
            var touchedLines = new HashSet<int>();

            foreach (ArgumentListSyntax list in root.DescendantNodes().OfType<ArgumentListSyntax>())
            {
                int baseLine = LineStart(text, list.SpanStart);
                string desired = IndentBefore(text, list.SpanStart) + "    ";
                SeparatedSyntaxList<ArgumentSyntax> args = list.Arguments;
                for (int i = 0; i < args.Count; i++)
                {
                    ArgumentSyntax arg = args[i];
                    // The continuation line's first token is either the argument itself (comma-trailing style:
                    // `foo(a,\n    b)`) or the leading comma separator (comma-led style: `foo(a\n    , b)`).
                    // Anchor on whichever begins the physical line so the indent fix targets its true start.
                    int anchor = arg.SpanStart;
                    if (i >= 1)
                    {
                        int sepStart = args.GetSeparator(i - 1).SpanStart;
                        if (LineStart(text, sepStart) == LineStart(text, arg.SpanStart)) anchor = sepStart;
                    }
                    int argLine = LineStart(text, anchor);
                    if (argLine == baseLine || !touchedLines.Add(argLine)) continue;
                    if (TrySetLineIndent(text, anchor, desired, out Edit edit))
                    {
                        edits.Add(edit);
                        ruleCounts["continuation"]++;
                    }
                }
            }

            foreach (BinaryExpressionSyntax binary in root.DescendantNodes().OfType<BinaryExpressionSyntax>())
            {
                if (!IsContinuationBinaryKind(binary.Kind())) continue;
                int baseLine = LineStart(text, binary.Left.SpanStart);
                // The continuation line's first token is either the operator (operator-led style, dominant in
                // OSTES: `if (a\n    && b)`) or the right operand (operator-trailing style: `if (a &&\n    b)`).
                // When the operator and right operand share a line, the operator leads -> anchor on the operator;
                // otherwise the right operand starts the continuation line. Anchoring on the operand alone (the
                // old behavior) silently missed every operator-led line because its true start is `&&`/`||`.
                int opStart = binary.OperatorToken.SpanStart;
                int rightStart = binary.Right.SpanStart;
                int anchor = LineStart(text, opStart) == LineStart(text, rightStart) ? opStart : rightStart;
                int contLine = LineStart(text, anchor);
                if (contLine == baseLine || !touchedLines.Add(contLine)) continue;
                string desired = IndentBefore(text, binary.Left.SpanStart) + "    ";
                if (TrySetLineIndent(text, anchor, desired, out Edit edit))
                {
                    edits.Add(edit);
                    ruleCounts["continuation"]++;
                }
            }

            // Method-chain continuation: a `.Member` whose leading `.` begins its own physical line (fluent style,
            // e.g. `receiver\n    .OrderBy(...)\n    .ToList()`). The reference (opening-line) indent is the line
            // where THIS access's receiver begins; the `.` line is pulled to receiver-indent + 4 when it is not
            // already at least that deep. Same conservative `onlyIfInsufficient` contract as the binary/arg cases,
            // so already-correct or deeper-than-opening+4 lines (Geometry.cs:171-style) are left byte-identical.
            foreach (MemberAccessExpressionSyntax member in root.DescendantNodes().OfType<MemberAccessExpressionSyntax>())
            {
                if (!member.IsKind(SyntaxKind.SimpleMemberAccessExpression)) continue;
                int dotStart = member.OperatorToken.SpanStart;
                int dotLine = LineStart(text, dotStart);
                int baseLine = LineStart(text, member.Expression.SpanStart);
                if (dotLine == baseLine) continue;                    // `.` is on the receiver's line -> not a continuation
                if (!touchedLines.Add(dotLine)) continue;
                string desired = IndentBefore(text, member.Expression.SpanStart) + "    ";
                if (TrySetLineIndent(text, dotStart, desired, out Edit edit))
                {
                    edits.Add(edit);
                    ruleCounts["continuation"]++;
                }
            }

            // Initializer / collection continuation: the `{`, its element lines, and the closing `}` of an
            // object/collection/array initializer that spill below the `new`/`= {` opening line. Each such line is
            // pulled to opening-indent + 4 when it is shallower (`{`(28) under a `new`(32) line -> 36; brace+elements
            // at the same indent as `new` -> +4). Deeper-indented lines are untouched (onlyIfInsufficient).
            foreach (InitializerExpressionSyntax initializer in root.DescendantNodes().OfType<InitializerExpressionSyntax>())
            {
                SyntaxNode anchorNode = initializer.Parent ?? initializer;
                int baseLine = LineStart(text, anchorNode.SpanStart);
                string desired = IndentBefore(text, anchorNode.SpanStart) + "    ";

                ReindentContinuationLine(text, initializer.OpenBraceToken.SpanStart, baseLine, desired, touchedLines, edits, ruleCounts);
                foreach (ExpressionSyntax element in initializer.Expressions)
                    ReindentContinuationLine(text, element.SpanStart, baseLine, desired, touchedLines, edits, ruleCounts);
                ReindentContinuationLine(text, initializer.CloseBraceToken.SpanStart, baseLine, desired, touchedLines, edits, ruleCounts);
            }
        }

        // Pull the physical line that `anchor` begins to `desired` indentation, but only when that line differs from
        // `baseLine` (the construct's opening line), has not already been touched this pass, and is under-indented
        // (TrySetLineIndent's default onlyIfInsufficient guard). Whitespace-only + idempotent.
        private static void ReindentContinuationLine(string text, int anchor, int baseLine, string desired,
            HashSet<int> touchedLines, List<Edit> edits, Dictionary<string, int> ruleCounts)
        {
            int line = LineStart(text, anchor);
            if (line == baseLine) return;
            if (!touchedLines.Add(line)) return;
            if (TrySetLineIndent(text, anchor, desired, out Edit edit))
            {
                edits.Add(edit);
                ruleCounts["continuation"]++;
            }
        }

        // Binary operators whose operator-led / operator-trailing continuation lines the `continuation` rule
        // re-indents to statement-indent + 4. Originally only &&/|| (logical); broadened to arithmetic, shift,
        // bitwise, and string-concat (`+` on strings is AddExpression — already covered). The anchor + indent
        // logic is identical for every kind; only the physical continuation line's leading whitespace is touched.
        private static bool IsContinuationBinaryKind(SyntaxKind kind)
        {
            switch (kind)
            {
                case SyntaxKind.LogicalAndExpression:      // &&
                case SyntaxKind.LogicalOrExpression:       // ||
                case SyntaxKind.AddExpression:             // +  (also string concatenation)
                case SyntaxKind.SubtractExpression:        // -
                case SyntaxKind.MultiplyExpression:        // *
                case SyntaxKind.DivideExpression:          // /
                case SyntaxKind.ModuloExpression:          // %
                case SyntaxKind.LeftShiftExpression:       // <<
                case SyntaxKind.RightShiftExpression:      // >>
                case SyntaxKind.BitwiseAndExpression:      // &
                case SyntaxKind.BitwiseOrExpression:       // |
                case SyntaxKind.ExclusiveOrExpression:     // ^
                    return true;
                default:
                    return false;
            }
        }

        private static void AddLinqAlignmentEdits(string text, SyntaxNode root, List<Edit> edits, Dictionary<string, int> ruleCounts)
        {
            foreach (QueryExpressionSyntax query in root.DescendantNodes().OfType<QueryExpressionSyntax>())
            {
                string desired = ColumnWhitespace(text, query.FromClause.SpanStart);
                foreach (QueryClauseSyntax clause in query.Body.Clauses)
                {
                    if (LineStart(text, clause.SpanStart) == LineStart(text, query.FromClause.SpanStart)) continue;
                    if (TrySetLineIndent(text, clause.SpanStart, desired, out Edit edit, onlyIfInsufficient: false))
                    {
                        edits.Add(edit);
                        ruleCounts["linqalign"]++;
                    }
                }
                SelectOrGroupClauseSyntax selectOrGroup = query.Body.SelectOrGroup;
                if (LineStart(text, selectOrGroup.SpanStart) != LineStart(text, query.FromClause.SpanStart)
                    && TrySetLineIndent(text, selectOrGroup.SpanStart, desired, out Edit finalEdit, onlyIfInsufficient: false))
                {
                    edits.Add(finalEdit);
                    ruleCounts["linqalign"]++;
                }
            }
        }

        private static bool TrySetLineIndent(string text, int tokenStart, string desiredIndent, out Edit edit, bool onlyIfInsufficient = true)
        {
            edit = default;
            int start = LineStart(text, tokenStart);
            string before = text.Substring(start, tokenStart - start);
            if (before.Trim().Length != 0) return false;
            if (before == desiredIndent) return false;
            if (before.IndexOf('\t') >= 0) return false;
            if (onlyIfInsufficient && before.Length >= desiredIndent.Length) return false;
            edit = new Edit(start, before.Length, desiredIndent);
            return true;
        }

        private static string ModifiersText(SyntaxTokenList modifiers)
        {
            if (modifiers.Count == 0) return "";
            return string.Join(" ", modifiers.Select(m => m.WithoutTrivia().ToFullString())) + " ";
        }

        private static string ColumnWhitespace(string text, int tokenStart)
        {
            int start = LineStart(text, tokenStart);
            int columns = tokenStart - start;
            return new string(' ', columns);
        }

        private static string PeriodAt(string text, int start, int end)
        {
            if (start < 0 || end > text.Length || start >= end) return text;

            int last = end - 1;
            while (last >= start && char.IsWhiteSpace(text[last])) last--;
            if (last < start) return text;   // empty / whitespace-only content

            // Pure-decoration guard: content (ignoring whitespace) has NO letter/digit at all (e.g. `// ----`,
            // `/****/`). Sparrow doesn't flag a sentence-less divider, so leave it untouched (avoids churn).
            bool anyAlnum = false;
            for (int i = start; i < end; i++) { if (IsPeriodChar(text[i])) { anyAlnum = true; break; } }
            if (!anyAlnum) return text;

            // Goal = pass Sparrow's MISSING_PERIOD (comment must END with a terminal punctuation . ? !). A comment
            // is ONLY skipped when it already ends with one of those; otherwise append a period — regardless of the
            // last char (`)`, symbol, box-drawing `─`, or commented-out code). Comments have no runtime effect, so
            // this is safe; the only real guards are compile-safety (inline `/* */` keeps its `*/`, string literals
            // untouched — handled by the caller/region) and idempotency (already-terminal -> no-op).
            if (IsTerminalPunct(text[last])) return text;
            return text.Substring(0, last + 1) + "." + text.Substring(last + 1);
        }

        // ---------------------------------------------------------------------------------------------------
        // Edit application
        // ---------------------------------------------------------------------------------------------------

        private readonly struct Edit
        {
            public readonly int Start;
            public readonly int Length;
            public readonly string Replacement;
            public Edit(int start, int length, string replacement) { Start = start; Length = length; Replacement = replacement; }
        }

        private static string ApplyEdits(string text, List<Edit> edits)
        {
            // Ascending by Start (each edit replaces one distinct, non-overlapping comment span), with Length
            // as a stable tie-break. Splice the replacements into the original text in one pass.
            edits.Sort((x, y) => x.Start != y.Start ? x.Start.CompareTo(y.Start) : x.Length.CompareTo(y.Length));

            var sb = new StringBuilder(text.Length + 16);
            int pos = 0;
            foreach (Edit e in edits)
            {
                if (e.Start < pos) throw new InvalidOperationException("overlapping edits (internal bug)");
                sb.Append(text, pos, e.Start - pos);
                sb.Append(e.Replacement);
                pos = e.Start + e.Length;
            }
            sb.Append(text, pos, text.Length - pos);
            return sb.ToString();
        }

        private static bool HasOverlappingEdits(List<Edit> edits)
        {
            edits.Sort((x, y) => x.Start != y.Start ? x.Start.CompareTo(y.Start) : x.Length.CompareTo(y.Length));
            int pos = 0;
            foreach (Edit e in edits)
            {
                if (e.Start < pos) return true;
                pos = e.Start + e.Length;
            }
            return false;
        }

        // ---------------------------------------------------------------------------------------------------
        // --files-from (SparrowXlsExport index.csv): distinct 파일명 column values.
        // ---------------------------------------------------------------------------------------------------

        private static List<string> ReadFilesFrom(string csvPath)
        {
            string full = Path.GetFullPath(csvPath);
            if (!File.Exists(full)) throw new FileNotFoundException("index csv not found: " + full);

            byte[] raw = File.ReadAllBytes(full);
            var enc = new UTF8Encoding(false, false);
            int off = raw.Length >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF ? 3 : 0;
            string content = enc.GetString(raw, off, raw.Length - off);

            List<List<string>> records = ParseCsv(content);
            if (records.Count == 0) throw new InvalidDataException("index csv is empty: " + full);

            List<string> header = records[0];
            int fileCol = -1;
            for (int i = 0; i < header.Count; i++)
            {
                if (string.Equals(header[i].Trim(), "파일명", StringComparison.Ordinal)) { fileCol = i; break; }
            }
            if (fileCol < 0) throw new InvalidDataException("index csv has no '파일명' column: " + full);

            var distinct = new List<string>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            for (int r = 1; r < records.Count; r++)
            {
                List<string> row = records[r];
                if (fileCol >= row.Count) continue;
                string v = row[fileCol].Trim();
                if (v.Length == 0) continue;
                if (seen.Add(v)) distinct.Add(v);
            }
            return distinct;
        }

        // RFC4180-ish CSV: fields separated by ',', quoted with '"', escaped '""'; quoted fields may hold
        // ',' and newlines. Trailing empty record is dropped.
        private static List<List<string>> ParseCsv(string s)
        {
            var records = new List<List<string>>();
            var record = new List<string>();
            var field = new StringBuilder();
            bool inQuotes = false;
            int i = 0, n = s.Length;

            void EndField() { record.Add(field.ToString()); field.Clear(); }
            void EndRecord()
            {
                EndField();
                // Skip a purely-empty record (e.g. a trailing newline producing one blank field).
                if (!(record.Count == 1 && record[0].Length == 0)) records.Add(record);
                record = new List<string>();
            }

            while (i < n)
            {
                char c = s[i];
                if (inQuotes)
                {
                    if (c == '"')
                    {
                        if (i + 1 < n && s[i + 1] == '"') { field.Append('"'); i += 2; continue; }
                        inQuotes = false; i++; continue;
                    }
                    field.Append(c); i++; continue;
                }
                if (c == '"') { inQuotes = true; i++; continue; }
                if (c == ',') { EndField(); i++; continue; }
                if (c == '\r') { i++; if (i < n && s[i] == '\n') i++; EndRecord(); continue; }
                if (c == '\n') { i++; EndRecord(); continue; }
                field.Append(c); i++;
            }
            // Flush the final record if there is any pending content.
            if (field.Length > 0 || record.Count > 0) EndRecord();
            return records;
        }

        // ---------------------------------------------------------------------------------------------------
        // Small helpers
        // ---------------------------------------------------------------------------------------------------

        private static bool IsComment(SyntaxKind kind)
        {
            switch (kind)
            {
                case SyntaxKind.SingleLineCommentTrivia:
                case SyntaxKind.MultiLineCommentTrivia:
                case SyntaxKind.SingleLineDocumentationCommentTrivia:
                case SyntaxKind.MultiLineDocumentationCommentTrivia:
                    return true;
                default:
                    return false;
            }
        }

        private static bool IsSingleLine(string text) => text.StartsWith("//", StringComparison.Ordinal);

        private static bool IsBlock(string text) =>
            text.StartsWith("/*", StringComparison.Ordinal) && text.EndsWith("*/", StringComparison.Ordinal) && text.Length >= 4;

        private static bool IsGeneratedOrBackupPath(string path)
        {
            string lowerPath = path.ToLowerInvariant();
            if (lowerPath.Contains("\\obj\\") || lowerPath.Contains("\\bin\\")) return true;
            string lowerName = Path.GetFileName(path).ToLowerInvariant();
            return lowerName.EndsWith(".g.cs", StringComparison.Ordinal)
                   || lowerName.EndsWith(".g.i.cs", StringComparison.Ordinal)
                   || lowerName.EndsWith(".designer.cs", StringComparison.Ordinal)
                   || lowerName == "assemblyinfo.cs"
                   || lowerName.Contains("temporarygeneratedfile")
                   || lowerName.Contains("generatedinternaltypehelper")
                   || lowerName.Contains("복사본");
        }

        private static bool HasAutoGeneratedHeader(string text)
        {
            int scan = 0;
            for (int line = 0; line < 5 && scan < text.Length; line++)
            {
                int end = text.IndexOf('\n', scan);
                if (end < 0) end = text.Length;
                string slice = text.Substring(scan, end - scan);
                if (slice.IndexOf("<auto-generated", StringComparison.OrdinalIgnoreCase) >= 0) return true;
                scan = end + 1;
            }
            return false;
        }

        private static int SlashRun(string text)
        {
            int s = 0;
            while (s < text.Length && text[s] == '/') s++;
            return s;
        }

        private static int LineStart(string text, int index)
        {
            int i = index - 1;
            while (i >= 0 && text[i] != '\r' && text[i] != '\n') i--;
            return i + 1;
        }

        private static int LineEnd(string text, int index)
        {
            int i = index;
            while (i < text.Length && text[i] != '\r' && text[i] != '\n') i++;
            return i;
        }

        private static bool IsStandaloneTriviaLine(string text, int start, int end)
        {
            string before = text.Substring(LineStart(text, start), start - LineStart(text, start));
            string after = text.Substring(end, LineEnd(text, end) - end);
            return before.Trim().Length == 0 && after.Trim().Length == 0;
        }

        private static string LeadingWhitespace(string text)
        {
            int i = 0;
            while (i < text.Length && (text[i] == ' ' || text[i] == '\t')) i++;
            return text.Substring(0, i);
        }

        private static string IndentBefore(string text, int index)
        {
            int start = LineStart(text, index);
            return LeadingWhitespace(text.Substring(start, index - start));
        }

        private static string DetectNewline(string text)
        {
            int crlf = text.IndexOf("\r\n", StringComparison.Ordinal);
            if (crlf >= 0) return "\r\n";
            int lf = text.IndexOf('\n');
            if (lf >= 0) return "\n";
            int cr = text.IndexOf('\r');
            if (cr >= 0) return "\r";
            return Environment.NewLine;
        }

        private static string NewlineAtOrDefault(string text, int index)
        {
            if (index < text.Length)
            {
                if (text[index] == '\r')
                {
                    if (index + 1 < text.Length && text[index + 1] == '\n') return "\r\n";
                    return "\r";
                }
                if (text[index] == '\n') return "\n";
            }
            return DetectNewline(text);
        }

        private static int NewlineCount(string text, int start, int end)
        {
            int count = 0;
            for (int i = start; i < end; i++)
            {
                if (text[i] == '\r')
                {
                    count++;
                    if (i + 1 < end && text[i + 1] == '\n') i++;
                }
                else if (text[i] == '\n') count++;
            }
            return count;
        }

        private static bool HasCommentOrDirectiveBetween(string text, int start, int end)
        {
            if (start >= end) return false;
            string slice = text.Substring(start, end - start);
            return slice.Contains("//", StringComparison.Ordinal)
                   || slice.Contains("/*", StringComparison.Ordinal)
                   || slice.Contains("#", StringComparison.Ordinal);
        }

        private static bool HasRiskyTrivia(SyntaxNode node)
        {
            foreach (SyntaxTrivia trivia in node.DescendantTrivia(descendIntoTrivia: true))
            {
                if (trivia.IsDirective) return true;
                if (trivia.IsKind(SyntaxKind.SingleLineCommentTrivia)
                    || trivia.IsKind(SyntaxKind.MultiLineCommentTrivia)
                    || trivia.IsKind(SyntaxKind.SingleLineDocumentationCommentTrivia)
                    || trivia.IsKind(SyntaxKind.MultiLineDocumentationCommentTrivia)
                    || trivia.IsKind(SyntaxKind.DisabledTextTrivia)
                    || trivia.IsKind(SyntaxKind.SkippedTokensTrivia))
                {
                    return true;
                }
            }
            return false;
        }

        // Letter (ASCII / Hangul syllable / CJK) or ASCII digit -> qualifies for the period rule.
        private static bool IsPeriodChar(char c)
        {
            if (c >= 'A' && c <= 'Z') return true;
            if (c >= 'a' && c <= 'z') return true;
            if (c >= '0' && c <= '9') return true;
            if (c >= '가' && c <= '힣') return true;   // Hangul syllables
            if (c >= '一' && c <= '鿿') return true;   // CJK Unified Ideographs
            if (c >= '㐀' && c <= '䶿') return true;   // CJK Unified Ideographs Extension A
            if (c >= '豈' && c <= '﫿') return true;   // CJK Compatibility Ideographs
            return false;
        }

        // Sparrow's accepted terminal punctuation for a comment sentence: period, question mark, exclamation mark.
        private static bool IsTerminalPunct(char c) => c == '.' || c == '?' || c == '!';

        private static byte[] Prepend(byte[] prefix, byte[] body)
        {
            var outBytes = new byte[prefix.Length + body.Length];
            Buffer.BlockCopy(prefix, 0, outBytes, 0, prefix.Length);
            Buffer.BlockCopy(body, 0, outBytes, prefix.Length, body.Length);
            return outBytes;
        }

        private static void AtomicWrite(string fullPath, byte[] bytes)
        {
            string dir = Path.GetDirectoryName(fullPath) ?? ".";
            string tmp = Path.Combine(dir, "." + Path.GetFileName(fullPath) + "." + Guid.NewGuid().ToString("N") + ".tmp");
            File.WriteAllBytes(tmp, bytes);
            try { File.Move(tmp, fullPath, overwrite: true); }
            catch { File.Delete(tmp); throw; }
        }

        private static bool TryNext(string[] args, ref int i, out string value)
        {
            if (i + 1 >= args.Length) { value = ""; return false; }
            value = args[++i];
            return true;
        }

        // blankline / asterisk are intentionally NOT active (removed/deferred per real-data analysis; see the
        // file header). Name the valid keys AND state the reason so the operator is not left guessing why a
        // checker key they saw in Sparrow is rejected.
        private static string InvalidRuleMessage(string token)
        {
            return "unknown or inactive rule '" + token + "'. valid rules: flatten, trailing, space, period, capitalize, memberblank, onestatement, onedeclaration, continuation, linqalign, all.\n"
                 + "  not active (removed/deferred per real-data analysis; re-addable as a small diff):\n"
                 + "  - asterisk: replaced by flatten for block comments\n"
                 + "  - blankline: replaced by trailing for inline comments";
        }

        private static int Usage(string message)
        {
            Console.Error.WriteLine("error: " + message);
            Console.Error.WriteLine("usage: SparrowCommentFix <file.cs> [<file2.cs> ...] [--files-from index.csv] "
                                    + "[--root DIR] --rules <flatten,trailing,space,period,capitalize,memberblank,onestatement,onedeclaration,continuation,linqalign|all> [--dry-run] [--include-generated]");
            return 2;   // usage / validation error
        }
    }
}
