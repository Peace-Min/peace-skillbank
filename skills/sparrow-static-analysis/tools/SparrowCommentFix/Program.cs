// SparrowCommentFix: deterministic CLI that fixes COMMENT-TRIVIA-ONLY style issues flagged by the Sparrow
// (파수) static analyzer, WITHOUT loading any project. It operates on .cs TEXT files directly, so legacy
// non-SDK .csproj / .NET Framework 4.7.2 targets are irrelevant. Purpose: take the deterministic comment
// clean-ups out of a weak local LLM's hands in an air-gapped environment (Track B of the pipeline).
//
// SCOPE = 2 ACTIVE RULES (reduced after validating every rule against the REAL Sparrow output,
// issues_OSTES_6827.xls / 6855.xls, plus the checker descriptions):
//   space  (FORMATTING.COMMENT.MISSING_SPACE_AFTER_DELIMITER, "//와 주석 사이 공백") -- CORRECT. Kept.
//   period (FORMATTING.COMMENT.MISSING_PERIOD, "주석 문장 끝 종결부호")             -- CORRECT and the tool's
//           main rule (~221 real-source hits). Its guard (append '.' only when the last content char is a
//           letter/digit) auto-skips commented-out code ending in `;`/`]` and divider lines. Kept.
//
// THREE RULES ARE INTENTIONALLY NOT ACTIVE (removed/deferred per that same real-data analysis). This is the
// "code-fix-only" decision: deterministically-unfixable items are simply left unhandled rather than mis-edited.
//   capitalize (FORMATTING.COMMENT.LOWERCASE_FIRST_LETTER) -- REMOVED. Real flagged comments mostly start with
//               한글/기호(`[`, `<`, `.`) that have no deterministic "uppercase", and capitalizing commented-out
//               code (`/*att*/`->`/*Att*/`) is a wrong edit. No safe mechanical contract exists.
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
//  - CLEAN RULE REGISTRY (AllRuleKeys + per-comment rewrite dispatch): the 2 active rules (space, period)
//    each slot in by key. capitalize / blankline / asterisk are intentionally not active (see SCOPE above);
//    passing any of them -- or an unknown key -- exits 2 with a message naming the valid keys and the reason.
//  - TEXT rules (space, period) are pure comment-text rewrites, applied per comment in canonical order.
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

namespace SparrowCommentFix
{
    internal static class Program
    {
        // Canonical order the active text rules are applied in (selection order is irrelevant; application is
        // fixed). Reduced to space+period per real-data analysis; capitalize/blankline/asterisk are NOT active.
        private static readonly string[] AllRuleKeys = { "space", "period" };

        private static int Main(string[] args)
        {
            try { Console.OutputEncoding = new UTF8Encoding(false); } catch { /* stdout may be redirected */ }

            var positional = new List<string>();
            string? filesFrom = null;
            string? root = null;
            string? rulesArg = null;
            bool dryRun = false;

            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i];
                switch (a)
                {
                    case "--files-from": if (!TryNext(args, ref i, out filesFrom)) return Usage("--files-from requires a value"); break;
                    case "--root": if (!TryNext(args, ref i, out root)) return Usage("--root requires a value"); break;
                    case "--rules": if (!TryNext(args, ref i, out rulesArg)) return Usage("--rules requires a value"); break;
                    case "--dry-run": dryRun = true; break;
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
                return Run(positional, filesFrom, root, enabled, dryRun);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("error: " + ex.Message);
                return 1;   // runtime error: IO failure / unreadable index / etc.
            }
        }

        private static int Run(List<string> positional, string? filesFrom, string? root,
                               HashSet<string> enabled, bool dryRun)
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
                FileResult r = ProcessFile(full, enabled, dryRun);
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

        private static FileResult ProcessFile(string fullPath, HashSet<string> enabled, bool dryRun)
        {
            var result = new FileResult();
            foreach (string k in AllRuleKeys) result.RuleCounts[k] = 0;

            byte[] raw = File.ReadAllBytes(fullPath);
            bool hasBom = raw.Length >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF;
            int contentOffset = hasBom ? 3 : 0;
            int contentLength = raw.Length - contentOffset;

            var enc = new UTF8Encoding(false, false);   // no BOM, no throw on decode
            string text = enc.GetString(raw, contentOffset, contentLength);

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
            SyntaxNode root = tree.GetRoot();

            var comments = root.DescendantTrivia().Where(t => IsComment(t.Kind())).ToList();

            var edits = new List<Edit>();

            // The active rules (space, period) are all pure comment-text rewrites, applied per comment in
            // canonical order. Each rule's guards make it a no-op when it does not apply (=> idempotent).
            foreach (SyntaxTrivia t in comments)
            {
                string original = t.ToFullString();
                string cur = original;

                if (enabled.Contains("space"))
                {
                    string next = RewriteSpace(cur);
                    if (!string.Equals(next, cur, StringComparison.Ordinal)) { ruleCounts["space"]++; cur = next; }
                }
                if (enabled.Contains("period"))
                {
                    string next = RewritePeriod(cur);
                    if (!string.Equals(next, cur, StringComparison.Ordinal)) { ruleCounts["period"]++; cur = next; }
                }

                if (!string.Equals(cur, original, StringComparison.Ordinal))
                    edits.Add(new Edit(t.SpanStart, t.Span.Length, cur));
            }

            if (edits.Count == 0) return text;
            return ApplyEdits(text, edits);
        }

        // ---------------------------------------------------------------------------------------------------
        // Text rules
        // ---------------------------------------------------------------------------------------------------

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

        private static string PeriodAt(string text, int start, int end)
        {
            if (start < 0 || end > text.Length || start >= end) return text;

            int last = end - 1;
            while (last >= start && char.IsWhiteSpace(text[last])) last--;
            if (last < start) return text;   // empty / whitespace-only content

            // Divider guard: content (ignoring whitespace) has no letter/digit at all (e.g. `// ----`, `/****/`).
            bool anyAlnum = false;
            for (int i = start; i < end; i++) { if (IsPeriodChar(text[i])) { anyAlnum = true; break; } }
            if (!anyAlnum) return text;

            if (!IsPeriodChar(text[last])) return text;   // already terminal/other punctuation -> leave alone
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

        private static int SlashRun(string text)
        {
            int s = 0;
            while (s < text.Length && text[s] == '/') s++;
            return s;
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

        // capitalize / blankline / asterisk are intentionally NOT active (removed/deferred per real-data
        // analysis; see the file header). Name the valid keys AND state the reason so the operator is not
        // left guessing why a checker key they saw in Sparrow is rejected.
        private static string InvalidRuleMessage(string token)
        {
            return "unknown or inactive rule '" + token + "'. valid rules: space, period, all.\n"
                 + "  not active (removed/deferred per real-data analysis; re-addable as a small diff):\n"
                 + "  - capitalize: 한글/기호로 시작하는 주석이 많아 대문자화 결정론 불가 + 주석처리 코드 오변형 위험 -> 제거\n"
                 + "  - blankline:  실물은 트레일링(인라인) 주석 지적이라 반대 타깃 + 구조 재작성 위험 -> 제거\n"
                 + "  - asterisk:   Doxygen 별표(*) 블록 제거는 스타일 판단 -> 보류";
        }

        private static int Usage(string message)
        {
            Console.Error.WriteLine("error: " + message);
            Console.Error.WriteLine("usage: SparrowCommentFix <file.cs> [<file2.cs> ...] [--files-from index.csv] "
                                    + "[--root DIR] --rules <space,period|all> [--dry-run]");
            return 2;   // usage / validation error
        }
    }
}
