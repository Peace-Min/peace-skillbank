// Phase 0 spike for issue #29: prove ClrMD can, from a .dmp, do the six things the root-chain
// report needs:
//   (1) enumerate heap objects
//   (2) find instances of a candidate type
//   (3) enumerate GC roots
//   (4) shortest path candidate -> GC root (multi-source BFS from roots)
//   (5) group paths by signature + coverage accounting (rootReached / unresolved / truncated)
//   (6) run as a self-contained exe (see publish step)

using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.Diagnostics.Runtime;

namespace ClrMdRootChainReport
{
    internal static class Program
    {
        private static int Main(string[] args)
        {
            if (args.Length < 1)
            {
                Console.Error.WriteLine("usage: ClrMdRootChainReport <dump> [typeSubstr] [maxDepth]");
                return 2;
            }
            string dumpPath = args[0];
            string typeSub = args.Length > 1 ? args[1] : "DeviceViewModel";
            int maxDepth = args.Length > 2 ? int.Parse(args[2]) : 40;

            using DataTarget dt = DataTarget.LoadDump(dumpPath);
            using ClrRuntime runtime = dt.ClrVersions[0].CreateRuntime();
            ClrHeap heap = runtime.Heap;
            if (!heap.CanWalkHeap)
            {
                Console.Error.WriteLine("cannot walk heap");
                return 1;
            }

            // (1)+(2)
            var candidates = new HashSet<ulong>();
            long totalObjs = 0;
            foreach (ClrObject o in heap.EnumerateObjects())
            {
                totalObjs++;
                string tn = o.Type?.Name;
                if (tn != null && tn.Contains(typeSub)) candidates.Add(o.Address);
            }
            Console.WriteLine("heap objects:        " + totalObjs);
            Console.WriteLine("candidate '" + typeSub + "': " + candidates.Count);
            if (candidates.Count == 0) return 1;

            // (3) seed BFS with all root objects
            var parent = new Dictionary<ulong, ulong>();
            var depthOf = new Dictionary<ulong, int>();
            var rootKindOf = new Dictionary<ulong, string>();
            var q = new Queue<ulong>();
            int rootCount = 0;
            foreach (ClrRoot root in heap.EnumerateRoots())
            {
                rootCount++;
                ClrObject ro = root.Object;
                if (ro.IsNull) continue;
                if (!parent.ContainsKey(ro.Address))
                {
                    parent[ro.Address] = 0UL;
                    depthOf[ro.Address] = 0;
                    rootKindOf[ro.Address] = root.RootKind.ToString();
                    q.Enqueue(ro.Address);
                }
            }
            Console.WriteLine("GC roots:            " + rootCount);

            // (4) multi-source BFS -> shortest path from nearest root; stop when all candidates reached
            var reachedDepth = new Dictionary<ulong, int>();
            while (q.Count > 0 && reachedDepth.Count < candidates.Count)
            {
                ulong a = q.Dequeue();
                int d = depthOf[a];
                if (candidates.Contains(a) && !reachedDepth.ContainsKey(a)) reachedDepth[a] = d;
                if (d >= maxDepth) continue;
                ClrObject obj = heap.GetObject(a);
                foreach (ClrObject r in obj.EnumerateReferences(false, true))
                {
                    if (r.IsNull) continue;
                    if (!parent.ContainsKey(r.Address))
                    {
                        parent[r.Address] = a;
                        depthOf[r.Address] = d + 1;
                        q.Enqueue(r.Address);
                    }
                }
            }

            // (5) reconstruct shortest path per reached candidate, group by type-signature, count coverage
            var groups = new Dictionary<string, GroupInfo>();
            foreach (ulong c in reachedDepth.Keys)
            {
                var pathTypes = new List<string>();
                ulong cur = c, rootObj = c;
                while (cur != 0UL)
                {
                    ClrObject o = heap.GetObject(cur);
                    pathTypes.Add(ShortName(o.Type?.Name));
                    rootObj = cur;
                    cur = parent[cur];
                }
                pathTypes.Reverse();
                string sig = string.Join(" -> ", pathTypes);
                string rk = rootKindOf.TryGetValue(rootObj, out string k) ? k : "?";
                if (!groups.TryGetValue(sig, out GroupInfo gi))
                {
                    gi = new GroupInfo { RootKind = rk, Depth = pathTypes.Count - 1, Example = sig };
                    groups[sig] = gi;
                }
                gi.Count++;
            }

            int analyzed = candidates.Count;
            int reached = reachedDepth.Count;
            int unresolved = analyzed - reached;
            double coverage = analyzed == 0 ? 0 : (100.0 * reached / analyzed);

            Console.WriteLine();
            Console.WriteLine("=== coverage ===");
            Console.WriteLine("analyzed instances:  " + analyzed);
            Console.WriteLine("rootReached:         " + reached + "  (" + coverage.ToString("0.0") + "%)");
            Console.WriteLine("unresolved (>maxDepth or unrooted): " + unresolved);
            Console.WriteLine();
            Console.WriteLine("=== path groups (root -> ... -> candidate; shortest) ===");
            foreach (KeyValuePair<string, GroupInfo> kv in groups.OrderByDescending(g => g.Value.Count))
            {
                Console.WriteLine("  [" + kv.Value.Count + " objs] rootKind=" + kv.Value.RootKind +
                                  " depth=" + kv.Value.Depth);
                Console.WriteLine("     " + kv.Key);
            }
            return 0;
        }

        private sealed class GroupInfo { public int Count; public string RootKind; public int Depth; public string Example; }

        private static string ShortName(string full)
        {
            if (string.IsNullOrEmpty(full)) return "?";
            // trim generic noise + namespace for readability, keep last segment-ish
            int lt = full.IndexOf('<');
            string head = lt >= 0 ? full.Substring(0, lt) : full;
            int dot = head.LastIndexOf('.');
            string shortHead = dot >= 0 ? head.Substring(dot + 1) : head;
            return lt >= 0 ? shortHead + "<...>" : shortHead;
        }
    }
}
