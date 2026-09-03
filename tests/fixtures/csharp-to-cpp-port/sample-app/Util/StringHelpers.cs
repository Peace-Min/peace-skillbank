using System.Collections.Generic;
using System.Text;

namespace SampleApp.Util
{
    public static class StringHelpers
    {
        public static string PadId(int id)
        {
            return id.ToString().PadLeft(4, '0');
        }

        public static string JoinLines(IEnumerable<string> lines)
        {
            var sb = new StringBuilder();
            bool first = true;
            foreach (string line in lines)
            {
                if (!first) sb.Append('\n');
                sb.Append(line);
                first = false;
            }
            return sb.ToString();
        }

        public static bool IsBlank(string value)
        {
            return string.IsNullOrWhiteSpace(value);
        }
    }
}
