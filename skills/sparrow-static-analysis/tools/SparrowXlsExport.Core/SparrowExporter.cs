// SparrowXlsExport.Core: deterministic parsing library that reads a Sparrow (파수 정적분석) result .xls
// (real BIFF/OLE2, or .xlsx) WITHOUT Excel/COM, and splits it into per-item markdown + an index + a
// per-checker worklist. Shared by the console tool (thin CLI wrapper) and the WPF GUI (in-process).
//
// Design points baked in:
//  - GENERIC header mapping: whatever headers exist become table columns; a fixed set of Sparrow columns
//    is treated as WELL-KNOWN only for filenames/index/summary (ID / 체커 키 / 체커명 / 위험도 / 파일명 /
//    라인 / 이슈 상태 / 체커 설명 / 소스 코드).
//  - deterministic: sheet order preserved; filters AND-combined; --max caps the written set; all three
//    outputs (per-item md, index.csv, checkers.md) reflect that same written set.
//  - encodings: md/csv are UTF-8 WITHOUT BOM, EXCEPT index.csv which is written WITH a BOM so Excel shows
//    Korean correctly. Files use LF line endings.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using NPOI.SS.UserModel;

namespace SparrowXlsExport.Core
{
    /// <summary>Inputs for a single export run. Mirrors the console CLI options.</summary>
    public sealed class ExportOptions
    {
        /// <summary>Path to the input .xls/.xlsx (required).</summary>
        public string InputPath = "";

        /// <summary>Output directory; null =&gt; &lt;input dir&gt;\&lt;name&gt;.items next to the input.</summary>
        public string? OutDir;

        /// <summary>Case-insensitive substring filter on 체커 키; null =&gt; no checker filter.</summary>
        public string? Checker;

        /// <summary>Case-insensitive substring filter on 이슈 상태; null =&gt; no status filter.</summary>
        public string? Status;

        /// <summary>Exact-match severity set (AND-combined with the other filters). Empty =&gt; no severity filter.</summary>
        public ISet<string> Severities = new HashSet<string>(StringComparer.Ordinal);

        /// <summary>Cap on the number of written items; null =&gt; no cap.</summary>
        public int? Max;
    }

    /// <summary>Structured result of a successful export (also written as the human summary to the log).</summary>
    public sealed class ExportResult
    {
        public string InputPath = "";
        public string OutputDir = "";
        public string SheetName = "";
        public int SheetIndex;
        public string SheetPick = "";
        public int Columns;
        public int TotalDataRows;
        public int MatchedCount;
        public int WrittenCount;
        public int UniqueCheckers;
        public IReadOnlyList<(string Sev, int Count)> SeverityCounts = Array.Empty<(string, int)>();
        public int MergedRegions;
    }

    /// <summary>Deterministic Sparrow .xls -&gt; split-outputs exporter. Stateless; safe to call repeatedly.</summary>
    public static class SparrowExporter
    {
        // Well-known Sparrow columns (used for filenames/index/summary; NOT required to exist).
        private const string CID = "ID";
        private const string CCheckerKey = "체커 키";
        private const string CCheckerName = "체커명";
        private const string CSeverity = "위험도";
        private const string CFileName = "파일명";
        private const string CLine = "라인";
        private const string CStatus = "이슈 상태";
        private const string CDesc = "체커 설명";
        private const string CSource = "소스 코드";

        /// <summary>
        /// Parse the workbook and write items/{...}.md + index.csv + checkers.md, exactly as the console tool.
        /// Writes the same human summary lines (incl. the "output dir:" line) to <paramref name="log"/> when
        /// it is non-null. Throws FileNotFoundException / InvalidDataException / IO exceptions on failure
        /// (caller maps to exit codes; nothing is caught here).
        /// </summary>
        public static ExportResult Run(ExportOptions opts, TextWriter? log = null)
        {
            string input = opts.InputPath;
            string? outDir = opts.OutDir;
            string? checker = opts.Checker;
            string? status = opts.Status;
            ISet<string> severities = opts.Severities ?? new HashSet<string>(StringComparer.Ordinal);
            int? max = opts.Max;

            string inputFull = Path.GetFullPath(input);
            if (!File.Exists(inputFull)) throw new FileNotFoundException("input file not found: " + inputFull);

            outDir ??= Path.Combine(Path.GetDirectoryName(inputFull) ?? ".", Path.GetFileNameWithoutExtension(inputFull) + ".items");
            outDir = Path.GetFullPath(outDir);
            string itemsDir = Path.Combine(outDir, "items");
            Directory.CreateDirectory(itemsDir);

            var fmt = new DataFormatter(CultureInfo.InvariantCulture);

            IWorkbook workbook;
            using (FileStream fs = File.OpenRead(inputFull))
            {
                workbook = WorkbookFactory.Create(fs);   // auto-detects HSSF (.xls) vs XSSF (.xlsx)
            }

            // Sheet pick: prefer the sheet named "issues", else sheet 0.
            ISheet sheet;
            int sheetIdx;
            string sheetPick;
            ISheet? named = workbook.GetSheet("issues");
            if (named != null) { sheet = named; sheetIdx = workbook.GetSheetIndex(named); sheetPick = "named 'issues'"; }
            else { sheet = workbook.GetSheetAt(0); sheetIdx = 0; sheetPick = "first sheet (no 'issues')"; }

            int mergedRegions = sheet.NumMergedRegions;   // reported as an anomaly if > 0

            // Header row = first non-empty row. Map non-empty header cell text -> column order.
            var columns = new List<(string Header, int Col)>();
            var headerToIdx = new Dictionary<string, int>(StringComparer.Ordinal);   // header -> position in columns
            int headerRowIdx = -1;
            for (int r = sheet.FirstRowNum; r <= sheet.LastRowNum; r++)
            {
                IRow? row = sheet.GetRow(r);
                if (row == null) continue;
                bool any = false;
                for (int c = row.FirstCellNum; c < row.LastCellNum; c++)
                {
                    if (CellToString(row.GetCell(c), fmt).Trim().Length > 0) { any = true; break; }
                }
                if (!any) continue;
                headerRowIdx = r;
                for (int c = row.FirstCellNum; c < row.LastCellNum; c++)
                {
                    string h = CellToString(row.GetCell(c), fmt).Trim();
                    if (h.Length == 0) continue;
                    if (!headerToIdx.ContainsKey(h)) headerToIdx[h] = columns.Count;   // first wins on duplicate header
                    columns.Add((h, c));
                }
                break;
            }
            if (headerRowIdx < 0 || columns.Count == 0) throw new InvalidDataException("no header row found on sheet '" + sheet.SheetName + "'");

            // Read data rows (skip fully-empty). Ordinal = 1-based position among data rows (stable across filters).
            var records = new List<(int Ord, string[] Vals)>();
            int ord = 0;
            for (int r = headerRowIdx + 1; r <= sheet.LastRowNum; r++)
            {
                IRow? row = sheet.GetRow(r);
                if (row == null) continue;
                var vals = new string[columns.Count];
                bool any = false;
                for (int i = 0; i < columns.Count; i++)
                {
                    string v = CellToString(row.GetCell(columns[i].Col), fmt);
                    vals[i] = v;
                    if (v.Length > 0) any = true;
                }
                if (!any) continue;
                ord++;
                records.Add((ord, vals));
            }

            string GV(string[] vals, string name) => headerToIdx.TryGetValue(name, out int i) ? vals[i] : "";

            // Filters (AND-combined). severity = exact-match set; checker/status = case-insensitive substring.
            var matched = records.Where(rec =>
            {
                if (severities.Count > 0 && !severities.Contains(GV(rec.Vals, CSeverity).Trim())) return false;
                if (checker != null && GV(rec.Vals, CCheckerKey).IndexOf(checker, StringComparison.OrdinalIgnoreCase) < 0) return false;
                if (status != null && GV(rec.Vals, CStatus).IndexOf(status, StringComparison.OrdinalIgnoreCase) < 0) return false;
                return true;
            }).ToList();

            var written = max.HasValue ? matched.Take(Math.Max(0, max.Value)).ToList() : matched;

            var utf8NoBom = new UTF8Encoding(false);
            var utf8Bom = new UTF8Encoding(true);

            // 1) Per-item markdown.
            var index = new StringBuilder();
            index.Append("md_file,ID,체커 키,위험도,파일명,라인,이슈 상태,체커명\n");
            foreach (var rec in written)
            {
                string id = GV(rec.Vals, CID);
                string checkerKey = GV(rec.Vals, CCheckerKey);
                string fileName = GV(rec.Vals, CFileName);
                string line = GV(rec.Vals, CLine);
                string idPart = id.Length > 0 ? id : rec.Ord.ToString("D5", CultureInfo.InvariantCulture);

                string mdName = San(idPart) + "_" + Cap(San(checkerKey), 40) + "_" + Cap(San(fileName), 40) + "_" + San(line) + ".md";
                File.WriteAllText(Path.Combine(itemsDir, mdName), BuildItemMd(rec.Vals, columns, GV), utf8NoBom);

                index.Append(string.Join(",", new[]
                {
                    CsvQuote("items/" + mdName), CsvQuote(id), CsvQuote(checkerKey), CsvQuote(GV(rec.Vals, CSeverity)),
                    CsvQuote(fileName), CsvQuote(line), CsvQuote(GV(rec.Vals, CStatus)), CsvQuote(GV(rec.Vals, CCheckerName)),
                })).Append('\n');
            }

            // 2) index.csv (WITH BOM so Excel renders Korean).
            File.WriteAllText(Path.Combine(outDir, "index.csv"), index.ToString(), utf8Bom);

            // 3) checkers.md worklist, unique 체커 키 sorted by count desc (then key asc for determinism).
            File.WriteAllText(Path.Combine(outDir, "checkers.md"), BuildCheckersMd(written, GV), utf8NoBom);

            // 4) Console summary.
            var sevCounts = written.GroupBy(rec => GV(rec.Vals, CSeverity))
                .Select(g => new { Sev = g.Key, C = g.Count() })
                .OrderByDescending(x => x.C).ThenBy(x => x.Sev, StringComparer.Ordinal).ToList();
            int uniqueCheckers = written.Select(rec => GV(rec.Vals, CCheckerKey)).Distinct(StringComparer.Ordinal).Count();

            if (log != null)
            {
                log.WriteLine("input:            " + inputFull);
                log.WriteLine("sheet:            " + sheet.SheetName + " (index " + sheetIdx.ToString(CultureInfo.InvariantCulture) + ", " + sheetPick + ")");
                log.WriteLine("columns:          " + columns.Count.ToString(CultureInfo.InvariantCulture));
                log.WriteLine("total data rows:  " + records.Count.ToString(CultureInfo.InvariantCulture));
                log.WriteLine("matched filters:  " + matched.Count.ToString(CultureInfo.InvariantCulture));
                log.WriteLine("written md files: " + written.Count.ToString(CultureInfo.InvariantCulture));
                log.WriteLine("unique checkers:  " + uniqueCheckers.ToString(CultureInfo.InvariantCulture));
                log.WriteLine("severity counts:  " + (sevCounts.Count == 0 ? "(none)" :
                    string.Join(" ", sevCounts.Select(x => (x.Sev.Length > 0 ? x.Sev : "(없음)") + ":" + x.C.ToString(CultureInfo.InvariantCulture)))));
                if (mergedRegions > 0) log.WriteLine("NOTE: sheet has " + mergedRegions.ToString(CultureInfo.InvariantCulture) + " merged region(s); only top-left cell values are read");
                if (matched.Count == 0) log.WriteLine("NOTE: 0 rows matched filters");
                log.WriteLine("output dir:       " + outDir);
            }

            return new ExportResult
            {
                InputPath = inputFull,
                OutputDir = outDir,
                SheetName = sheet.SheetName,
                SheetIndex = sheetIdx,
                SheetPick = sheetPick,
                Columns = columns.Count,
                TotalDataRows = records.Count,
                MatchedCount = matched.Count,
                WrittenCount = written.Count,
                UniqueCheckers = uniqueCheckers,
                SeverityCounts = sevCounts.Select(x => (x.Sev, x.C)).ToList(),
                MergedRegions = mergedRegions,
            };
        }

        private static string BuildItemMd(string[] vals, List<(string Header, int Col)> columns,
                                          Func<string[], string, string> gv)
        {
            string checkerKey = gv(vals, CCheckerKey);
            string fileName = gv(vals, CFileName);
            string line = gv(vals, CLine);

            var sb = new StringBuilder();
            sb.Append("# ").Append(checkerKey).Append(" @ ").Append(fileName).Append(':').Append(line).Append("\n\n");
            sb.Append("| 필드 | 값 |\n|---|---|\n");
            for (int i = 0; i < columns.Count; i++)
            {
                string h = columns[i].Header;
                if (h == CSource || h == CDesc) continue;   // these get their own verbatim sections below
                string v = vals[i];
                if (v.Length == 0) continue;
                sb.Append("| ").Append(TableCell(h)).Append(" | ").Append(TableCell(v)).Append(" |\n");
            }

            string desc = gv(vals, CDesc);
            sb.Append("\n## 체커 설명\n");
            sb.Append(desc);
            if (!desc.EndsWith("\n", StringComparison.Ordinal)) sb.Append('\n');

            string src = gv(vals, CSource);
            // 대상 라인 강조: 소스 스니펫의 라인번호 접두("  96:" 또는 "  96.")가 검출 라인과 같은 줄에 마커를 붙인다.
            bool lineMarked = false;
            string targetLineText = "";
            if (int.TryParse(line.Trim(), out int targetLine) && targetLine > 0)
            {
                var reLine = new System.Text.RegularExpressions.Regex(@"(?m)^(\s*" + targetLine + @"[\.:][^\r\n]*)");
                if (reLine.IsMatch(src))
                {
                    var match = reLine.Match(src);
                    targetLineText = match.Groups[1].Value.TrimEnd();
                    src = reLine.Replace(src, "$1    <<< TARGET LINE " + targetLine + " - FIX THIS LINE >>>", 1);
                    lineMarked = true;
                }
            }

            sb.Append("\n## 수정 대상\n");
            if (line.Trim().Length > 0)
            {
                sb.Append("- 파일: `").Append(fileName).Append("`\n");
                sb.Append("- 라인: `").Append(line.Trim()).Append("`\n");
                sb.Append("- 지시: **이 라인과 이 라인에서 직접 드러난 결함만 수정한다. 주변 문맥은 판단용이며 임의 수정 금지.**\n");
                if (targetLineText.Length > 0)
                {
                    sb.Append("- 대상 코드: `").Append(InlineCode(targetLineText)).Append("`\n");
                }
            }
            else
            {
                sb.Append("- 라인 정보 없음: 소스 스니펫과 파일 문맥을 확인한 뒤 실제 검출 위치를 먼저 특정한다.\n");
            }

            string fence = src.Contains("```") ? "````" : "```";   // escape source that itself contains a fence
            sb.Append("\n## 소스 코드\n");
            if (line.Trim().Length > 0)
            {
                sb.Append("> ⚠️ **수정 대상 = 라인 ").Append(line.Trim()).Append("**");
                sb.Append(lineMarked
                    ? " (아래 소스의 `TARGET LINE` 표시). 그 라인만 고치고, 표시 없는 다른 라인은 임의로 수정하지 마라.\n\n"
                    : ". 이 라인만 고치고, 다른 라인은 임의로 수정하지 마라.\n\n");
            }
            sb.Append(fence).Append("text\n");
            sb.Append(src);
            if (!src.EndsWith("\n", StringComparison.Ordinal)) sb.Append('\n');
            sb.Append(fence).Append('\n');
            return sb.ToString();
        }

        private static string BuildCheckersMd(IEnumerable<(int Ord, string[] Vals)> written, Func<string[], string, string> gv)
        {
            var groups = written
                .GroupBy(rec => gv(rec.Vals, CCheckerKey), StringComparer.Ordinal)
                .Select(g => new
                {
                    Key = g.Key,
                    Count = g.Count(),
                    Name = g.Select(r => gv(r.Vals, CCheckerName)).FirstOrDefault(s => s.Length > 0) ?? "",
                    Desc = g.Select(r => gv(r.Vals, CDesc)).FirstOrDefault(s => s.Length > 0) ?? "",
                    Sev = g.GroupBy(r => gv(r.Vals, CSeverity)).Select(sg => new { S = sg.Key, C = sg.Count() })
                           .OrderByDescending(x => x.C).ThenBy(x => x.S, StringComparer.Ordinal).ToList(),
                })
                .OrderByDescending(x => x.Count).ThenBy(x => x.Key, StringComparer.Ordinal)
                .ToList();

            var sb = new StringBuilder();
            sb.Append("# 체커별 요약 (해결방안 작성용 워크리스트)\n\n");
            foreach (var g in groups)
            {
                sb.Append("## ").Append(g.Key.Length > 0 ? g.Key : "(빈 체커 키)").Append("\n\n");
                sb.Append("- 건수: ").Append(g.Count.ToString(CultureInfo.InvariantCulture)).Append('\n');
                sb.Append("- 체커명: ").Append(OneLine(g.Name)).Append('\n');
                sb.Append("- 위험도 분포: ").Append(string.Join(" ", g.Sev.Select(x =>
                    (x.S.Length > 0 ? x.S : "(없음)") + ":" + x.C.ToString(CultureInfo.InvariantCulture)))).Append('\n');
                sb.Append("- 체커 설명: ").Append(OneLine(g.Desc)).Append("\n\n");
                sb.Append("- [ ] 해결방안 작성\n\n");
            }
            return sb.ToString();
        }

        // --- cell -> string ---
        private static string CellToString(ICell? cell, DataFormatter fmt)
        {
            if (cell == null) return "";
            switch (cell.CellType)
            {
                case CellType.String: return cell.StringCellValue ?? "";
                case CellType.Boolean: return cell.BooleanCellValue ? "true" : "false";
                case CellType.Numeric: return NumericToString(cell);
                case CellType.Formula:
                    switch (cell.CachedFormulaResultType)
                    {
                        case CellType.String: return cell.StringCellValue ?? "";
                        case CellType.Boolean: return cell.BooleanCellValue ? "true" : "false";
                        case CellType.Numeric: return NumericToString(cell);
                        default:
                            try { return fmt.FormatCellValue(cell) ?? ""; } catch { return ""; }
                    }
                default: return "";   // Blank / Error / Unknown
            }
        }

        private static string NumericToString(ICell cell)
        {
            if (DateUtil.IsCellDateFormatted(cell))
            {
                // Date-formatted numeric: render deterministically (invariant) rather than as a raw serial.
                DateTime dt = cell.DateCellValue ?? DateTime.MinValue;
                return dt.TimeOfDay == TimeSpan.Zero
                    ? dt.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)
                    : dt.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
            }
            double d = cell.NumericCellValue;
            // Integral values render without a trailing ".0" (ID/라인 must be 6464794, not 6464794.0).
            if (!double.IsNaN(d) && !double.IsInfinity(d) && d == Math.Truncate(d) && Math.Abs(d) < 9.007199254740992e15)
                return ((long)d).ToString(CultureInfo.InvariantCulture);
            return d.ToString("R", CultureInfo.InvariantCulture);
        }

        // --- helpers ---
        private static string San(string s)
        {
            char[] invalid = Path.GetInvalidFileNameChars();
            var sb = new StringBuilder(s.Length);
            foreach (char ch in s)
                sb.Append(ch == ' ' || Array.IndexOf(invalid, ch) >= 0 ? '-' : ch);
            return sb.ToString();
        }

        private static string Cap(string s, int n) => s.Length <= n ? s : s.Substring(0, n);

        // Table cell: escape pipe, collapse newlines to <br> so the row stays a single markdown line.
        private static string TableCell(string s) =>
            s.Replace("|", "\\|").Replace("\r\n", "<br>").Replace("\n", "<br>").Replace("\r", "<br>");

        private static string OneLine(string s) =>
            s.Replace("\r\n", " ").Replace("\n", " ").Replace("\r", " ").Trim();

        private static string InlineCode(string s) =>
            s.Replace("`", "'");

        private static string CsvQuote(string s) =>
            s.IndexOfAny(new[] { ',', '"', '\n', '\r' }) >= 0 ? "\"" + s.Replace("\"", "\"\"") + "\"" : s;
    }
}
