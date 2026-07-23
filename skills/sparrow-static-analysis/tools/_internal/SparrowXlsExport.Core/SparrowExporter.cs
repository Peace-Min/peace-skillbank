// SparrowXlsExport.Core: deterministic parsing library that reads a Sparrow (파수 정적분석) result .xls
// (real BIFF/OLE2, or .xlsx) WITHOUT Excel/COM, and splits it into per-item markdown + an index + a
// per-checker worklist. Shared by the console tool (thin CLI wrapper) and the WPF GUI (in-process).
//
// Design points baked in:
//  - GENERIC header mapping: whatever headers exist become table columns; a fixed set of Sparrow columns
//    is treated as WELL-KNOWN only for filenames/index/summary (ID / 체커 키 / 체커명 / 위험도 / 파일명 /
//    라인 / 이슈 상태 / 체커 설명 / 소스 코드 / 경로).
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

        /// <summary>Source root used to resolve relative XLS paths and relative files-from entries.</summary>
        public string? RootPath;

        /// <summary>CSV/newline list of selected source files. When set, rows outside this file set are skipped.</summary>
        public string? FilesFrom;
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

        /// <summary>
        /// True when scope filtering (FilesFrom) was active with a non-empty selection over a non-empty xls,
        /// yet NOTHING matched (Tier-1 absolute AND Tier-2 relative-tail both failed for every row). This is the
        /// tell-tale "wrong project / different checkout path structure" situation — distinct from a legitimate
        /// selection that genuinely has zero findings.
        /// </summary>
        public bool ScopeMismatch;

        /// <summary>Actionable Korean diagnostic ([범위 불일치] block) when <see cref="ScopeMismatch"/>; else null.</summary>
        public string? ScopeDiagnostic;

        /// <summary>Softer Korean note ([범위 경고]) when some rows were kept via an AMBIGUOUS Tier-2 relative-tail
        /// over-match (matched more than one distinct selected file); null when no ambiguous matches occurred.</summary>
        public string? ScopeAmbiguousWarning;
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
        private const string CPath = "경로";   // full source path (dir+file); disambiguates same-named files across projects

        // Columns dropped from the per-item 필드 table: constant across the whole codebase
        // (보안약점 / C# / SEMANTIC / 미확인), or workflow/bookkeeping metadata that carries no signal for the
        // fix decision (A.S / 이슈 담당자 / 검출 시간 / 유사 이슈 그룹 / 레퍼런스). Both groups only add tokens to
        // the request md the worker reads. Explicit exclusion set so any future xls column keeps rendering by default.
        private static readonly HashSet<string> TableExcludedColumns = new HashSet<string>(StringComparer.Ordinal)
        {
            "유형", "언어", "체커 타입", "이슈 상태",
            "A.S", "이슈 담당자", "검출 시간", "유사 이슈 그룹", "레퍼런스",
        };

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

            var scopedRecords = records;
            SourceScopeMatcher? scopeMatcher = SourceScopeMatcher.Create(opts.RootPath, opts.FilesFrom);
            if (scopeMatcher != null)
            {
                scopedRecords = records.Where(rec => scopeMatcher.Keep(GV(rec.Vals, CPath), GV(rec.Vals, CFileName))).ToList();
            }

            // Scope diagnostics: distinguish a total path-structure mismatch (0 kept from a non-empty selection over a
            // non-empty xls — the cross-PC "wrong checkout root" case) from a legitimate zero-finding selection, and
            // surface an ambiguous Tier-2 over-match note. Populated on ExportResult for the CLI (stderr) and GUI (log).
            string? scopeDiagnostic = null;
            string? scopeAmbiguousWarning = null;
            scopeMatcher?.BuildDiagnostics(records.Count, out scopeDiagnostic, out scopeAmbiguousWarning);

            // Filters (AND-combined). Scope is applied first; severity = exact-match set; checker/status = case-insensitive substring.
            var matched = scopedRecords.Where(rec =>
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
            // 경로 is appended as the LAST column (existing columns keep their positions so name/index-based
            // consumers are unaffected). It carries the xls '경로' full path for full-path finding identity
            // (G2 gate); empty string when the xls has no 경로 column.
            index.Append("md_file,ID,체커 키,위험도,파일명,라인,이슈 상태,체커명,경로\n");
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
                    CsvQuote(GV(rec.Vals, CPath)),
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
                ScopeMismatch = scopeDiagnostic != null,
                ScopeDiagnostic = scopeDiagnostic,
                ScopeAmbiguousWarning = scopeAmbiguousWarning,
            };
        }

        // Cross-PC scope filter. The collaboration model is ONE authoritative Sparrow xls (paths from PC-A's
        // checkout, e.g. D:\Work\OSTES\...) whose findings a team divides by file; each teammate selects files
        // from their OWN checkout at their OWN root (e.g. C:\myproj\OSTES\...). So matching MUST be drive/prefix-
        // independent. Three tiers, applied in order per row:
        //   Tier 1 — absolute exact (same-PC, fastest): any BuildCandidates() absolute path is in _selected.
        //   Tier 2 — relative-tail (cross-PC): the xls 경로 ENDS WITH a selected file's path-relative-to-_root at a
        //            directory boundary (full relative tail, not just basename, to minimize over-match).
        //   Tier 3 — empty-경로 basename fallback: only when the xls 경로 is empty AND the basename is unique both in
        //            the selection and under _root.
        private sealed class SourceScopeMatcher
        {
            private readonly string? _root;
            private readonly HashSet<string> _selected;
            private readonly Dictionary<string, List<string>> _byName;
            private readonly Dictionary<string, List<string>> _allByName;

            // Tier 2 index: normalized (separator + case folded) relative tail -> selected absolute paths that
            // produced it. A tail keyed to >1 selected path, or one row hitting >1 tail, is an ambiguous over-match.
            private readonly Dictionary<string, List<string>> _relTailMap;
            private readonly List<string> _relTailDisplay = new List<string>();   // original-case tails, for diagnostics

            // Outcome accounting across the whole run (Keep is called once per data row).
            private int _examined;        // rows the scope filter looked at
            private int _kept;            // rows kept by any tier
            private int _ambiguousKept;   // rows kept via an AMBIGUOUS Tier-2 match (>=2 distinct tails)
            private readonly List<string> _sampleXlsPaths = new List<string>();   // first couple non-empty 경로 values

            private SourceScopeMatcher(string? root, HashSet<string> selected, IEnumerable<string> allSourceFiles)
            {
                _root = root;
                _selected = selected;
                _byName = selected
                    .GroupBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase)
                    .ToDictionary(g => g.Key ?? "", g => g.ToList(), StringComparer.OrdinalIgnoreCase);
                _allByName = allSourceFiles
                    .GroupBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase)
                    .ToDictionary(g => g.Key ?? "", g => g.ToList(), StringComparer.OrdinalIgnoreCase);

                // Precompute the relative-tail -> selected map once. Only files genuinely UNDER _root yield a clean
                // relative tail; anything outside (rooted elsewhere / .. traversal) is skipped for Tier 2.
                _relTailMap = new Dictionary<string, List<string>>(StringComparer.Ordinal);
                if (_root != null)
                {
                    foreach (string sel in selected)
                    {
                        string? tail = GetRelativeTail(_root, sel);
                        if (tail == null) continue;
                        string norm = NormalizeTail(tail);
                        if (norm.Length == 0) continue;
                        if (!_relTailMap.TryGetValue(norm, out List<string>? list))
                        {
                            list = new List<string>();
                            _relTailMap[norm] = list;
                            _relTailDisplay.Add(tail);
                        }
                        list.Add(sel);
                    }
                }
            }

            public static SourceScopeMatcher? Create(string? rootPath, string? filesFrom)
            {
                if (string.IsNullOrWhiteSpace(filesFrom)) return null;
                string filesFromFull = Path.GetFullPath(filesFrom.Trim().Trim('"'));
                if (!File.Exists(filesFromFull)) throw new FileNotFoundException("files-from not found: " + filesFromFull);

                string? root = string.IsNullOrWhiteSpace(rootPath) ? null : Path.GetFullPath(rootPath.Trim().Trim('"'));
                var selected = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (string entry in ReadFilesFrom(filesFromFull))
                {
                    if (string.IsNullOrWhiteSpace(entry)) continue;
                    string full = Path.IsPathRooted(entry)
                        ? Path.GetFullPath(entry)
                        : Path.GetFullPath(Path.Combine(root ?? Directory.GetCurrentDirectory(), entry));
                    if (full.EndsWith(".cs", StringComparison.OrdinalIgnoreCase))
                    {
                        selected.Add(full);
                    }
                }

                IEnumerable<string> allSourceFiles = root != null && Directory.Exists(root)
                    ? EnumerateCsFiles(root)
                    : selected;
                return new SourceScopeMatcher(root, selected, allSourceFiles);
            }

            public bool Keep(string pathCell, string fileNameCell)
            {
                _examined++;
                string fileName = (fileNameCell ?? "").Trim();
                string path = (pathCell ?? "").Trim();
                RecordSampleXlsPath(path);

                // Tier 1 — absolute exact (same-PC).
                foreach (string candidate in BuildCandidates(path, fileName))
                {
                    if (_selected.Contains(candidate)) { _kept++; return true; }
                }

                // Tier 2 — relative-tail (cross-PC). Requires _root; skipped when 경로 is empty.
                if (TryMatchRelativeTail(path, out bool ambiguous))
                {
                    _kept++;
                    if (ambiguous) _ambiguousKept++;
                    return true;
                }

                // Tier 3 — empty-경로 basename fallback (unchanged): basename unique in selection AND under root.
                if (path.Length == 0 && fileName.Length > 0 &&
                    _byName.TryGetValue(Path.GetFileName(fileName), out List<string>? sameName) &&
                    sameName.Count == 1 &&
                    _allByName.TryGetValue(Path.GetFileName(fileName), out List<string>? sameNameInRoot) &&
                    sameNameInRoot.Count == 1)
                {
                    _kept++;
                    return true;
                }

                return false;
            }

            // Tier 2: does the xls 경로 end with any selected file's full relative-to-root tail, at a directory
            // boundary? A boundary means the whole normalized path equals the tail, or the char just before the tail
            // is a separator — so tail "View\Foo.cs" matches "...\View\Foo.cs" and "...\SubView\View\Foo.cs" but NOT
            // "...\OtherView\Foo.cs". Sets ambiguous=true (still a match — fail open) when the row hits >=2 distinct
            // selected tails, i.e. the finding could belong to more than one selected file.
            private bool TryMatchRelativeTail(string path, out bool ambiguous)
            {
                ambiguous = false;
                if (_root == null || _relTailMap.Count == 0 || path.Length == 0) return false;

                string norm = NormalizeTail(path);
                int matchedTails = 0;
                foreach (string tail in _relTailMap.Keys)
                {
                    if (norm.Length < tail.Length) continue;
                    if (norm.Equals(tail, StringComparison.Ordinal) ||
                        norm.EndsWith(Path.DirectorySeparatorChar + tail, StringComparison.Ordinal))
                    {
                        matchedTails++;
                        if (matchedTails >= 2) break;
                    }
                }

                if (matchedTails == 0) return false;
                ambiguous = matchedTails >= 2;
                return true;
            }

            private void RecordSampleXlsPath(string path)
            {
                if (path.Length == 0 || _sampleXlsPaths.Count >= 2) return;
                if (!_sampleXlsPaths.Contains(path, StringComparer.OrdinalIgnoreCase)) _sampleXlsPaths.Add(path);
            }

            // Full relative tail of a selected absolute path under root (original case, separators preserved), or null
            // when it is not genuinely under root (rooted elsewhere / different drive / .. traversal).
            private static string? GetRelativeTail(string root, string selected)
            {
                string relative;
                try { relative = Path.GetRelativePath(root, selected); }
                catch { return null; }
                if (string.IsNullOrEmpty(relative) || relative == ".") return null;
                if (Path.IsPathRooted(relative)) return null;   // GetRelativePath returns absolute when on another drive
                if (relative == ".." ||
                    relative.StartsWith(".." + Path.DirectorySeparatorChar, StringComparison.Ordinal) ||
                    relative.StartsWith("../", StringComparison.Ordinal))
                    return null;
                return relative;
            }

            // Normalize a path/tail for cross-PC comparison: fold '/' and '\' to the platform separator and lowercase
            // (Windows paths are case-insensitive). Used for both the tail keys and the xls 경로 at match time.
            private static string NormalizeTail(string s)
            {
                return s.Replace('/', Path.DirectorySeparatorChar)
                        .Replace('\\', Path.DirectorySeparatorChar)
                        .Trim()
                        .ToLowerInvariant();
            }

            // Build the run-level scope diagnostics. mismatch = the actionable [범위 불일치] block emitted ONLY for a
            // total zero-match under a non-empty selection over a non-empty xls (the cross-PC wrong-root case);
            // ambiguousWarning = the softer [범위 경고] note when some rows were kept via ambiguous Tier-2 over-match.
            public void BuildDiagnostics(int totalDataRows, out string? mismatch, out string? ambiguousWarning)
            {
                mismatch = null;
                ambiguousWarning = null;

                if (_selected.Count > 0 && _examined > 0 && _kept == 0)
                {
                    string xlsEx = _sampleXlsPaths.Count > 0 ? string.Join("  |  ", _sampleXlsPaths) : "(경로 없음)";
                    string selEx = _relTailDisplay.Count > 0
                        ? string.Join("  |  ", _relTailDisplay.Take(2))
                        : "(상대경로 없음)";
                    mismatch =
                        "[범위 불일치] 선택한 소스(" + (_root ?? "(root 미지정)") + ")의 상대경로가 이 xls의 검출 경로와 하나도 "
                        + "일치하지 않습니다. 같은 프로젝트의 다른 체크아웃인지, 선택 폴더가 맞는지 확인하세요. "
                        + "(xls 검출 " + totalDataRows.ToString(CultureInfo.InvariantCulture) + "건 중 0건 매칭)\n"
                        + "  xls 예: " + xlsEx + "   /   선택 예: " + selEx;
                }

                if (_ambiguousKept > 0)
                {
                    ambiguousWarning =
                        "[범위 경고] 상대경로가 여러 선택 파일과 겹치는 검출 "
                        + _ambiguousKept.ToString(CultureInfo.InvariantCulture) + "건은 포함했습니다.";
                }
            }

            private IEnumerable<string> BuildCandidates(string path, string fileName)
            {
                if (path.Length == 0) yield break;

                string normalizedPath = path.Replace('/', Path.DirectorySeparatorChar).Trim();
                var rawCandidates = new List<string>();

                if (Path.IsPathRooted(normalizedPath))
                {
                    rawCandidates.Add(normalizedPath);
                    if (fileName.Length > 0) rawCandidates.Add(Path.Combine(normalizedPath, fileName));
                }
                else if (_root != null)
                {
                    rawCandidates.Add(Path.Combine(_root, normalizedPath));
                    if (fileName.Length > 0) rawCandidates.Add(Path.Combine(_root, normalizedPath, fileName));
                }

                foreach (string raw in rawCandidates)
                {
                    string full;
                    try
                    {
                        full = Path.GetFullPath(raw);
                    }
                    catch
                    {
                        continue;
                    }

                    if (_root != null && !IsUnderRoot(full, _root)) continue;
                    yield return full;
                }
            }

            private static bool IsUnderRoot(string path, string root)
            {
                string rootWithSlash = root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                                      + Path.DirectorySeparatorChar;
                string full = path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                return full.Equals(root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar), StringComparison.OrdinalIgnoreCase)
                       || full.StartsWith(rootWithSlash, StringComparison.OrdinalIgnoreCase);
            }

            private static IEnumerable<string> ReadFilesFrom(string path)
            {
                List<string[]> rows = ParseCsv(File.ReadAllText(path));
                if (rows.Count == 0) yield break;

                int col = PickColumn(rows[0]);
                int start = IsHeader(rows[0], col) ? 1 : 0;
                for (int i = start; i < rows.Count; i++)
                {
                    if (col >= rows[i].Length) continue;
                    string value = rows[i][col].Trim();
                    if (value.Length > 0) yield return value;
                }
            }

            private static IEnumerable<string> EnumerateCsFiles(string root)
            {
                var stack = new Stack<string>();
                stack.Push(root);
                while (stack.Count > 0)
                {
                    string dir = stack.Pop();
                    IEnumerable<string> files;
                    try
                    {
                        files = Directory.EnumerateFiles(dir, "*.cs", SearchOption.TopDirectoryOnly).ToList();
                    }
                    catch
                    {
                        files = Array.Empty<string>();
                    }

                    foreach (string file in files)
                    {
                        string full;
                        try { full = Path.GetFullPath(file); }
                        catch { continue; }
                        yield return full;
                    }

                    IEnumerable<string> dirs;
                    try
                    {
                        dirs = Directory.EnumerateDirectories(dir).ToList();
                    }
                    catch
                    {
                        dirs = Array.Empty<string>();
                    }

                    foreach (string child in dirs)
                    {
                        stack.Push(child);
                    }
                }
            }

            private static int PickColumn(string[] header)
            {
                string[] names = { "파일명", "경로", "path", "filepath", "file", "fullpath" };
                foreach (string name in names)
                {
                    for (int i = 0; i < header.Length; i++)
                    {
                        if (string.Equals(header[i].Trim(), name, StringComparison.OrdinalIgnoreCase)) return i;
                    }
                }

                return 0;
            }

            private static bool IsHeader(string[] row, int col)
            {
                if (col < 0 || col >= row.Length) return false;
                string cell = row[col].Trim();
                return string.Equals(cell, "파일명", StringComparison.OrdinalIgnoreCase)
                       || string.Equals(cell, "경로", StringComparison.OrdinalIgnoreCase)
                       || string.Equals(cell, "path", StringComparison.OrdinalIgnoreCase)
                       || string.Equals(cell, "filepath", StringComparison.OrdinalIgnoreCase)
                       || string.Equals(cell, "file", StringComparison.OrdinalIgnoreCase)
                       || string.Equals(cell, "fullpath", StringComparison.OrdinalIgnoreCase);
            }

            private static List<string[]> ParseCsv(string text)
            {
                var rows = new List<string[]>();
                var row = new List<string>();
                var cell = new StringBuilder();
                bool quoted = false;

                for (int i = 0; i < text.Length; i++)
                {
                    char ch = text[i];
                    if (quoted)
                    {
                        if (ch == '"')
                        {
                            if (i + 1 < text.Length && text[i + 1] == '"')
                            {
                                cell.Append('"');
                                i++;
                            }
                            else
                            {
                                quoted = false;
                            }
                        }
                        else
                        {
                            cell.Append(ch);
                        }
                    }
                    else
                    {
                        if (ch == '"') quoted = true;
                        else if (ch == ',')
                        {
                            row.Add(cell.ToString());
                            cell.Clear();
                        }
                        else if (ch == '\r' || ch == '\n')
                        {
                            if (ch == '\r' && i + 1 < text.Length && text[i + 1] == '\n') i++;
                            row.Add(cell.ToString());
                            rows.Add(row.ToArray());
                            row.Clear();
                            cell.Clear();
                        }
                        else
                        {
                            cell.Append(ch);
                        }
                    }
                }

                if (cell.Length > 0 || row.Count > 0)
                {
                    row.Add(cell.ToString());
                    rows.Add(row.ToArray());
                }

                return rows;
            }
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
                if (TableExcludedColumns.Contains(h)) continue;   // constant/no-signal columns
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
                    src = reLine.Replace(src, "$1    <<< TARGET LINE " + targetLine + " - ANCHOR >>>", 1);
                    lineMarked = true;
                }
            }

            sb.Append("\n## 수정 대상\n");
            if (line.Trim().Length > 0)
            {
                sb.Append("- 파일: `").Append(fileName).Append("`\n");
                sb.Append("- 라인: `").Append(line.Trim()).Append("`\n");
                sb.Append("- 지시: **이 라인은 수정 기준점(anchor)이다. 결함 제거에 필요한 최소 인접 범위까지 수정하되, 무관한 주변 코드는 임의 수정하지 않는다.**\n");
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
                // 앵커 문구는 '기준점'이지 '단일 라인 수정 지시'가 아니다. 자원 누수/상수 추출처럼 결함 제거에
                // 여러 줄이 필요한 수정을 "그 라인만 고치라"는 제약으로 읽고 무의미한 1줄 교체를 하거나 아예
                // 포기(문맥 필요)하는 경로를 막기 위해, 작업 규칙 3(최소 인접 범위 허용)과 문구를 일치시킨다.
                sb.Append("> ⚠️ **수정 기준점 = 라인 ").Append(line.Trim()).Append(".**");
                if (lineMarked) sb.Append(" (아래 소스의 `TARGET LINE` 표시)");
                sb.Append(" 결함 제거에 필요한 최소 인접 범위(감싸는 블록·try/finally·선언부)까지는 수정 가능하며, 결함과 무관한 다른 코드는 수정하지 마십시오. 범위 제약을 수정 불가 사유로 삼지 마십시오.\n\n");
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
