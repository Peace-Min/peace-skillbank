// SparrowXlsExport.Core.TriagePreparer: deterministic reproduction of Run-Triage.ps1 `prepare`.
//
// Reads index.csv (UTF-8 with BOM; header md_file,ID,체커 키,위험도,파일명,라인,이슈 상태,체커명), and for
// each row resolves the checker guide <GuidesDir>\<체커 키>.md (join on the verbatim 체커 키 column). If the
// guide is present it writes a self-contained requests\{ID}_{체커키}.md (the repair prompt with {{GUIDE}} and
// {{ITEM}} substituted). If the guide is missing but the checker key exists, it emits a fallback guide from the
// XLS/item evidence so the LLM can still handle the finding. Only rows with no checker key or missing item md
// remain in unresolved.csv. Also writes worklist.csv.
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

        /// <summary>Path to references\project-conventions.md (OSTES 정책 단일 소스). Required.</summary>
        public string ConventionsPath = "";

        /// <summary>Path to the folder-instruction-template.md (_작업지침.md 렌더 템플릿). Required.</summary>
        public string TemplatePath = "";

        /// <summary>Output directory; gets requests\, worklist.csv, unresolved.csv. Required.</summary>
        public string OutDir = "";

        /// <summary>Exact-match filter on 체커 키; null =&gt; no checker filter.</summary>
        public string? Checker;

        /// <summary>Comma-separated severity set (each trimmed); null/empty =&gt; no severity filter.</summary>
        public string? Severity;

        /// <summary>
        /// Comma-separated set of guide tracks (A/B/C) to INCLUDE. null/empty =&gt; default "C" only
        /// (mirrors Run-Triage.ps1 -Tracks). A guide whose parsed track is not in this set is skipped
        /// (neither a request nor an unresolved row). Guides with no parseable track are treated as C.
        /// </summary>
        public string? Tracks;

        /// <summary>Cap on requests+unresolved among filter-passing rows; null =&gt; no cap.</summary>
        public int? Max;
    }

    /// <summary>Structured result of a triage-prepare run (counts mirror the PS Write-Host summary).</summary>
    public sealed class PrepareResult
    {
        public int RequestCount;
        public int UnresolvedCount;
        /// <summary>Rows skipped because the guide's track was not in the requested -Tracks set.</summary>
        public int TrackFiltered;
        /// <summary>Per-checker request counts, ordered count desc then key asc (PS summary order).</summary>
        public IReadOnlyList<(string Checker, int Count)> PerChecker = Array.Empty<(string, int)>();
        public string OutDir = "";
    }

    /// <summary>Deterministic index.csv -&gt; triage requests preparer. Byte-identical to Run-Triage.ps1 prepare.</summary>
    public static class TriagePreparer
    {
        /// <summary>
        /// Reproduce Run-Triage.ps1 prepare exactly: emit requests\{ID}_{체커키}.md (guide+item merged into the
        /// prompt), worklist.csv, and unresolved.csv. Optionally streams the same
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
            if (string.IsNullOrEmpty(opts.ConventionsPath)) throw new ArgumentException("prepare: ConventionsPath 필요");
            if (!File.Exists(opts.ConventionsPath)) throw new FileNotFoundException("프로젝트 규약 문서 없음: " + opts.ConventionsPath);
            if (string.IsNullOrEmpty(opts.TemplatePath)) throw new ArgumentException("prepare: TemplatePath 필요");
            if (!File.Exists(opts.TemplatePath)) throw new FileNotFoundException("폴더 지침 템플릿 없음: " + opts.TemplatePath);

            string promptTemplate = ReadTextNoBom(opts.PromptPath);

            // OSTES 프로젝트 정책 소스(공통) + 폴더 지침 템플릿.
            var conventions = GetConventionSections(ReadTextNoBom(opts.ConventionsPath));
            string folderTemplate = ReadTextNoBom(opts.TemplatePath);
            string commonPolicy = conventions.TryGetValue("(공통) 처리 정책", out string? _cp) ? _cp : "";
            string generalNote = conventions.TryGetValue("프로젝트 규약", out string? _gn) ? _gn : "";

            var sevSet = new List<string>();
            if (!string.IsNullOrEmpty(opts.Severity))
                sevSet = opts.Severity.Split(',').Select(x => x.Trim()).Where(x => x.Length > 0).ToList();

            // 트랙 필터: 요청을 생성할 가이드 트랙 집합. 기본 = C만(Run-Triage.ps1 -Tracks 기본과 동일).
            var trackSet = new HashSet<string>(StringComparer.Ordinal) { "C" };
            if (!string.IsNullOrEmpty(opts.Tracks))
                trackSet = new HashSet<string>(
                    opts.Tracks.Split(',').Select(x => x.Trim().ToUpperInvariant()).Where(x => x.Length > 0),
                    StringComparer.Ordinal);

            // 출력 폴더 준비(멱등: prepare 산출물만 초기화).
            Directory.CreateDirectory(opts.OutDir);
            string reqDir = Path.Combine(opts.OutDir, "requests");
            if (Directory.Exists(reqDir)) Directory.Delete(reqDir, recursive: true);
            Directory.CreateDirectory(reqDir);

            var rows = ReadCsvNoBom(opts.IndexCsvPath);

            var worklist = new List<string> { "id,체커키,위험도,파일명,라인,item_md,guide,상태" };
            var unresolved = new List<string> { "id,체커키,위험도,파일명,라인,item_md,사유" };

            int requestCount = 0;
            int unresolvedCount = 0;
            int trackFilteredCount = 0;
            var perChecker = new Dictionary<string, int>(StringComparer.Ordinal);
            var perCheckerMeta = new Dictionary<string, (string Name, string Severity)>(StringComparer.Ordinal);
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

                string checkerName = Field(row, "체커명");
                string guidePath = JoinPathPwsh(opts.GuidesDir, checkerKey + ".md");
                bool fallbackGuide = false;

                if (checkerKey.Length == 0)
                {
                    unresolvedCount++;
                    unresolved.Add(string.Join(",", new[]
                    {
                        CsvField(idPart), CsvField(checkerKey), CsvField(sev),
                        CsvField(file), CsvField(line), CsvField(itemLeaf), CsvField("체커 키 없음"),
                    }));
                    continue;
                }

                // 가이드 존재 → 트랙 필터. 가이드를 여기서 1회 읽어 트랙을 파싱하고, 요청 집합에 없으면
                // 이 행을 건너뜀(요청도 미해결도 아님). 통과 시 guideText 를 요청 조립 때 재사용.
                string guideText;
                if (File.Exists(guidePath))
                {
                    guideText = ReadTextNoBom(guidePath);
                }
                else
                {
                    fallbackGuide = true;
                    guidePath = "__generated_fallback__/" + checkerKey + ".md";
                    guideText = BuildFallbackGuide(checkerKey, checkerName, sev);
                }
                string guideTrack = GetGuideTrack(guideText);
                if (!trackSet.Contains(guideTrack))
                {
                    trackFilteredCount++;
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

                if (!perCheckerMeta.ContainsKey(checkerKey))
                    perCheckerMeta[checkerKey] = GetGuideMeta(guideText, checkerKey);
                if (!fallbackGuide && checkerKey == "NULL_RETURN_STD")
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

                // OSTES 정책 임베드: 모든 요청에 공통 Policy A(self-contained). 체커 섹션이 있으면 추가.
                reqText = reqText + "\n\n---\n\n## 처리 정책 (이 프로젝트)\n\n" + commonPolicy + "\n";
                if (conventions.TryGetValue(checkerKey, out string? checkerSection))
                    reqText = reqText + "\n---\n\n## " + checkerKey + " — 프로젝트 의무\n\n" + checkerSection + "\n";

                string safeChecker = SafeName(checkerKey);
                string reqName = SafeName(idPart) + "_" + safeChecker + ".md";
                string subDir = Path.Combine(reqDir, safeChecker);
                Directory.CreateDirectory(subDir);
                string reqPath = Path.Combine(subDir, reqName);
                WriteUtf8Lf(reqPath, reqText);
                requestCount++;
                perChecker[checkerKey] = perChecker.TryGetValue(checkerKey, out int c) ? c + 1 : 1;

                worklist.Add(string.Join(",", new[]
                {
                    CsvField(idPart), CsvField(checkerKey), CsvField(sev),
                    CsvField(file), CsvField(line),
                    CsvField("requests/" + safeChecker + "/" + reqName),
                    CsvField(guidePath), "TODO",
                }));
            }

            // 체커별 _작업지침.md (요청 ≥1건 받은 폴더). 결정론: 체커키 오름차순.
            foreach (string ck in perChecker.Keys.OrderBy(k => k, StringComparer.Ordinal))
            {
                string safeChecker = SafeName(ck);
                var meta = perCheckerMeta[ck];
                string mandate = conventions.TryGetValue(ck, out string? sec) ? sec : generalNote;
                string instr = folderTemplate
                    .Replace("{{CHECKER_KEY}}", ck)
                    .Replace("{{CHECKER_NAME}}", meta.Name)
                    .Replace("{{COUNT}}", perChecker[ck].ToString(CultureInfo.InvariantCulture))
                    .Replace("{{SEVERITY}}", meta.Severity)
                    .Replace("{{COMMON_POLICY}}", commonPolicy)
                    .Replace("{{CHECKER_MANDATE}}", mandate);
                WriteUtf8Lf(Path.Combine(reqDir, safeChecker, "_작업지침.md"), instr);
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
                log.WriteLine("  트랙 필터   : " + string.Join(",", trackSet));
                log.WriteLine("  요청 생성수 : " + requestCount.ToString(CultureInfo.InvariantCulture));
                log.WriteLine("  미해결수    : " + unresolvedCount.ToString(CultureInfo.InvariantCulture));
                log.WriteLine("  트랙 제외수 : " + trackFilteredCount.ToString(CultureInfo.InvariantCulture));
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
                TrackFiltered = trackFilteredCount,
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

        // Parse project-conventions.md into '## <name>' -> body(Trim) map. Mirrors Get-ConventionSections:
        // a section starts at a line with the exact "## " prefix ('### ' is not a boundary); body is the lines
        // up to the next "## " (or EOF), trimmed. H1 ('# ') outside a section is ignored.
        private static Dictionary<string, string> GetConventionSections(string text)
        {
            string norm = text.Replace("\r\n", "\n");
            string[] lines = norm.Split('\n');
            var sections = new Dictionary<string, string>(StringComparer.Ordinal);
            string? current = null;
            var buffer = new List<string>();
            foreach (string ln in lines)
            {
                if (ln.StartsWith("## ", StringComparison.Ordinal))
                {
                    if (current != null) sections[current] = string.Join("\n", buffer).Trim();
                    current = ln.Substring(3).Trim();
                    buffer = new List<string>();
                }
                else if (current != null) buffer.Add(ln);
            }
            if (current != null) sections[current] = string.Join("\n", buffer).Trim();
            return sections;
        }

        // Extract the checker's Korean name (H1 '# KEY — 이름') and severity ('**심각도**: 값 |') from the
        // guide text. Mirrors Get-GuideMeta. Falls back to the key / "" when not found.
        private static (string Name, string Severity) GetGuideMeta(string guideText, string checkerKey)
        {
            string norm = guideText.Replace("\r\n", "\n");
            string[] lines = norm.Split('\n');
            string name = checkerKey;
            string sev = "";
            foreach (string ln in lines)
            {
                if (name == checkerKey && ln.StartsWith("# ", StringComparison.Ordinal))
                {
                    int dash = ln.IndexOf('—');
                    if (dash >= 0) name = ln.Substring(dash + 1).Trim();
                }
                if (sev.Length == 0)
                {
                    int sevIdx = ln.IndexOf("심각도", StringComparison.Ordinal);
                    if (sevIdx >= 0)
                    {
                        int colon = ln.IndexOf(':', sevIdx);
                        if (colon >= 0)
                        {
                            string rest = ln.Substring(colon + 1);
                            int bar = rest.IndexOf('|');
                            sev = (bar >= 0 ? rest.Substring(0, bar) : rest).Trim();
                        }
                    }
                }
            }
            return (name, sev);
        }

        // Matches the guide header '**트랙**: X' (X = A/B/C). Same regex PowerShell -match uses (.NET engine).
        private static readonly System.Text.RegularExpressions.Regex TrackRe =
            new System.Text.RegularExpressions.Regex(@"\*\*트랙\*\*:\s*([ABC])",
                System.Text.RegularExpressions.RegexOptions.Compiled);

        // Extract the checker guide's track (A/B/C). Missing/unparseable => "C" (safe default: no regression).
        private static string GetGuideTrack(string guideText)
        {
            var m = TrackRe.Match(guideText);
            return m.Success ? m.Groups[1].Value : "C";
        }

        private static string BuildFallbackGuide(string checkerKey, string checkerName, string severity)
        {
            string title = string.IsNullOrWhiteSpace(checkerName) ? checkerKey : checkerName.Trim();
            string sev = string.IsNullOrWhiteSpace(severity) ? "미확인" : severity.Trim();
            var sb = new StringBuilder();
            sb.Append("# ").Append(checkerKey).Append(" — ").Append(title).Append("\n\n");
            sb.Append("**트랙**: C  |  **심각도**: ").Append(sev).Append("  |  **가이드 상태**: XLS 기반 자동 생성\n\n");
            sb.Append("## 진성 판별 기준\n\n");
            sb.Append("- 이 체커는 `references/checkers/").Append(checkerKey).Append(".md` 가이드가 아직 없다.\n");
            sb.Append("- Sparrow XLS의 `체커 설명`, `소스 코드`, `파일명`, `라인`, `체커명`을 1차 근거로 삼는다.\n");
            sb.Append("- 실제 소스 파일에서 해당 라인 주변의 최소 문맥을 확인하고, Sparrow가 요구한 결함을 제거하는 방향으로 수정한다.\n\n");
            sb.Append("## 이렇게 보여도 넘기지 말 것\n\n");
            sb.Append("- 가이드가 없다는 이유로 false-positive 처리하거나 스킵하지 않는다.\n");
            sb.Append("- 코드상 문제가 없어 보인다는 이유만으로 방치하지 않는다. Sparrow 검출 항목은 전건 수정 정책의 대상이다.\n");
            sb.Append("- 문맥이 부족하면 `문맥 필요`로 두고 필요한 파일, 심볼, 호출부, 소유권 정보를 명시한다.\n\n");
            sb.Append("## 수정 패턴 (C# 예시)\n\n");
            sb.Append("- 이 체커의 전용 예시는 아직 없다.\n");
            sb.Append("- 요청 md의 `[검출 항목]`에 포함된 Sparrow 설명과 소스 스니펫을 기준으로 Before/After를 작성한다.\n");
            sb.Append("- .NET Framework 4.7.2 / C# 7.3 문법만 사용한다.");
            return sb.ToString();
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
