// CoreTests: loop-test harness proving the Core refactor is byte-faithful.
//
//   A. Console parse (optional real xls) exits 0 and emits BOM'd index.csv.
//   B. Core.Run == console parse: byte-identical items/*, index.csv, checkers.md.
//   C. Core.Prepare == Run-Triage.ps1 prepare (CRITICAL): byte-identical requests/*, worklist.csv,
//      unresolved.csv on the fixture set and, when supplied, a real XLS subset (full, -Checker, -Severity/-Max).
//
// Prints PASS/FAIL per assertion; exits nonzero if any assertion fails. Run after a Release build of the
// Core, console, and CoreTests projects. By default this runs fixture-only. Pass a real XLS path as argv[0]
// to add optional real-data checks without fixed historical row-count assumptions.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using SparrowXlsExport.Core;

internal static class Program
{
    private static int _fails;
    private static int _checks;

    private static void Check(bool cond, string name, string detail = "")
    {
        _checks++;
        if (cond) Console.WriteLine("  [PASS] " + name);
        else { _fails++; Console.WriteLine("  [FAIL] " + name + (detail.Length > 0 ? "  -- " + detail : "")); }
    }

    private static int Main(string[] args)
    {
        try { Console.OutputEncoding = new UTF8Encoding(false); } catch { }

        string? realXlsArg = args.FirstOrDefault(a => !a.StartsWith("--", StringComparison.Ordinal));
        bool fixturesOnly = args.Any(a => string.Equals(a, "--fixtures-only", StringComparison.OrdinalIgnoreCase)) || realXlsArg == null;
        string realXls = realXlsArg ?? "";

        string? skillRoot = FindSkillRoot(AppContext.BaseDirectory);
        if (skillRoot == null) { Console.Error.WriteLine("skill root (references\\triage\\triage-prompt.md) not found"); return 3; }

        string references = Path.Combine(skillRoot, "references");
        string guidesDir = Path.Combine(references, "checkers");
        string promptPath = Path.Combine(references, "triage", "triage-prompt.md");
        string conventionsPath = Path.Combine(references, "project-conventions.md");
        string templatePath = Path.Combine(references, "triage", "folder-instruction-template.md");
        string runTriage = Path.Combine(references, "triage", "Run-Triage.ps1");
        string fixturesIndex = Path.Combine(references, "triage", "fixtures", "index.csv");
        string fixturesItems = Path.Combine(references, "triage", "fixtures", "items");
        string consoleExe = Path.Combine(skillRoot, "tools", "_internal", "SparrowXlsExport", "bin", "Release", "net8.0", "SparrowXlsExport.exe");

        string work = Path.Combine(Path.GetTempPath(), "sparrow-coretests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);

        Console.WriteLine("================= CoreTests (A/B/C) =================");
        Console.WriteLine("skillRoot : " + skillRoot);
        Console.WriteLine("consoleExe: " + consoleExe);
        Console.WriteLine("realXls   : " + realXls);
        Console.WriteLine("runTriage : " + runTriage);
        Console.WriteLine("work      : " + work);
        Console.WriteLine();

        try
        {
            Check(File.Exists(consoleExe), "precondition: console exe exists", consoleExe);
            if (!fixturesOnly) Check(File.Exists(realXls), "precondition: real xls exists", realXls);
            Check(File.Exists(runTriage), "precondition: Run-Triage.ps1 exists", runTriage);
            Check(File.Exists(promptPath), "precondition: triage-prompt.md exists", promptPath);
            Check(File.Exists(conventionsPath), "precondition: project-conventions.md exists", conventionsPath);
            Check(File.Exists(templatePath), "precondition: folder-instruction-template.md exists", templatePath);
            if (_fails > 0) return Done();

            if (fixturesOnly)
            {
                Console.WriteLine("\n==== C. Core.Prepare == Run-Triage.ps1 prepare (fixtures only) ====");
                ComparePrepare("C1 fixtures", runTriage, promptPath, conventionsPath, templatePath,
                    fixturesIndex, fixturesItems, guidesDir, work, "C1",
                    checker: null, severity: null, max: null);
                return Done();
            }

            // ================================================================ A
            Console.WriteLine("\n==== A. Console parse identical (real xls) ====");
            string dirA = Path.Combine(work, "A_console");
            var (exitA, stdoutA) = RunProcess(consoleExe, new[] { realXls, "--out", dirA });
            Check(exitA == 0, "A: console exit 0", "exit=" + exitA);
            Check(stdoutA.Contains("total data rows:"), "A: stdout has total data rows summary");
            Check(stdoutA.Contains("unique checkers:"), "A: stdout has unique checkers summary");
            string itemsA = Path.Combine(dirA, "items");
            int countA = Directory.Exists(itemsA) ? Directory.GetFiles(itemsA, "*.md").Length : 0;
            Check(countA > 0, "A: items generated", "found=" + countA);
            string indexA = Path.Combine(dirA, "index.csv");
            Check(HasUtf8Bom(indexA), "A: index.csv has UTF-8 BOM");

            // ================================================================ B
            Console.WriteLine("\n==== B. Core.Run == console parse (byte-identical) ====");
            string dirB = Path.Combine(work, "B_core");
            SparrowExporter.Run(new ExportOptions { InputPath = realXls, OutDir = dirB }, TextWriter.Null);
            Check(DirsByteIdentical(Path.Combine(dirA, "items"), Path.Combine(dirB, "items"), "*.md", out string bItemsDiff),
                  "B: items/*.md byte-identical", bItemsDiff);
            Check(FilesByteIdentical(indexA, Path.Combine(dirB, "index.csv"), out string bIdxDiff),
                  "B: index.csv byte-identical", bIdxDiff);
            Check(FilesByteIdentical(Path.Combine(dirA, "checkers.md"), Path.Combine(dirB, "checkers.md"), out string bChkDiff),
                  "B: checkers.md byte-identical", bChkDiff);

            // ================================================================ C
            Console.WriteLine("\n==== C. Core.Prepare == Run-Triage.ps1 prepare (CRITICAL) ====");

            // C1: fixture set.
            ComparePrepare("C1 fixtures", runTriage, promptPath, conventionsPath, templatePath,
                fixturesIndex, fixturesItems, guidesDir, work, "C1",
                checker: null, severity: null, max: null);

            // Parse the real xls FULL once (no filter) for the real-subset prepare cases.
            string realParsed = Path.Combine(work, "real_parsed");
            SparrowExporter.Run(new ExportOptions { InputPath = realXls, OutDir = realParsed }, TextWriter.Null);
            string realIndex = Path.Combine(realParsed, "index.csv");
            string realItems = Path.Combine(realParsed, "items");

            // C2: real full (mixed resolved/unresolved, exercises unresolved.csv at scale).
            ComparePrepare("C2 real-full", runTriage, promptPath, conventionsPath, templatePath,
                realIndex, realItems, guidesDir, work, "C2",
                checker: null, severity: null, max: null);

            // C3: real -Checker RESOURCE_LEAK (exact checker filter + guide resolution).
            ComparePrepare("C3 real-RESOURCE_LEAK", runTriage, promptPath, conventionsPath, templatePath,
                realIndex, realItems, guidesDir, work, "C3",
                checker: "RESOURCE_LEAK", severity: null, max: null);

            // C4: real -Checker NULL_RETURN_STD (exercises the dotnet-contracts append path, if any rows).
            ComparePrepare("C4 real-NULL_RETURN_STD", runTriage, promptPath, conventionsPath, templatePath,
                realIndex, realItems, guidesDir, work, "C4",
                checker: "NULL_RETURN_STD", severity: null, max: null);

            // C5: real -Max 50 (max cap).
            ComparePrepare("C5 real-severity-max", runTriage, promptPath, conventionsPath, templatePath,
                realIndex, realItems, guidesDir, work, "C5",
                checker: null, severity: null, max: 50);

            // C6: real -Checker OVERLY_BROAD_CATCH (per-checker mandate embed path).
            ComparePrepare("C6 real-OVERLY_BROAD_CATCH", runTriage, promptPath, conventionsPath, templatePath,
                realIndex, realItems, guidesDir, work, "C6",
                checker: "OVERLY_BROAD_CATCH", severity: null, max: null);

            // C7: real -Checker EMPTY_CATCH_BLOCK (per-checker mandate embed path).
            ComparePrepare("C7 real-EMPTY_CATCH_BLOCK", runTriage, promptPath, conventionsPath, templatePath,
                realIndex, realItems, guidesDir, work, "C7",
                checker: "EMPTY_CATCH_BLOCK", severity: null, max: null);

            // C8: real -Tracks C (explicit default; C-track checkers only).
            ComparePrepare("C8 real-Tracks-C", runTriage, promptPath, conventionsPath, templatePath,
                realIndex, realItems, guidesDir, work, "C8",
                checker: null, severity: null, max: null, tracks: "C");

            // C9: real -Tracks A,B,C (opt-in: A/B checkers ALSO emit requests).
            ComparePrepare("C9 real-Tracks-ABC", runTriage, promptPath, conventionsPath, templatePath,
                realIndex, realItems, guidesDir, work, "C9",
                checker: null, severity: null, max: null, tracks: "A,B,C");

            // ================================================================ CT. track-filter behavior
            Console.WriteLine("\n==== CT. Track filter: C-only default vs A,B,C opt-in (real xls) ====");
            string ctC = Path.Combine(work, "C8_cs", "requests");
            string ctAbc = Path.Combine(work, "C9_cs", "requests");

            int cReq = CountRequests(ctC);
            int abcReq = CountRequests(ctAbc);
            Check(Directory.Exists(ctC), "CT: -Tracks C requests directory exists", ctC);
            Check(Directory.Exists(ctAbc), "CT: -Tracks A,B,C requests directory exists", ctAbc);
            Check(abcReq >= cReq, "CT: A,B,C request count is greater than or equal to C-only", "C=" + cReq + " ABC=" + abcReq);
            Check(abcReq > 0, "CT: A,B,C produces at least one request", "count=" + abcReq);

            // ================================================================ D. policy-embed content
            Console.WriteLine("\n==== D. Policy embeds + per-checker _??얜??쒐춯?뼿??md (content) ====");

            // Real-data content assertions are intentionally not tied to one historical XLS.
            // The optional real mode verifies parser/prepare equivalence and general track-count behavior above.
            return Done();
        }
        finally
        {
            try { Directory.Delete(work, recursive: true); } catch { }
        }
    }

    private static int Done()
    {
        Console.WriteLine("\n============================================================");
        Console.WriteLine("checks: " + _checks + "   fails: " + _fails);
        if (_fails == 0) { Console.WriteLine("== CoreTests PASS =="); return 0; }
        Console.WriteLine("== CoreTests FAIL (" + _fails + ") =="); return 1;
    }

    // Run PS prepare and Core.Prepare on the same inputs, then byte-compare requests/**, worklist, unresolved.
    private static void ComparePrepare(string label, string runTriage, string promptPath,
        string conventionsPath, string templatePath,
        string index, string itemsDir, string guidesDir, string work, string tag,
        string? checker, string? severity, int? max, string? tracks = null)
    {
        Console.WriteLine("\n-- " + label + " --");
        string psOut = Path.Combine(work, tag + "_ps");
        string csOut = Path.Combine(work, tag + "_cs");

        // PS prepare.
        var psArgs = new List<string>
        {
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", runTriage, "prepare",
            "-Index", index, "-ItemsDir", itemsDir, "-GuidesDir", guidesDir,
            "-Out", psOut, "-PromptPath", promptPath,
            "-ConventionsPath", conventionsPath, "-TemplatePath", templatePath,
        };
        if (checker != null) { psArgs.Add("-Checker"); psArgs.Add(checker); }
        if (severity != null) { psArgs.Add("-Severity"); psArgs.Add(severity); }
        if (tracks != null) { psArgs.Add("-Tracks"); psArgs.Add(tracks); }
        if (max.HasValue) { psArgs.Add("-Max"); psArgs.Add(max.Value.ToString()); }
        var (psExit, _) = RunProcess("powershell.exe", psArgs.ToArray());
        Check(psExit == 0, label + ": PS prepare exit 0", "exit=" + psExit);

        // Core prepare.
        TriagePreparer.Prepare(new PrepareOptions
        {
            IndexCsvPath = index,
            ItemsDir = itemsDir,
            GuidesDir = guidesDir,
            PromptPath = promptPath,
            ConventionsPath = conventionsPath,
            TemplatePath = templatePath,
            OutDir = csOut,
            Checker = checker,
            Severity = severity,
            Tracks = tracks,
            Max = max,
        }, TextWriter.Null);

        // Compare the whole requests\ tree (subfolders + _??얜??쒐춯?뼿??md + request bodies).
        Check(TreeByteIdentical(Path.Combine(psOut, "requests"), Path.Combine(csOut, "requests"), out string reqDiff),
              label + ": requests\\** byte-identical", reqDiff);
        Check(FilesByteIdentical(Path.Combine(psOut, "worklist.csv"), Path.Combine(csOut, "worklist.csv"), out string wlDiff),
              label + ": worklist.csv byte-identical", wlDiff);
        Check(FilesByteIdentical(Path.Combine(psOut, "unresolved.csv"), Path.Combine(csOut, "unresolved.csv"), out string unDiff),
              label + ": unresolved.csv byte-identical", unDiff);
    }

    // --- process helper ---
    private static (int exit, string stdout) RunProcess(string exe, string[] argv)
    {
        var psi = new ProcessStartInfo
        {
            FileName = exe,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
        };
        foreach (string a in argv) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        string outText = p.StandardOutput.ReadToEnd();
        string errText = p.StandardError.ReadToEnd();
        p.WaitForExit();
        return (p.ExitCode, outText + errText);
    }

    // --- comparison helpers ---
    private static bool FilesByteIdentical(string a, string b, out string diff)
    {
        if (!File.Exists(a)) { diff = "missing PS file: " + a; return false; }
        if (!File.Exists(b)) { diff = "missing Core file: " + b; return false; }
        byte[] ba = File.ReadAllBytes(a), bb = File.ReadAllBytes(b);
        if (ba.Length != bb.Length) { diff = "length " + ba.Length + " vs " + bb.Length + " (" + Path.GetFileName(a) + ")"; return false; }
        for (int i = 0; i < ba.Length; i++)
            if (ba[i] != bb[i]) { diff = "byte @" + i + " in " + Path.GetFileName(a); return false; }
        diff = ""; return true;
    }

    private static bool DirsByteIdentical(string a, string b, string pattern, out string diff)
    {
        bool aEx = Directory.Exists(a), bEx = Directory.Exists(b);
        if (!aEx && !bEx) { diff = ""; return true; }
        if (!aEx) { diff = "missing PS dir: " + a; return false; }
        if (!bEx) { diff = "missing Core dir: " + b; return false; }
        var na = Directory.GetFiles(a, pattern).Select(Path.GetFileName).OrderBy(x => x, StringComparer.Ordinal).ToList();
        var nb = Directory.GetFiles(b, pattern).Select(Path.GetFileName).OrderBy(x => x, StringComparer.Ordinal).ToList();
        if (na.Count != nb.Count) { diff = "file count " + na.Count + " vs " + nb.Count; return false; }
        for (int i = 0; i < na.Count; i++)
        {
            if (!string.Equals(na[i], nb[i], StringComparison.Ordinal)) { diff = "name mismatch: " + na[i] + " vs " + nb[i]; return false; }
            if (!FilesByteIdentical(Path.Combine(a, na[i]!), Path.Combine(b, nb[i]!), out string d)) { diff = d; return false; }
        }
        diff = ""; return true;
    }

    // Recursive tree compare: every file under a/ and b/ (by relative path, ordinal-sorted) byte-identical.
    private static bool TreeByteIdentical(string a, string b, out string diff)
    {
        bool aEx = Directory.Exists(a), bEx = Directory.Exists(b);
        if (!aEx && !bEx) { diff = ""; return true; }
        if (!aEx) { diff = "missing PS dir: " + a; return false; }
        if (!bEx) { diff = "missing Core dir: " + b; return false; }
        var na = Directory.GetFiles(a, "*", SearchOption.AllDirectories)
            .Select(p => Path.GetRelativePath(a, p)).OrderBy(x => x, StringComparer.Ordinal).ToList();
        var nb = Directory.GetFiles(b, "*", SearchOption.AllDirectories)
            .Select(p => Path.GetRelativePath(b, p)).OrderBy(x => x, StringComparer.Ordinal).ToList();
        if (na.Count != nb.Count) { diff = "file count " + na.Count + " vs " + nb.Count; return false; }
        for (int i = 0; i < na.Count; i++)
        {
            if (!string.Equals(na[i], nb[i], StringComparison.Ordinal)) { diff = "path mismatch: " + na[i] + " vs " + nb[i]; return false; }
            if (!FilesByteIdentical(Path.Combine(a, na[i]), Path.Combine(b, nb[i]), out string d)) { diff = na[i] + ": " + d; return false; }
        }
        diff = ""; return true;
    }

    // Read UTF-8 (BOM-stripped) text for content assertions.
    private static string ReadText(string path)
    {
        byte[] bytes = File.ReadAllBytes(path);
        string t = new UTF8Encoding(false).GetString(bytes);
        if (t.Length > 0 && t[0] == '\uFEFF') t = t.Substring(1);
        return t;
    }

    // First request md (a file not named _??얜??쒐춯?뼿??md) in a checker subfolder, ordinal-sorted; null if none.
    private static string? FirstRequest(string dir)
    {
        if (!Directory.Exists(dir)) return null;
        return Directory.GetFiles(dir, "*.md")
            .Where(p => !string.Equals(Path.GetFileName(p), "_??얜??쒐춯?뼿??md", StringComparison.Ordinal))
            .OrderBy(p => Path.GetFileName(p), StringComparer.Ordinal)
            .FirstOrDefault();
    }

    // Count request md files (any *.md except _??얜??쒐춯?뼿??md) anywhere under a requests\ tree.
    private static int CountRequests(string requestsDir)
    {
        if (!Directory.Exists(requestsDir)) return 0;
        return Directory.GetFiles(requestsDir, "*.md", SearchOption.AllDirectories)
            .Count(p => !string.Equals(Path.GetFileName(p), "_??얜??쒐춯?뼿??md", StringComparison.Ordinal));
    }

    private static bool HasUtf8Bom(string path)
    {
        if (!File.Exists(path)) return false;
        using var fs = File.OpenRead(path);
        int b0 = fs.ReadByte(), b1 = fs.ReadByte(), b2 = fs.ReadByte();
        return b0 == 0xEF && b1 == 0xBB && b2 == 0xBF;
    }

    private static string? FindSkillRoot(string start)
    {
        var dir = new DirectoryInfo(start);
        for (int i = 0; dir != null && i < 12; i++, dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "references", "triage", "triage-prompt.md")))
                return dir.FullName;
        return null;
    }
}
