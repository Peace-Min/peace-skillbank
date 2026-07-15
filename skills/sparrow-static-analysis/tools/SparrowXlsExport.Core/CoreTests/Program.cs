// CoreTests: loop-test harness proving the Core refactor is byte-faithful.
//
//   A. Console parse (real xls) produces the documented summary + 7170 items + BOM'd index.csv, exit 0.
//   B. Core.Run == console parse: byte-identical items/*, index.csv, checkers.md.
//   C. Core.Prepare == Run-Triage.ps1 prepare (CRITICAL): byte-identical requests/*, worklist.csv,
//      unresolved.csv on the fixture set AND the real 6827 subset (full, -Checker, -Severity/-Max).
//
// Prints PASS/FAIL per assertion; exits nonzero if any assertion fails. Run after a Release build of the
// Core, console, and CoreTests projects. The real xls path may be overridden as argv[0].

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

        string realXls = args.Length > 0 ? args[0] : @"C:\Users\CEO\Downloads\issues_OSTES_6827.xls";

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
        string consoleExe = Path.Combine(skillRoot, "tools", "SparrowXlsExport", "bin", "Release", "net8.0", "SparrowXlsExport.exe");

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
            Check(File.Exists(realXls), "precondition: real xls exists", realXls);
            Check(File.Exists(runTriage), "precondition: Run-Triage.ps1 exists", runTriage);
            Check(File.Exists(promptPath), "precondition: triage-prompt.md exists", promptPath);
            Check(File.Exists(conventionsPath), "precondition: project-conventions.md exists", conventionsPath);
            Check(File.Exists(templatePath), "precondition: folder-instruction-template.md exists", templatePath);
            if (_fails > 0) return Done();

            // ================================================================ A
            Console.WriteLine("\n==== A. Console parse identical (real xls) ====");
            string dirA = Path.Combine(work, "A_console");
            var (exitA, stdoutA) = RunProcess(consoleExe, new[] { realXls, "--out", dirA });
            Check(exitA == 0, "A: console exit 0", "exit=" + exitA);
            Check(stdoutA.Contains("total data rows:  7170"), "A: stdout total data rows: 7170");
            Check(stdoutA.Contains("unique checkers:  28"), "A: stdout unique checkers: 28");
            Check(stdoutA.Contains("severity counts:  낮음:5962 보통:978 매우위험:119 높음:93 위험:18"),
                  "A: stdout severity counts exact");
            string itemsA = Path.Combine(dirA, "items");
            int countA = Directory.Exists(itemsA) ? Directory.GetFiles(itemsA, "*.md").Length : 0;
            Check(countA == 7170, "A: items = 7170 md files", "found=" + countA);
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

            // C2: real full (7170 rows; mixed resolved/unresolved, exercises unresolved.csv at scale).
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

            // C5: real -Severity 매우위험 -Max 50 (severity set filter + max cap).
            ComparePrepare("C5 real-severity-max", runTriage, promptPath, conventionsPath, templatePath,
                realIndex, realItems, guidesDir, work, "C5",
                checker: null, severity: "매우위험", max: 50);

            // C6: real -Checker OVERLY_BROAD_CATCH (per-checker mandate embed path).
            ComparePrepare("C6 real-OVERLY_BROAD_CATCH", runTriage, promptPath, conventionsPath, templatePath,
                realIndex, realItems, guidesDir, work, "C6",
                checker: "OVERLY_BROAD_CATCH", severity: null, max: null);

            // C7: real -Checker EMPTY_CATCH_BLOCK (per-checker mandate embed path).
            ComparePrepare("C7 real-EMPTY_CATCH_BLOCK", runTriage, promptPath, conventionsPath, templatePath,
                realIndex, realItems, guidesDir, work, "C7",
                checker: "EMPTY_CATCH_BLOCK", severity: null, max: null);

            // ================================================================ D. policy-embed content
            Console.WriteLine("\n==== D. Policy embeds + per-checker _작업지침.md (content) ====");

            // OVERLY_BROAD_CATCH folder instruction (from the C6 Core output).
            string obcDir = Path.Combine(work, "C6_cs", "requests", "OVERLY_BROAD_CATCH");
            string obcInstr = Path.Combine(obcDir, "_작업지침.md");
            Check(File.Exists(obcInstr), "D: OVERLY_BROAD_CATCH\\_작업지침.md exists", obcInstr);
            string obcInstrText = File.Exists(obcInstr) ? ReadText(obcInstr) : "";
            Check(obcInstrText.Contains("catch(Exception)"), "D: 작업지침 has catch(Exception) 금지");
            Check(obcInstrText.Contains("명시 catch"), "D: 작업지침 has 명시 catch");
            Check(obcInstrText.Contains("위양성 사용 금지"), "D: 작업지침 has 위양성 사용 금지");

            string? obcReq = FirstRequest(obcDir);
            Check(obcReq != null, "D: OVERLY_BROAD_CATCH has ≥1 request", obcDir);
            string obcReqText = obcReq != null ? ReadText(obcReq) : "";
            Check(obcReqText.Contains("## 처리 정책 (이 프로젝트)"), "D: OBC request has 처리 정책 embed");
            Check(obcReqText.Contains("catch(Exception)") && obcReqText.Contains("명시 catch"),
                  "D: OBC request has OVERLY_BROAD_CATCH mandate");

            // EMPTY_CATCH_BLOCK request (from the C7 Core output).
            string ecbDir = Path.Combine(work, "C7_cs", "requests", "EMPTY_CATCH_BLOCK");
            string? ecbReq = FirstRequest(ecbDir);
            Check(ecbReq != null, "D: EMPTY_CATCH_BLOCK has ≥1 request", ecbDir);
            string ecbReqText = ecbReq != null ? ReadText(ecbReq) : "";
            Check(ecbReqText.Contains("LogUtil.Error"), "D: ECB request has LogUtil.Error rule");
            Check(ecbReqText.Contains("Console.WriteLine(\"Exception\")") && ecbReqText.Contains("오답"),
                  "D: ECB request flags Console.WriteLine(\"Exception\")…오답");

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
        string? checker, string? severity, int? max)
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
            Max = max,
        }, TextWriter.Null);

        // Compare the whole requests\ tree (subfolders + _작업지침.md + request bodies).
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
        if (t.Length > 0 && t[0] == '﻿') t = t.Substring(1);
        return t;
    }

    // First request md (a file not named _작업지침.md) in a checker subfolder, ordinal-sorted; null if none.
    private static string? FirstRequest(string dir)
    {
        if (!Directory.Exists(dir)) return null;
        return Directory.GetFiles(dir, "*.md")
            .Where(p => !string.Equals(Path.GetFileName(p), "_작업지침.md", StringComparison.Ordinal))
            .OrderBy(p => Path.GetFileName(p), StringComparer.Ordinal)
            .FirstOrDefault();
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
