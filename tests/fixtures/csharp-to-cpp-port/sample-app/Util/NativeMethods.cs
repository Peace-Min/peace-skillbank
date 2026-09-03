using System.Runtime.InteropServices;

namespace SampleApp.Util
{
    internal static class NativeMethods
    {
        [DllImport("kernel32.dll")]
        internal static extern uint GetTickCount();

        internal static bool ClockIsRunning()
        {
            return GetTickCount() > 0;
        }
    }
}
