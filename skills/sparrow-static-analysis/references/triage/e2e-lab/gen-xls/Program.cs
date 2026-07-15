// GenXls: emits two Sparrow-style .xls workbooks (real BIFF via NPOI HSSF) for the E2E test:
//   sample-before.xls  = all 5 planted defects (미해결)
//   sample-after.xls   = post-fix rescan: only the OVERLY_BROAD_CATCH row remains (보류 — not fixed yet);
//                        the 4 수정 checkers' rows are removed. No NEW (checker,file,line).
// Sheet name 'issues'. Header + the well-known Sparrow columns the parser keys on:
//   ID, 체커 키, 체커명, 위험도, 파일명, 라인, 이슈 상태, 체커 설명, 소스 코드
// Values (체커 키/체커명/위험도/체커 설명) are verbatim from the tool's real checkers.md.

using System;
using System.IO;
using NPOI.HSSF.UserModel;
using NPOI.SS.UserModel;

namespace GenXls
{
    internal sealed class Defect
    {
        public int Id;
        public string CheckerKey = "";
        public string CheckerName = "";
        public string Severity = "";
        public string File = "";
        public int Line;
        public string Status = "";
        public string Desc = "";
        public string Source = "";
        public bool InAfter;   // true = still present after the fix rescan (보류 item, not fixed yet)
    }

    internal static class Program
    {
        private static readonly string[] Headers =
        {
            "ID", "체커 키", "체커명", "위험도", "파일명", "라인", "이슈 상태", "체커 설명", "소스 코드",
        };

        private static readonly Defect[] Defects =
        {
            new Defect {
                Id = 9001, CheckerKey = "FORWARD_NULL", CheckerName = "널 역참조", Severity = "매우위험",
                File = "NullDeref.cs", Line = 11, Status = "미해결",
                Desc = "널 값 역참조 체커는 널 상수나 널이 할당된 변수를 역참조하는 경우를 검출합니다.",
                Source = "            return node.Value;", InAfter = false,
            },
            new Defect {
                Id = 9002, CheckerKey = "RESOURCE_LEAK", CheckerName = "자원 누수", Severity = "매우위험",
                File = "LeakFile.cs", Line = 9, Status = "미해결",
                Desc = "리소스 누수 체커는 파일, 소켓 등 리소스를 할당한 후에 해제하지 않는 코드를 검출합니다.",
                Source = "            var fs = new FileStream(path, FileMode.Open);", InAfter = false,
            },
            new Defect {
                Id = 9003, CheckerKey = "EMPTY_CATCH_BLOCK", CheckerName = "빈 catch 블록", Severity = "높음",
                File = "SwallowEx.cs", Line = 13, Status = "미해결",
                Desc = "빈 예외 처리 블록 체커는 예외를 처리하는 코드 내용이 없는 예외 처리 블록을 검출합니다.",
                Source = "            catch { }", InAfter = false,
            },
            new Defect {
                Id = 9004, CheckerKey = "OVERLY_BROAD_CATCH", CheckerName = "지나치게 일반적인 예외 처리", Severity = "보통",
                File = "BroadCatch.cs", Line = 13, Status = "미해결",
                Desc = "지나치게 일반적인 예외 처리 체커는 너무 다양한 예외를 포괄적으로 처리하는 코드를 검출합니다.",
                Source = "            catch (Exception ex)", InAfter = true,
            },
            new Defect {
                Id = 9005, CheckerKey = "NULL_RETURN_STD", CheckerName = "표준 라이브러리의 널 반환 값 역참조", Severity = "매우위험",
                File = "BclNull.cs", Line = 10, Status = "미해결",
                Desc = "표준 라이브러리 널 반환 값 역참조 체커는 C# 표준 라이브러리 메소드 중에서 널을 반환할 가능성이 있는 메소드의 반환 값을 확인 없이 역참조하는 경우를 검출합니다.",
                Source = "            return Activator.CreateInstance(t);", InAfter = false,
            },
        };

        private static int Main(string[] args)
        {
            if (args.Length < 1)
            {
                Console.Error.WriteLine("usage: GenXls <outDir>");
                return 2;
            }
            string outDir = Path.GetFullPath(args[0]);
            Directory.CreateDirectory(outDir);

            string beforePath = Path.Combine(outDir, "sample-before.xls");
            string afterPath = Path.Combine(outDir, "sample-after.xls");

            WriteWorkbook(beforePath, onlyAfter: false);
            WriteWorkbook(afterPath, onlyAfter: true);

            Console.WriteLine("wrote " + beforePath);
            Console.WriteLine("wrote " + afterPath);
            return 0;
        }

        private static void WriteWorkbook(string path, bool onlyAfter)
        {
            IWorkbook wb = new HSSFWorkbook();
            ISheet sheet = wb.CreateSheet("issues");

            IRow header = sheet.CreateRow(0);
            for (int c = 0; c < Headers.Length; c++) header.CreateCell(c).SetCellValue(Headers[c]);

            int rowIdx = 1;
            foreach (Defect d in Defects)
            {
                if (onlyAfter && !d.InAfter) continue;   // after = post-fix rescan
                IRow row = sheet.CreateRow(rowIdx++);
                row.CreateCell(0).SetCellValue((double)d.Id);     // ID numeric -> renders without ".0"
                row.CreateCell(1).SetCellValue(d.CheckerKey);
                row.CreateCell(2).SetCellValue(d.CheckerName);
                row.CreateCell(3).SetCellValue(d.Severity);
                row.CreateCell(4).SetCellValue(d.File);
                row.CreateCell(5).SetCellValue((double)d.Line);   // 라인 numeric
                row.CreateCell(6).SetCellValue(d.Status);
                row.CreateCell(7).SetCellValue(d.Desc);
                row.CreateCell(8).SetCellValue(d.Source);
            }

            string? dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            using (FileStream fs = File.Create(path)) wb.Write(fs);
        }
    }
}
