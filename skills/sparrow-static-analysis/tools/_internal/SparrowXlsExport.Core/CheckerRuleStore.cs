// SparrowXlsExport.Core.CheckerRuleStore: local management of per-checker Track C guides
// (references\checkers\<CHECKER_KEY>.md). Lets the GUI add/remove/edit checker rules for checkers
// that do NOT yet have a hand-authored guide, so anyone can register a rule for a previously-unknown
// checker without editing the repo by hand. TriagePreparer reads the guides directory fresh per run
// (SparrowXlsExport.Core.TriagePreparer.Prepare -> File.Exists(<GuidesDir>\<체커키>.md)), so a rule
// added here is picked up on the very next Track C run — no restart, no rebuild.
//
// Encoding: guide files are written UTF-8 WITHOUT BOM with LF line endings (matches the majority of the
// existing guides and the _TEMPLATE.md skeleton; TriagePreparer reads them with a BOM-stripping decoder
// either way, so BOM presence is functionally irrelevant — we standardize on no-BOM/LF).

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using NPOI.SS.UserModel;

namespace SparrowXlsExport.Core
{
    /// <summary>One registered checker rule (guide) in the guides directory.</summary>
    public sealed class CheckerRule
    {
        public CheckerRule(string key, string title, string filePath)
        {
            Key = key;
            Title = title;
            FilePath = filePath;
        }

        /// <summary>File name without the .md extension (== the Sparrow 체커 키).</summary>
        public string Key { get; }

        /// <summary>Text of the first Markdown heading (# ...) in the guide, or "" if none.</summary>
        public string Title { get; }

        /// <summary>Absolute path of the guide .md file.</summary>
        public string FilePath { get; }
    }

    /// <summary>
    /// CRUD over the checker-guide directory (references\checkers). A "registered rule" is any *.md file
    /// whose name does NOT start with '_' (files like _TEMPLATE.md / _BACKLOG.md are reserved scaffolding
    /// and never appear as rules). All validation messages are Korean (surfaced verbatim in the GUI).
    /// </summary>
    public sealed class CheckerRuleStore
    {
        // Sparrow checker keys: OVERLY_BROAD_CATCH, PRACTICE.LOOP_VARIABLE.NOT_USED_IMPLICIT_TYPING, etc.
        // Letters, digits, underscore and dot only. No path separators can appear, so <key>.md is always a
        // leaf inside GuidesDir (no traversal possible).
        private static readonly Regex KeyRe = new Regex(@"^[A-Za-z0-9_.]+$", RegexOptions.Compiled);

        private readonly string _guidesDir;

        public CheckerRuleStore(string guidesDir)
        {
            if (string.IsNullOrWhiteSpace(guidesDir))
                throw new ArgumentException("가이드 폴더 경로가 필요합니다.", nameof(guidesDir));
            _guidesDir = guidesDir;
        }

        /// <summary>The guides directory this store manages.</summary>
        public string GuidesDir => _guidesDir;

        /// <summary>
        /// Registered rules = *.md files in the guides dir whose name does NOT start with '_', ordered by
        /// key (case-insensitive). Returns empty when the directory does not exist yet.
        /// </summary>
        public IReadOnlyList<CheckerRule> List()
        {
            var result = new List<CheckerRule>();
            if (!Directory.Exists(_guidesDir)) return result;

            foreach (string path in Directory.GetFiles(_guidesDir, "*.md")
                         .OrderBy(p => Path.GetFileName(p), StringComparer.OrdinalIgnoreCase))
            {
                string key = Path.GetFileNameWithoutExtension(path);
                if (key.StartsWith("_", StringComparison.Ordinal)) continue;   // reserved scaffolding
                result.Add(new CheckerRule(key, ExtractTitle(path), Path.GetFullPath(path)));
            }
            return result;
        }

        /// <summary>
        /// Create a new guide &lt;key&gt;.md with the given content. Validates the key (non-empty, matches
        /// the Sparrow key charset, not '_'-prefixed, not already registered — case-insensitive). Throws
        /// <see cref="ArgumentException"/> (Korean message) on any violation.
        /// </summary>
        public void Add(string key, string content)
        {
            key = ValidateKey(key);

            Directory.CreateDirectory(_guidesDir);
            string fileName = key + ".md";
            bool exists = Directory.Exists(_guidesDir) && Directory.GetFiles(_guidesDir, "*.md")
                .Any(p => string.Equals(Path.GetFileName(p), fileName, StringComparison.OrdinalIgnoreCase));
            if (exists)
                throw new ArgumentException("이미 등록된 체커 룰입니다: " + key);

            WriteGuide(Path.Combine(_guidesDir, fileName), content);
        }

        /// <summary>Delete &lt;key&gt;.md. Throws <see cref="FileNotFoundException"/> when it does not exist.</summary>
        public void Remove(string key)
        {
            key = (key ?? "").Trim();
            if (key.Length == 0) throw new ArgumentException("삭제할 체커 키가 비어 있습니다.");
            string path = Path.Combine(_guidesDir, key + ".md");
            if (!File.Exists(path))
                throw new FileNotFoundException("삭제할 체커 룰 파일이 없습니다: " + key + ".md", path);
            File.Delete(path);
        }

        /// <summary>Read a registered guide's content (BOM-stripped, LF). Throws when the file is missing.</summary>
        public string ReadContent(string key)
        {
            key = (key ?? "").Trim();
            string path = Path.Combine(_guidesDir, key + ".md");
            if (!File.Exists(path))
                throw new FileNotFoundException("체커 룰 파일이 없습니다: " + key + ".md", path);
            return ReadTextNoBom(path);
        }

        /// <summary>
        /// Overwrite &lt;key&gt;.md with new content (used by the editor's save). Validates the key charset
        /// (defensive — the editor only saves an already-registered rule). Creates the guides dir if needed.
        /// </summary>
        public void SaveContent(string key, string content)
        {
            key = ValidateKey(key);
            Directory.CreateDirectory(_guidesDir);
            WriteGuide(Path.Combine(_guidesDir, key + ".md"), content);
        }

        /// <summary>
        /// Content to pre-fill a new guide: the repo _TEMPLATE.md if present, else a minimal built-in Korean
        /// skeleton (설명 / 판정 기준 / 수정 방법 / 예시).
        /// </summary>
        public string LoadTemplate()
        {
            string templatePath = Path.Combine(_guidesDir, "_TEMPLATE.md");
            if (File.Exists(templatePath)) return ReadTextNoBom(templatePath);
            return BuiltInTemplate();
        }

        /// <summary>
        /// Distinct, non-empty <c>체커 키</c> values from a Sparrow result .xls/.xlsx, in first-seen order.
        /// Reuses the same sheet-pick + header-mapping conventions as <see cref="SparrowExporter"/> (prefer a
        /// sheet named "issues", else sheet 0; header row = first non-empty row; column resolved by the
        /// verbatim header "체커 키"). Returns empty when there is no such column. Does NOT duplicate the
        /// exporter's md/csv generation — it only scans one column.
        /// </summary>
        public static IReadOnlyList<string> GetXlsCheckerKeys(string xlsPath)
        {
            if (string.IsNullOrWhiteSpace(xlsPath)) throw new ArgumentException("xls 경로가 필요합니다.", nameof(xlsPath));
            string full = Path.GetFullPath(xlsPath);
            if (!File.Exists(full)) throw new FileNotFoundException("xls 파일이 없습니다: " + full, full);

            IWorkbook workbook;
            using (FileStream fs = File.OpenRead(full))
            {
                workbook = WorkbookFactory.Create(fs);   // auto-detects HSSF (.xls) vs XSSF (.xlsx)
            }

            ISheet? named = workbook.GetSheet("issues");
            ISheet sheet = named ?? workbook.GetSheetAt(0);

            // Header row = first non-empty row; map header text -> column index (first wins on duplicates).
            int checkerCol = -1;
            int headerRowIdx = -1;
            for (int r = sheet.FirstRowNum; r <= sheet.LastRowNum; r++)
            {
                IRow? row = sheet.GetRow(r);
                if (row == null) continue;
                bool any = false;
                for (int c = row.FirstCellNum; c < row.LastCellNum; c++)
                    if (CellToString(row.GetCell(c)).Trim().Length > 0) { any = true; break; }
                if (!any) continue;

                headerRowIdx = r;
                for (int c = row.FirstCellNum; c < row.LastCellNum; c++)
                {
                    string h = CellToString(row.GetCell(c)).Trim();
                    if (h == "체커 키") { checkerCol = c; break; }
                }
                break;
            }
            if (headerRowIdx < 0 || checkerCol < 0) return new List<string>();

            var seen = new HashSet<string>(StringComparer.Ordinal);
            var ordered = new List<string>();
            for (int r = headerRowIdx + 1; r <= sheet.LastRowNum; r++)
            {
                IRow? row = sheet.GetRow(r);
                if (row == null) continue;
                string v = CellToString(row.GetCell(checkerCol)).Trim();
                if (v.Length == 0) continue;
                if (seen.Add(v)) ordered.Add(v);
            }
            return ordered;
        }

        // --- internals ---

        private string ValidateKey(string key)
        {
            key = (key ?? "").Trim();
            if (key.Length == 0)
                throw new ArgumentException("체커 키를 입력하세요.");
            if (key.StartsWith("_", StringComparison.Ordinal))
                throw new ArgumentException("체커 키는 '_'로 시작할 수 없습니다. ('_'는 템플릿/백로그 등 예약 파일용입니다.)");
            if (!KeyRe.IsMatch(key))
                throw new ArgumentException("체커 키 형식이 올바르지 않습니다. 영문/숫자/밑줄(_)/마침표(.)만 사용하세요. (예: OVERLY_BROAD_CATCH)");
            return key;
        }

        // Write UTF-8 WITHOUT BOM, LF line endings (matches existing guide/_TEMPLATE conventions).
        private static void WriteGuide(string path, string content)
        {
            string lf = (content ?? "").Replace("\r\n", "\n").Replace("\r", "\n");
            File.WriteAllText(path, lf, new UTF8Encoding(false));
        }

        // Decode UTF-8, strip a single leading BOM, normalize to LF (mirrors TriagePreparer.ReadTextNoBom).
        private static string ReadTextNoBom(string path)
        {
            byte[] bytes = File.ReadAllBytes(path);
            string text = new UTF8Encoding(false).GetString(bytes);
            if (text.Length > 0 && text[0] == '﻿') text = text.Substring(1);
            return text.Replace("\r\n", "\n").Replace("\r", "\n");
        }

        // First Markdown heading line ("# ...", any level) -> its text; "" when none.
        private static string ExtractTitle(string path)
        {
            string text;
            try { text = ReadTextNoBom(path); }
            catch (IOException) { return ""; }

            foreach (string raw in text.Split('\n'))
            {
                string line = raw.TrimStart();
                if (!line.StartsWith("#", StringComparison.Ordinal)) continue;
                int i = 0;
                while (i < line.Length && line[i] == '#') i++;
                return line.Substring(i).Trim();
            }
            return "";
        }

        private static string BuiltInTemplate()
        {
            var sb = new StringBuilder();
            sb.Append("# <체커 키> — <체커명>\n\n");
            sb.Append("- **트랙**: C\n\n");
            sb.Append("## 설명\n");
            sb.Append("[작성: 이 체커가 무엇을 검출하는지, 어떤 결함/위험을 막으려는지.]\n\n");
            sb.Append("## 판정 기준\n");
            sb.Append("[작성: 이게 진짜 결함인 조건. 코드 맥락에서 무엇을 보면 결함인가. false-positive 처럼 보여도 전건 수정 대상.]\n\n");
            sb.Append("## 수정 방법\n");
            sb.Append("[작성: 안전한 표준 수정 방향. .NET Framework 4.7.2 / C# 7.3 문법만 사용.]\n\n");
            sb.Append("## 예시\n");
            sb.Append("```csharp\n");
            sb.Append("// Before\n\n");
            sb.Append("// After\n");
            sb.Append("```\n");
            return sb.ToString();
        }

        // Minimal cell -> string (checker-key column is textual; numeric fallback kept for safety).
        private static string CellToString(ICell? cell)
        {
            if (cell == null) return "";
            switch (cell.CellType)
            {
                case CellType.String: return cell.StringCellValue ?? "";
                case CellType.Boolean: return cell.BooleanCellValue ? "true" : "false";
                case CellType.Numeric:
                    double d = cell.NumericCellValue;
                    if (!double.IsNaN(d) && !double.IsInfinity(d) && d == Math.Truncate(d) && Math.Abs(d) < 9.007199254740992e15)
                        return ((long)d).ToString(System.Globalization.CultureInfo.InvariantCulture);
                    return d.ToString("R", System.Globalization.CultureInfo.InvariantCulture);
                case CellType.Formula:
                    switch (cell.CachedFormulaResultType)
                    {
                        case CellType.String: return cell.StringCellValue ?? "";
                        default: return "";
                    }
                default: return "";
            }
        }
    }
}
