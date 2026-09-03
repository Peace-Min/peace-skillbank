using System;
using System.Collections.Generic;
using SampleApp.Models;
using SampleApp.Services;
using SampleApp.Util;

namespace SampleApp
{
    internal static class Program
    {
        private static int Main(string[] args)
        {
            DeviceKind filter = DeviceKind.Sensor;
            if (args.Length > 0 && !StringHelpers.IsBlank(args[0]))
            {
                if (!Enum.TryParse(args[0], true, out filter))
                {
                    Console.WriteLine("unknown kind: " + args[0]);
                    return 2;
                }
            }

            using (var logger = new Logger(null))
            {
                var repo = new DeviceRepository(logger);
                var added = new List<string>();
                repo.DeviceAdded += (sender, device) => added.Add(device.Name);

                repo.Add(new Device(3, "thermo-b", DeviceKind.Sensor));
                repo.Add(new Device(1, "valve-1", DeviceKind.Actuator));
                repo.Add(new Device(2, "thermo-a", DeviceKind.Sensor));
                repo.Add(new Device(7, "edge-gw", DeviceKind.Gateway));

                Console.WriteLine("added: " + StringHelpers.JoinLines(added).Replace('\n', ','));
                Console.WriteLine("count: " + repo.Count);
                Console.WriteLine("장치 수: " + repo.Count);

                int touched = repo.RefreshAsync(42).GetAwaiter().GetResult();
                Console.WriteLine("touched: " + touched);

                foreach (Device d in repo.FindByKind(filter))
                {
                    Console.WriteLine(d.Describe());
                }

                Device missing = repo.Find(99);
                Console.WriteLine("find(99): " + (missing == null ? "null" : missing.Name));
                Console.WriteLine("online(2): " + repo.Find(2).IsOnline);
                Console.WriteLine("ratio: " + (repo.Count / 8.0));
                Console.WriteLine("ratio2: " + (repo.Count / 3.0).ToString("F2"));
                Console.WriteLine("clock: " + (NativeMethods.ClockIsRunning() ? "running" : "stopped"));
                Console.WriteLine("log lines: " + logger.Count);
            }

            return 0;
        }
    }
}
