// SparrowXlsExport: deterministic CLI that reads a Sparrow (파수 정적분석) result .xls (real BIFF/OLE2,
// or .xlsx) WITHOUT Excel/COM, and splits it into per-item markdown + an index + a per-checker worklist.
// Purpose: take all xls/xlsx parsing out of a weak local LLM's hands in an air-gapped environment.
//
// This is a THIN CLI wrapper. All parsing/output logic lives in SparrowXlsExport.Core.SparrowExporter,
// which the WPF GUI also calls in-process. This file only parses args + maps exceptions to exit codes;
// the stdout summary is produced by Core writing to Console.Out, so it stays byte-identical.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using SparrowXlsExport.Core;

namespace SparrowXlsExport
{
    internal static class Program
    {
        private static int Main(string[] args)
        {
            try { Console.OutputEncoding = new UTF8Encoding(false); } catch { /* stdout may be redirected */ }

            string? input = null, outDir = null, checker = null, status = null, rootPath = null, filesFrom = null;
            var severities = new HashSet<string>(StringComparer.Ordinal);
            int? max = null;

            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i];
                switch (a)
                {
                    case "--out": if (!TryNext(args, ref i, out outDir)) return Usage("--out requires a value"); break;
                    case "--root": if (!TryNext(args, ref i, out rootPath)) return Usage("--root requires a value"); break;
                    case "--files-from": if (!TryNext(args, ref i, out filesFrom)) return Usage("--files-from requires a value"); break;
                    case "--checker": if (!TryNext(args, ref i, out checker)) return Usage("--checker requires a value"); break;
                    case "--status": if (!TryNext(args, ref i, out status)) return Usage("--status requires a value"); break;
                    case "--severity":
                        if (!TryNext(args, ref i, out string sevArg)) return Usage("--severity requires a value");
                        foreach (string s in sevArg.Split(',').Select(x => x.Trim()).Where(x => x.Length > 0)) severities.Add(s);
                        break;
                    case "--max":
                        if (!TryNext(args, ref i, out string maxArg)) return Usage("--max requires a value");
                        if (!int.TryParse(maxArg, NumberStyles.Integer, CultureInfo.InvariantCulture, out int mv)) return Usage("--max must be an integer");
                        max = mv;
                        break;
                    default:
                        if (a.StartsWith("--", StringComparison.Ordinal)) return Usage("unknown option: " + a);
                        if (input == null) input = a; else return Usage("unexpected argument: " + a);
                        break;
                }
            }

            if (input == null) return Usage("input file is required");

            try
            {
                var opts = new ExportOptions
                {
                    InputPath = input,
                    OutDir = outDir,
                    Checker = checker,
                    Status = status,
                    RootPath = rootPath,
                    FilesFrom = filesFrom,
                    Severities = severities,
                    Max = max,
                };
                SparrowExporter.Run(opts, Console.Out);   // Core writes the identical stdout summary.
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("error: " + ex.Message);
                return 1;   // runtime error: file unreadable / not a workbook / IO failure
            }
        }

        private static bool TryNext(string[] args, ref int i, out string value)
        {
            if (i + 1 >= args.Length) { value = ""; return false; }
            value = args[++i];
            return true;
        }

        private static int Usage(string message)
        {
            Console.Error.WriteLine("error: " + message);
            Console.Error.WriteLine("usage: SparrowXlsExport <input.xls> [--out DIR] [--root SRC_ROOT] [--files-from FILES.csv] [--severity 낮음,보통,높음] [--checker SUBSTR] [--status SUBSTR] [--max N]");
            return 2;
        }
    }
}
