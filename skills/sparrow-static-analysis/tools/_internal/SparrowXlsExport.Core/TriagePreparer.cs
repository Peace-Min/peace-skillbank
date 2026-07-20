// SparrowXlsExport.Core.TriagePreparer: deterministic reproduction of Run-Triage.ps1 `prepare`.
//
// Reads index.csv (UTF-8 with BOM; header md_file,ID,체커 키,위험도,파일명,라인,이슈 상태,체커명,경로 — the
// trailing 경로 column is ignored here, columns are resolved by name), and for
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
//  - the prompt template's maintainer preamble (leading '>' block + '---' before the first '## ') is stripped
//    at assembly time so it never leaks into a generated request (Remove-MaintainerPreamble in PS)

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

        /// <summary>Case-insensitive substring filter on 체커 키; null =&gt; no checker filter.</summary>
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
        /// <summary>
        /// Checker keys whose requests were assembled from a generated fallback guide (no
        /// references\checkers\&lt;key&gt;.md). Ordinal-ascending. Operator-facing only: the request md never
        /// mentions rule registration; this drives the summary hint and the fallback _작업지침.md note.
        /// </summary>
        public IReadOnlyList<string> FallbackCheckers = Array.Empty<string>();
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

            string promptTemplate = StripMaintainerPreamble(ReadTextNoBom(opts.PromptPath));

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
            var unresolvedRequests = new List<UnresolvedRow>();

            int requestCount = 0;
            int unresolvedCount = 0;
            int trackFilteredCount = 0;
            var perChecker = new Dictionary<string, int>(StringComparer.Ordinal);
            var perCheckerMeta = new Dictionary<string, (string Name, string Severity)>(StringComparer.Ordinal);
            // 요청이 fallback(미등록) 가이드로 조립된 체커키 집합. 운영자 안내(요약 출력 + _작업지침.md)에만 쓴다.
            var fallbackCheckers = new HashSet<string>(StringComparer.Ordinal);
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

                // 필터(AND). checker=대소문자 무시 부분검색(체커 키), severity=집합 포함.
                if (opts.Checker != null && checkerKey.IndexOf(opts.Checker, StringComparison.OrdinalIgnoreCase) < 0) continue;
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
                    unresolvedRequests.Add(new UnresolvedRow(idPart, checkerKey, sev, file, line, itemLeaf, "체커 키 없음"));
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
                    unresolvedRequests.Add(new UnresolvedRow(idPart, checkerKey, sev, file, line, itemLeaf, "항목 md 없음: " + itemLeaf));
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

                // 자리표시자 치환(리터럴, 정규식 아님). 근거 필드/제약은 등록·미등록에 따라 분기한다.
                string reqText = promptTemplate
                    .Replace("{{EVIDENCE_FIELD}}", fallbackGuide ? EvidenceFieldUnregistered : EvidenceFieldRegistered)
                    .Replace("{{UNREGISTERED_CONSTRAINT}}", fallbackGuide ? UnregisteredConstraint : "")
                    .Replace("{{GUIDE}}", guideText).Replace("{{ITEM}}", itemText);

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
                if (fallbackGuide) fallbackCheckers.Add(checkerKey);
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
                    .Replace("{{FALLBACK_NOTE}}", fallbackCheckers.Contains(ck) ? FallbackFolderNote(ck) : "")
                    .Replace("{{CHECKER_KEY}}", ck)
                    .Replace("{{CHECKER_NAME}}", meta.Name)
                    .Replace("{{COUNT}}", perChecker[ck].ToString(CultureInfo.InvariantCulture))
                    .Replace("{{SEVERITY}}", meta.Severity)
                    .Replace("{{COMMON_POLICY}}", commonPolicy)
                    .Replace("{{CHECKER_MANDATE}}", mandate);
                WriteUtf8Lf(Path.Combine(reqDir, safeChecker, "_작업지침.md"), instr);
            }

            WriteUnresolvedRequests(reqDir, unresolvedRequests);

            WriteUtf8Lf(Path.Combine(opts.OutDir, "worklist.csv"), string.Join("\n", worklist) + "\n");
            WriteUtf8Lf(Path.Combine(opts.OutDir, "unresolved.csv"), string.Join("\n", unresolved) + "\n");

            // 체커별 카운트: count desc, then key asc (PS Sort-Object { -count }, { key }).
            var perCheckerOrdered = perChecker
                .Select(kv => (Checker: kv.Key, Count: kv.Value))
                .OrderByDescending(x => x.Count).ThenBy(x => x.Checker, StringComparer.Ordinal)
                .ToList();
            var fallbackOrdered = fallbackCheckers.OrderBy(k => k, StringComparer.Ordinal).ToList();

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
                if (fallbackOrdered.Count > 0)
                {
                    log.WriteLine("  미등록 체커 " + fallbackOrdered.Count.ToString(CultureInfo.InvariantCulture)
                                  + "종 — GUI '체커 룰 관리'에서 룰 추가 가능: " + string.Join(", ", fallbackOrdered));
                }
                log.WriteLine("  출력 폴더   : " + Path.GetFullPath(opts.OutDir));
            }

            return new PrepareResult
            {
                RequestCount = requestCount,
                UnresolvedCount = unresolvedCount,
                TrackFiltered = trackFilteredCount,
                PerChecker = perCheckerOrdered,
                FallbackCheckers = fallbackOrdered,
                OutDir = Path.GetFullPath(opts.OutDir),
            };
        }

        private sealed class UnresolvedRow
        {
            public UnresolvedRow(string id, string checker, string severity, string file, string line, string item, string reason)
            {
                Id = id;
                Checker = checker;
                Severity = severity;
                File = file;
                Line = line;
                Item = item;
                Reason = reason;
            }

            public string Id { get; }
            public string Checker { get; }
            public string Severity { get; }
            public string File { get; }
            public string Line { get; }
            public string Item { get; }
            public string Reason { get; }
        }

        private static void WriteUnresolvedRequests(string reqDir, IReadOnlyList<UnresolvedRow> rows)
        {
            if (rows.Count == 0) return;

            string unresolvedDir = Path.Combine(reqDir, "_UNRESOLVED");
            Directory.CreateDirectory(unresolvedDir);
            WriteUtf8Lf(Path.Combine(unresolvedDir, "_작업지침.md"),
                "# _UNRESOLVED\n\n" +
                "- 이 폴더는 Track C 요청 md로 정상 조립하지 못한 Sparrow XLS 행입니다.\n" +
                "- 원본 XLS, 실제 소스 파일, 주변 문맥을 확인해 결함 제거 작업을 계속합니다.\n" +
                "- 항목 md가 없거나 체커 키가 비어 있어도 Sparrow 검출 행이므로 임의로 무시하지 않습니다.");

            for (int i = 0; i < rows.Count; i++)
            {
                var row = rows[i];
                string checkerPart = string.IsNullOrWhiteSpace(row.Checker) ? "NO_CHECKER" : SafeName(row.Checker);
                string name = (i + 1).ToString("D5", CultureInfo.InvariantCulture) + "_" + SafeName(row.Id) + "_" + checkerPart + ".md";
                var sb = new StringBuilder();
                sb.Append("# 미해결 Sparrow 항목\n\n");
                sb.Append("- ID: ").Append(row.Id).Append('\n');
                sb.Append("- 체커 키: ").Append(row.Checker).Append('\n');
                sb.Append("- 위험도: ").Append(row.Severity).Append('\n');
                sb.Append("- 파일명: ").Append(row.File).Append('\n');
                sb.Append("- 라인: ").Append(row.Line).Append('\n');
                sb.Append("- item_md: ").Append(row.Item).Append('\n');
                sb.Append("- 사유: ").Append(row.Reason).Append("\n\n");
                sb.Append("## 작업 지시\n\n");
                sb.Append("이 항목은 자동 조립이 실패했지만 Sparrow 검출 행입니다. 실제 소스 파일의 대상 라인과 최소 인접 문맥을 확인해 결함을 제거하고, 수정이 불가능하면 필요한 추가 문맥을 명시합니다.");
                WriteUtf8Lf(Path.Combine(unresolvedDir, name), sb.ToString());
            }
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

        // 미등록 체커의 자리표시 가이드. 합성 의사(pseudo) 가이드를 쓰지 않는다: 스킵 금지/전건 수정은 모든
        // 요청에 붙는 '처리 정책' 섹션이 이미 규정하므로 여기서 반복하면 중복 토큰만 늘어난다. XLS가 실제로
        // 준 값(체커키/체커명/심각도)과 최소 안내 2줄만 남긴다. (PS New-FallbackGuide 와 바이트 동일)
        //
        // 안내 2줄의 역할: (1) 근거 범위를 '체커 설명 + 표시된 소스 라인'으로 못박아 없는 룰/표준 매핑을 지어내지
        // 못하게 하고, (2) 룰 미등록이 처리 유예 사유가 아님을 못박는다. GUI 룰 등록 안내는 작업자(LLM)가 실행할
        // 수 없는 동작이라 요청 md에서 제외하고, 운영자용 경로(prepare 요약 + fallback 체커의 _작업지침.md)로만 남긴다.
        private static string BuildFallbackGuide(string checkerKey, string checkerName, string severity)
        {
            string title = string.IsNullOrWhiteSpace(checkerName) ? checkerKey : checkerName.Trim();
            string sev = string.IsNullOrWhiteSpace(severity) ? "미확인" : severity.Trim();
            var sb = new StringBuilder();
            sb.Append("# ").Append(checkerKey).Append(" — ").Append(title).Append("\n\n");
            sb.Append("**트랙**: C  |  **심각도**: ").Append(sev).Append("  |  **가이드 상태**: 미등록\n\n");
            sb.Append("(이 체커에는 등록된 룰이 없습니다. 근거로 사용할 수 있는 것은 아래 [검출 항목]의 `체커 설명`과 표시된 소스 라인뿐이며, 그 외 판별 기준·예외 조건·표준(CWE 등) 매핑을 추론해 보충하지 마십시오.)\n");
            sb.Append("(룰 미등록은 처리 유예 사유가 아닙니다. 위 범위만으로 반드시 수정 또는 patch를 산출하고, 정말 불가능하면 `문맥 필요`로 두되 필요한 룰 항목을 [추가 필요 문맥]에 적으십시오.)");
            return sb.ToString();
        }

        // 요청 md의 '처리 상태 > 근거' 필드. 등록 체커는 가이드 요약 1줄. 미등록 체커는 요약할 룰이 없으므로
        // 요약 대신 '인용'을 강제한다(빈칸을 "가이드에 따르면…"으로 메우는 환각 경로 차단).
        private const string EvidenceFieldRegistered =
            "- 근거: <체커 가이드 기준으로 짧게 요약>";

        private const string EvidenceFieldUnregistered =
            "- 근거(인용): <[검출 항목]의 `체커 설명`에서 그대로 인용한 문장 1개>\n" +
            "- 근거(코드): <TARGET LINE의 실제 코드가 왜 그 설명에 해당하는지 1문장>";

        // 미등록 체커에만 '출력 형식' 앞에 붙는 제약. 등록 체커는 빈 문자열(자리표시자 뒤 문장에 그대로 이어짐).
        private const string UnregisteredConstraint =
            "**등록된 룰이 없으므로 \"체커 가이드에 따르면\" 류 서술을 쓰지 마십시오. 인용 가능한 근거는 `체커 설명` 한 줄과 표시된 소스 라인뿐입니다.**\n\n";

        // fallback 체커 폴더의 _작업지침.md 에만 들어가는 운영자용 안내(작업자용 요청 md에는 넣지 않는다).
        private static string FallbackFolderNote(string checkerKey)
            => "- (운영 참고) 이 체커에는 등록된 룰 가이드가 없어 요청 md의 [체커 가이드] 자리에는 미등록 안내만 들어갑니다. Sparrow Helper GUI → '체커 룰 관리'에서 `"
               + checkerKey + "` 룰을 추가하면 다음 실행부터 이 자리에 가이드 전문이 반영됩니다.\n";

        // 템플릿 유지보수용 머리말 제거(생성물에서만). triage-prompt.md 상단의 '>' 인용 블록은 템플릿 파일을
        // 읽는 유지보수자용 설명이지 작업자용 지시가 아니므로, 요청 md 로 새어 나가지 않게 조립 직전에 벗겨낸다.
        // 정의: 첫 '## ' 섹션 앞에 나오는 연속된 '>' 줄 + 바로 뒤의 '---' 구분선 + 주변 빈 줄. H1 은 유지.
        // 그런 블록이 없으면 원문 그대로 반환(no-op, 멱등). PS Remove-MaintainerPreamble 과 동일 알고리즘.
        private static string StripMaintainerPreamble(string template)
        {
            string[] lines = template.Split('\n');

            int firstSection = lines.Length;
            for (int i = 0; i < lines.Length; i++)
            {
                if (lines[i].TrimStart().StartsWith("## ", StringComparison.Ordinal)) { firstSection = i; break; }
            }

            int bq = -1;
            for (int i = 0; i < firstSection; i++)
            {
                if (lines[i].TrimStart().StartsWith(">", StringComparison.Ordinal)) { bq = i; break; }
            }
            if (bq < 0) return template;   // 머리말 없음 → 그대로

            int end = bq;
            while (end + 1 < firstSection && lines[end + 1].TrimStart().StartsWith(">", StringComparison.Ordinal)) end++;

            // 인용 블록 뒤: 빈 줄 → '---' → 빈 줄 이 이어지면 함께 제거. '---' 가 없으면 빈 줄은 남긴다.
            int probe = end + 1;
            while (probe < firstSection && lines[probe].Trim().Length == 0) probe++;
            if (probe < firstSection && lines[probe].Trim() == "---")
            {
                end = probe;
                while (end + 1 < firstSection && lines[end + 1].Trim().Length == 0) end++;
            }

            int start = bq;
            while (start - 1 >= 0 && lines[start - 1].Trim().Length == 0) start--;

            var kept = new List<string>(lines.Length);
            for (int i = 0; i < start; i++) kept.Add(lines[i]);
            // 앞뒤로 내용이 남아 있으면 빈 줄 하나로 이어 붙인다(H1 과 첫 섹션 사이 한 줄 유지).
            if (start > 0 && end + 1 < lines.Length) kept.Add("");
            for (int i = end + 1; i < lines.Length; i++) kept.Add(lines[i]);
            return string.Join("\n", kept);
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
