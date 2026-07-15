// SparrowXlsExport.Core.TriagePreparer: deterministic reproduction of Run-Triage.ps1 `prepare`.
//
// Reads index.csv (UTF-8 with BOM; header md_file,ID,체커 키,위험도,파일명,라인,이슈 상태,체커명), and for
// each row resolves the checker guide <GuidesDir>\<체커 키>.md (join on the verbatim 체커 키 column). If the
// guide is present it writes a self-contained requests\{ID}_{체커키}.md (the triage prompt with {{GUIDE}} and
// {{ITEM}} substituted), else it records the row in unresolved.csv. Also writes worklist.csv and creates an
// empty verdicts\ folder.
//
// BYTE-IDENTICAL contract vs Run-Triage.ps1 prepare (PS is the reference — do not diverge):
//  - request filename: {Get-SafeName idPart}_{Get-SafeName 체커키}.md
//  - worklist header:   id,체커키,위험도,파일명,라인,item_md,guide,상태   (rows end in ,TODO)
//  - unresolved header: id,체커키,위험도,파일명,라인,item_md,사유
//  - ordering: index.csv row order preserved (stable), ordinal = 1-based data-row position
//  - idPart: trimmed ID, or ordinal.ToString("D5") when the ID cell is blank
//  - item_md in worklist uses forward slash: requests/{name}; guide column is the Join-Path result (\)
//  - encodings: all outputs UTF-8 WITHOUT BOM, LF line endings; every CSV ends with a trailing LF
//  - NULL_RETURN_STD guide gets the dotnet-contracts\null-return-std.md contract table appended (if present)
//  - reads guide/item/prompt with Read-TextNoBom semantics (decode UTF-8, strip a single leading U+FEFF)

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace SparrowXlsExport.Core
{
    /// <summary>Inputs for a single triage-prepare run. Mirrors Run-Triage.ps1 prepare parameters.</summary>
    public sealed class PrepareOptions
    {
        /// <summary>Path to index.csv (UTF-8 with BOM; produced by <see cref="SparrowExporter"/>). Required.</summary>
        public string IndexCsvPath = "";

        /// <summary>Directory holding the per-item md files referenced by index.csv's md_file column. Required.</summary>
        public string ItemsDir = "";

        /// <summary>Directory holding the checker guides &lt;체커 키&gt;.md (references\checkers). Required.</summary>
        public string GuidesDir = "";

        /// <summary>Path to the triage-prompt.md template ({{GUIDE}}/{{ITEM}} placeholders). Required.</summary>
        public string PromptPath = "";

        /// <summary>Output directory; gets requests\, worklist.csv, unresolved.csv, empty verdicts\. Required.</summary>
        public string OutDir = "";

        /// <summary>Exact-match filter on 체커 키; null =&gt; no checker filter.</summary>
        public string? Checker;

        /// <summary>Comma-separated severity set (each trimmed); null/empty =&gt; no severity filter.</summary>
        public string? Severity;

        /// <summary>Cap on requests+unresolved among filter-passing rows; null =&gt; no cap.</summary>
        public int? Max;
    }

    /// <summary>Structured result of a triage-prepare run (counts mirror the PS Write-Host summary).</summary>
    public sealed class PrepareResult
    {
        public int RequestCount;
        public int UnresolvedCount;
        /// <summary>Per-checker request counts, ordered count desc then key asc (PS summary order).</summary>
        public IReadOnlyList<(string Checker, int Count)> PerChecker = Array.Empty<(string, int)>();
        public string OutDir = "";
    }

    /// <summary>Deterministic index.csv -&gt; triage requests preparer. Byte-identical to Run-Triage.ps1 prepare.</summary>
    public static class TriagePreparer
    {
        /// <summary>
        /// Reproduce Run-Triage.ps1 prepare exactly: emit requests\{ID}_{체커키}.md (guide+item merged into the
        /// prompt), worklist.csv, unresolved.csv, and an empty verdicts\ folder. Optionally streams the same
        /// human summary lines the PS version prints to <paramref name="log"/>.
        /// </summary>
        public static PrepareResult Prepare(PrepareOptions opts, TextWriter? log = null)
        {
            if (string.IsNullOrEmpty(opts.IndexCsvPath)) throw new ArgumentException("prepare: IndexCsvPath 필요");
            if (string.IsNullOrEmpty(opts.ItemsDir)) throw new ArgumentException("prepare: ItemsDir 필요");
            if (string.IsNullOrEmpty(opts.GuidesDir)) throw new ArgumentException("prepare: GuidesDir 필요");
            if (string.IsNullOrEmpty(opts.OutDir)) throw new ArgumentException("prepare: OutDir 필요");

            if (!File.Exists(opts.IndexCsvPath)) throw new FileNotFoundException("index.csv 없음: " + opts.IndexCsvPath);
            if (!Directory.Exists(opts.ItemsDir)) throw new DirectoryNotFoundException("items 폴더 없음: " + opts.ItemsDir);
            if (!Directory.Exists(opts.GuidesDir)) throw new DirectoryNotFoundException("checkers(가이드) 폴더 없음: " + opts.GuidesDir);
            if (string.IsNullOrEmpty(opts.PromptPath)) throw new ArgumentException("prepare: PromptPath 필요");
            if (!File.Exists(opts.PromptPath)) throw new FileNotFoundException("프롬프트 템플릿 없음: " + opts.PromptPath);

            string promptTemplate = ReadTextNoBom(opts.PromptPath);

            var sevSet = new List<string>();
            if (!string.IsNullOrEmpty(opts.Severity))
                sevSet = opts.Severity.Split(',').Select(x => x.Trim()).Where(x => x.Length > 0).ToList();

            // 출력 폴더 준비(멱등: prepare 산출물만 초기화, verdicts\는 보존).
            Directory.CreateDirectory(opts.OutDir);
            string reqDir = Path.Combine(opts.OutDir, "requests");
            if (Directory.Exists(reqDir)) Directory.Delete(reqDir, recursive: true);
            Directory.CreateDirectory(reqDir);
            string verDir = Path.Combine(opts.OutDir, "verdicts");
            Directory.CreateDirectory(verDir);   // 입력 폴더 — 있으면 보존

            var rows = ReadCsvNoBom(opts.IndexCsvPath);

            var worklist = new List<string> { "id,체커키,위험도,파일명,라인,item_md,guide,상태" };
            var unresolved = new List<string> { "id,체커키,위험도,파일명,라인,item_md,사유" };

            int requestCount = 0;
            int unresolvedCount = 0;
            var perChecker = new Dictionary<string, int>(StringComparer.Ordinal);
            int ordinal = 0;

            foreach (var row in rows)
            {
                ordinal++;
                string id = Field(row, "ID");
                string checkerKey = Field(row, "체커 키");
                string sev = Field(row, "위험도");
                string file = Field(row, "파일명");
                string line = Field(row, "라인");
                string mdField = Field(row, "md_file");

                // 필터(AND). checker=정확 일치(체커 키), severity=집합 포함.
                if (opts.Checker != null && checkerKey != opts.Checker) continue;
                if (sevSet.Count > 0 && !sevSet.Contains(sev.Trim())) continue;
                // Max caps the number of processed items (requests + unresolved) among the filtered rows,
                // matching Run-Triage.ps1 prepare (guard: `$Max -gt 0`). Break before processing the (Max+1)th.
                if (opts.Max is int _max && _max > 0 && requestCount + unresolvedCount >= _max) break;

                string idPart = id.Trim().Length > 0 ? id.Trim() : ordinal.ToString("D5", CultureInfo.InvariantCulture);
                string itemLeaf = mdField.Length > 0 ? LeafName(mdField) : "";
                string itemPath = itemLeaf.Length > 0 ? Path.Combine(opts.ItemsDir, itemLeaf) : "";

                string guidePath = JoinPathPwsh(opts.GuidesDir, checkerKey + ".md");

                if (checkerKey.Length == 0 || !File.Exists(guidePath))
                {
                    unresolvedCount++;
                    string reason = checkerKey.Length == 0 ? "체커 키 없음" : "가이드 없음(Track A/B 또는 무가이드)";
                    unresolved.Add(string.Join(",", new[]
                    {
                        CsvField(idPart), CsvField(checkerKey), CsvField(sev),
                        CsvField(file), CsvField(line), CsvField(itemLeaf), CsvField(reason),
                    }));
                    continue;
                }

                if (itemPath.Length == 0 || !File.Exists(itemPath))
                {
                    unresolvedCount++;
                    unresolved.Add(string.Join(",", new[]
                    {
                        CsvField(idPart), CsvField(checkerKey), CsvField(sev),
                        CsvField(file), CsvField(line), CsvField(itemLeaf), CsvField("항목 md 없음: " + itemLeaf),
                    }));
                    continue;
                }

                string guideText = ReadTextNoBom(guidePath);
                if (checkerKey == "NULL_RETURN_STD")
                {
                    string contractPath = JoinPathPwsh(ParentDir(opts.GuidesDir), "dotnet-contracts\\null-return-std.md");
                    if (File.Exists(contractPath))
                    {
                        guideText = guideText + "\n\n---\n\n## [추가 계약표: .NET null-return API]\n\n" + ReadTextNoBom(contractPath);
                    }
                }
                string itemText = ReadTextNoBom(itemPath);

                // 자리표시자 치환(리터럴, 정규식 아님).
                string reqText = promptTemplate.Replace("{{GUIDE}}", guideText).Replace("{{ITEM}}", itemText);

                string reqName = SafeName(idPart) + "_" + SafeName(checkerKey) + ".md";
                string reqPath = Path.Combine(reqDir, reqName);
                WriteUtf8Lf(reqPath, reqText);
                requestCount++;
                perChecker[checkerKey] = perChecker.TryGetValue(checkerKey, out int c) ? c + 1 : 1;

                worklist.Add(string.Join(",", new[]
                {
                    CsvField(idPart), CsvField(checkerKey), CsvField(sev),
                    CsvField(file), CsvField(line),
                    CsvField("requests/" + reqName),
                    CsvField(guidePath), "TODO",
                }));
            }

            WriteUtf8Lf(Path.Combine(opts.OutDir, "worklist.csv"), string.Join("\n", worklist) + "\n");
            WriteUtf8Lf(Path.Combine(opts.OutDir, "unresolved.csv"), string.Join("\n", unresolved) + "\n");

            // 체커별 카운트: count desc, then key asc (PS Sort-Object { -count }, { key }).
            var perCheckerOrdered = perChecker
                .Select(kv => (Checker: kv.Key, Count: kv.Value))
                .OrderByDescending(x => x.Count).ThenBy(x => x.Checker, StringComparer.Ordinal)
                .ToList();

            if (log != null)
            {
                log.WriteLine("=== prepare 요약 ===");
                log.WriteLine("  요청 생성수 : " + requestCount.ToString(CultureInfo.InvariantCulture));
                log.WriteLine("  미해결수    : " + unresolvedCount.ToString(CultureInfo.InvariantCulture));
                log.WriteLine("  체커별 카운트:");
                if (perCheckerOrdered.Count == 0)
                {
                    log.WriteLine("    (없음)");
                }
                else
                {
                    foreach (var pc in perCheckerOrdered)
                        log.WriteLine("    " + pc.Checker + " : " + pc.Count.ToString(CultureInfo.InvariantCulture));
                }
                log.WriteLine("  출력 폴더   : " + Path.GetFullPath(opts.OutDir));
            }

            return new PrepareResult
            {
                RequestCount = requestCount,
                UnresolvedCount = unresolvedCount,
                PerChecker = perCheckerOrdered,
                OutDir = Path.GetFullPath(opts.OutDir),
            };
        }

        // --- text I/O (Read-TextNoBom / Write-Utf8Lf equivalents) ---

        // Decode all bytes as UTF-8 then strip a single leading U+FEFF (exactly Read-TextNoBom).
        private static string ReadTextNoBom(string path)
        {
            byte[] bytes = File.ReadAllBytes(path);
            string text = new UTF8Encoding(false).GetString(bytes);
            if (text.Length > 0 && text[0] == '﻿') text = text.Substring(1);
            return text;
        }

        // Normalize CRLF -> LF, write UTF-8 without BOM (exactly Write-Utf8Lf).
        private static void WriteUtf8Lf(string path, string content)
        {
            string lf = content.Replace("\r\n", "\n");
            File.WriteAllText(path, lf, new UTF8Encoding(false));
        }

        // --- CSV read (ConvertFrom-Csv equivalent, header-keyed) ---

        // Parse an RFC4180-style CSV (BOM-stripped) into header-keyed rows, matching ConvertFrom-Csv:
        // first non-empty record is the header, quoted fields may contain commas/quotes("")/newlines,
        // unquoted fields are preserved verbatim (no trimming). Fully-blank lines are skipped.
        private static List<Dictionary<string, string>> ReadCsvNoBom(string path)
        {
            string text = ReadTextNoBom(path);
            var records = ParseCsvRecords(text);
            var result = new List<Dictionary<string, string>>();
            if (records.Count == 0) return result;

            List<string> header = records[0];
            for (int r = 1; r < records.Count; r++)
            {
                var fields = records[r];
                var map = new Dictionary<string, string>(StringComparer.Ordinal);
                for (int i = 0; i < header.Count; i++)
                {
                    string key = header[i];
                    if (!map.ContainsKey(key)) map[key] = i < fields.Count ? fields[i] : "";
                }
                result.Add(map);
            }
            return result;
        }

        private static List<List<string>> ParseCsvRecords(string text)
        {
            var records = new List<List<string>>();
            var fields = new List<string>();
            var sb = new StringBuilder();
            bool inQuotes = false;
            bool recordHasContent = false;   // any char seen for the current record (to detect blank lines)
            int n = text.Length;

            void EndField() { fields.Add(sb.ToString()); sb.Clear(); }
            void EndRecord()
            {
                EndField();
                // Skip a record that is a single empty field originating from a blank line (matches
                // ConvertFrom-Csv, which ignores blank lines including the trailing newline).
                if (!(fields.Count == 1 && fields[0].Length == 0 && !recordHasContent))
                    records.Add(fields);
                fields = new List<string>();
                recordHasContent = false;
            }

            for (int i = 0; i < n; i++)
            {
                char ch = text[i];
                if (inQuotes)
                {
                    if (ch == '"')
                    {
                        if (i + 1 < n && text[i + 1] == '"') { sb.Append('"'); i++; }
                        else inQuotes = false;
                    }
                    else sb.Append(ch);
                    recordHasContent = true;
                }
                else
                {
                    if (ch == '"') { inQuotes = true; recordHasContent = true; }
                    else if (ch == ',') { EndField(); recordHasContent = true; }
                    else if (ch == '\r')
                    {
                        if (i + 1 < n && text[i + 1] == '\n') i++;
                        EndRecord();
                    }
                    else if (ch == '\n') { EndRecord(); }
                    else { sb.Append(ch); recordHasContent = true; }
                }
            }
            // trailing record without a final newline
            if (sb.Length > 0 || fields.Count > 0 || recordHasContent) EndRecord();
            return records;
        }

        private static string Field(Dictionary<string, string> row, string name)
            => row.TryGetValue(name, out string? v) ? v : "";

        // --- CSV write field (ConvertTo-CsvField equivalent) ---

        private static string CsvField(string? s)
        {
            s ??= "";
            if (s.IndexOfAny(new[] { ',', '"', '\n', '\r' }) >= 0)
                return "\"" + s.Replace("\"", "\"\"") + "\"";
            return s;
        }

        // --- filename safety (Get-SafeName / San equivalent) ---

        private static string SafeName(string? s)
        {
            if (s == null) return "";
            char[] invalid = Path.GetInvalidFileNameChars();
            var sb = new StringBuilder(s.Length);
            foreach (char ch in s)
                sb.Append(ch == ' ' || Array.IndexOf(invalid, ch) >= 0 ? '-' : ch);
            return sb.ToString();
        }

        // --- path helpers (Split-Path / Join-Path equivalents) ---

        // Split-Path -Leaf: last path component, treating both \ and / as separators.
        private static string LeafName(string p)
        {
            int idx = p.LastIndexOfAny(new[] { '\\', '/' });
            return idx >= 0 ? p.Substring(idx + 1) : p;
        }

        // Split-Path -Parent equivalent (used only to locate dotnet-contracts next to checkers).
        private static string ParentDir(string p)
        {
            string trimmed = p.TrimEnd('\\', '/');
            int idx = trimmed.LastIndexOfAny(new[] { '\\', '/' });
            return idx >= 0 ? trimmed.Substring(0, idx) : "";
        }

        // Join-Path semantics: single separator between parent and child; if parent already ends with a
        // separator, reuse it (don't add another). Windows default separator is '\'.
        private static string JoinPathPwsh(string parent, string child)
        {
            if (parent.Length > 0 && (parent[parent.Length - 1] == '\\' || parent[parent.Length - 1] == '/'))
                return parent + child;
            return parent + "\\" + child;
        }
    }
}
