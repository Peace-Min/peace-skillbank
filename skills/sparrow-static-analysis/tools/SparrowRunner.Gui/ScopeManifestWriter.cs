using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace SparrowRunner.Gui
{
    public static class ScopeManifestWriter
    {
        public static string WriteTemp(IReadOnlyCollection<string> selectedFiles)
        {
            string path = Path.Combine(Path.GetTempPath(), "sparrow-scope-" + Guid.NewGuid().ToString("N") + ".csv");
            Write(path, selectedFiles);
            return path;
        }

        public static void Write(string path, IReadOnlyCollection<string> selectedFiles)
        {
            var sb = new StringBuilder();
            sb.AppendLine("파일명");
            foreach (string file in selectedFiles
                         .Select(Path.GetFullPath)
                         .Distinct(StringComparer.OrdinalIgnoreCase)
                         .OrderBy(p => p, StringComparer.OrdinalIgnoreCase))
            {
                sb.Append('"').Append(file.Replace("\"", "\"\"")).AppendLine("\"");
            }

            File.WriteAllText(path, sb.ToString(), new UTF8Encoding(false));
        }
    }
}
