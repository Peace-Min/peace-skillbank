// Phase 0 synthetic leak: two DISTINCT retention paths to the same candidate type, so the ClrMD
// probe's path-grouping has something real to group.
//   (1) static cache path:  s_manager -> Dictionary -> DeviceViewModel
//   (2) timer path:         (timer queue) -> Timer -> TimerHolder -> List -> DeviceViewModel
// Then it writes its own heap dump (DumpType.WithHeap == `dotnet-dump --type heap`).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;
using Microsoft.Diagnostics.NETCore.Client;

namespace LeakSample
{
    internal sealed class DeviceViewModel
    {
        public int Id;
        public byte[] Buffer;
        public DeviceViewModel(int id) { Id = id; Buffer = new byte[2000]; }
    }

    internal sealed class DeviceManager
    {
        public Dictionary<int, DeviceViewModel> Devices = new Dictionary<int, DeviceViewModel>();
    }

    internal sealed class TimerHolder
    {
        public List<DeviceViewModel> Held = new List<DeviceViewModel>();
    }

    internal static class Program
    {
        // (1) static GC root
        private static DeviceManager s_manager = new DeviceManager();

        private static int Main(string[] args)
        {
            string outPath = args.Length > 0 ? args[0] : "after.dmp";
            int staticN = args.Length > 1 ? int.Parse(args[1]) : 8000;

            // (1) static cache path
            for (int i = 0; i < staticN; i++)
                s_manager.Devices[i] = new DeviceViewModel(i);

            // (2) timer path: a Timer kept alive by the runtime timer queue; its state holds DeviceViewModels.
            var holder = new TimerHolder();
            for (int i = 0; i < 1000; i++)
                holder.Held.Add(new DeviceViewModel(1_000_000 + i));
            // Local on purpose -- the runtime timer infrastructure roots it, NOT an app static.
            var timer = new Timer(static state => GC.KeepAlive(state), holder, 0, 60_000);

            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();

            if (System.IO.File.Exists(outPath)) System.IO.File.Delete(outPath);
            int pid = Process.GetCurrentProcess().Id;
            var client = new DiagnosticsClient(pid);
            client.WriteDump(DumpType.WithHeap, outPath);

            Console.WriteLine("wrote heap dump: " + outPath);
            Console.WriteLine("  DeviceViewModel total = " + (staticN + 1000) +
                              " (static cache=" + staticN + ", timer path=1000)");

            GC.KeepAlive(s_manager);
            GC.KeepAlive(timer);
            return 0;
        }
    }
}
