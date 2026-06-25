// ClrMdRootChainReport (issue #29 Phase 2): from an after.dmp + a candidate type list, produce
// managed paths-to-root grouped by signature, with coverage accounting, as JSON + MD + HTML.
//
// Design points baked in:
//  - STICKY-root preference: a leak's real root is sticky (any non-Stack root: StrongHandle / handle /
//    finalizer; a static field surfaces as StrongHandle -> Object[] -> holder in this ClrMD build, NOT
//    as a "Static" kind). A Stack root means "currently in use", not leaked. Two-phase BFS claims from
//    sticky roots first, then
//    stack roots, so a sticky path wins whenever one exists. rootKind is reported either way.
//  - path GROUPS + coverage, not top-N raw paths: every candidate instance is bucketed by its shortest
//    path signature; we report rootReached vs unresolved (>max-depth / unrooted).
//  - max-depth is a SAFETY cap, not a guarantee. Unreached instances are reported as unresolved.
//  - bounded: candidate types come pre-narrowed; instances analyzed per type are capped.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using Microsoft.Diagnostics.Runtime;

namespace ClrMdRootChainReport
{
    internal static class Program
    {
        private static int Main(string[] args)
        {
            string dumpPath = null, outDir = ".";
            int maxDepth = 40, maxInstances = 20000;
            long maxNodes = 5_000_000;   // safety budget: bound the whole-heap BFS so a multi-GB dump can't OOM the tool
            var wantTypes = new List<string>();
            for (int i = 0; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--types": wantTypes.AddRange(args[++i].Split(',')); break;
                    // one type per line -- robust against commas inside generic type names.
                    case "--types-file": wantTypes.AddRange(File.ReadAllLines(args[++i])); break;
                    case "--out": outDir = args[++i]; break;
                    case "--max-depth": maxDepth = int.Parse(args[++i]); break;
                    case "--max-instances": maxInstances = int.Parse(args[++i]); break;
                    case "--max-nodes": maxNodes = long.Parse(args[++i]); break;
                    default: dumpPath = dumpPath ?? args[i]; break;
                }
            }
            if (dumpPath == null)
            {
                Console.Error.WriteLine("usage: ClrMdRootChainReport <dump> [--types A,B,C | --types-file f] [--out dir] [--max-depth N] [--max-instances N] [--max-nodes N]");
                return 2;
            }
            wantTypes = wantTypes.Select(s => s.Trim()).Where(s => s.Length > 0).Distinct().ToList();

            using DataTarget dt = DataTarget.LoadDump(dumpPath);
            using ClrRuntime runtime = dt.ClrVersions[0].CreateRuntime();
            ClrHeap heap = runtime.Heap;
            if (!heap.CanWalkHeap) { Console.Error.WriteLine("cannot walk heap"); return 1; }

            // 1+2: collect candidate instances (capped per type). If no --types, fall back to "everything app-ish".
            var instancesByType = new Dictionary<string, List<ulong>>();
            var totalByType = new Dictionary<string, long>();
            foreach (ClrObject o in heap.EnumerateObjects())
            {
                string tn = o.Type?.Name;
                if (tn == null) continue;
                string key = MatchKey(tn, wantTypes);
                if (key == null) continue;
                totalByType.TryGetValue(key, out long tot); totalByType[key] = tot + 1;
                if (!instancesByType.TryGetValue(key, out var lst)) { lst = new List<ulong>(); instancesByType[key] = lst; }
                if (lst.Count < maxInstances) lst.Add(o.Address);
            }
            if (instancesByType.Count == 0) { Console.Error.WriteLine("no candidate instances found"); return 1; }

            // 3: split roots sticky vs stack
            var sticky = new List<(ulong addr, string kind)>();
            var stack = new List<(ulong addr, string kind)>();
            foreach (ClrRoot root in heap.EnumerateRoots())
            {
                ClrObject ro = root.Object;
                if (ro.IsNull) continue;
                string kind = root.RootKind.ToString();
                if (kind == "Stack") stack.Add((ro.Address, kind)); else sticky.Add((ro.Address, kind));
            }

            // 4: two-phase BFS (sticky first, then stack) -> parent/depth/rootKind maps.
            // depthCapped/nodeBudgetHit keep the limits HONEST: an unresolved instance may simply lie
            // beyond max-depth or the node budget rather than being genuinely unrooted, and we say so.
            var parent = new Dictionary<ulong, ulong>();
            var depthOf = new Dictionary<ulong, int>();
            var rootKindOf = new Dictionary<ulong, string>();
            bool depthCapped = false, nodeBudgetHit = false;
            void Bfs(List<(ulong addr, string kind)> roots)
            {
                var q = new Queue<ulong>();
                foreach (var (addr, kind) in roots)
                {
                    if (parent.ContainsKey(addr)) continue;
                    parent[addr] = 0UL; depthOf[addr] = 0; rootKindOf[addr] = kind; q.Enqueue(addr);
                }
                while (q.Count > 0)
                {
                    if (parent.Count >= maxNodes) { nodeBudgetHit = true; break; }  // bound memory on huge heaps
                    ulong a = q.Dequeue();
                    int d = depthOf[a];
                    if (d >= maxDepth) { depthCapped = true; continue; }            // exploration cut by depth
                    ClrObject obj = heap.GetObject(a);
                    foreach (ClrObject r in obj.EnumerateReferences(false, true))
                    {
                        if (r.IsNull || parent.ContainsKey(r.Address)) continue;
                        parent[r.Address] = a; depthOf[r.Address] = d + 1; q.Enqueue(r.Address);
                    }
                }
            }
            Bfs(sticky);
            Bfs(stack);

            // 5: per type, group reached instances by path signature; coverage accounting
            var report = new List<object>();
            foreach (var kv in instancesByType.OrderByDescending(k => totalByType[k.Key]))
            {
                string type = kv.Key;
                var analyzed = kv.Value;
                var groups = new Dictionary<string, GroupInfo>();
                int reached = 0;
                foreach (ulong c in analyzed)
                {
                    if (!parent.ContainsKey(c)) continue; // unresolved: beyond max-depth/node-budget OR unrooted
                    reached++;
                    var nodes = new List<string>();
                    ulong cur = c, rootObj = c;
                    while (cur != 0UL) { nodes.Add(ShortName(heap.GetObject(cur).Type?.Name)); rootObj = cur; cur = parent[cur]; }
                    nodes.Reverse();
                    string sig = string.Join(" -> ", nodes);
                    string rk = rootKindOf.TryGetValue(rootObj, out string k) ? k : "?";
                    if (!groups.TryGetValue(sig, out GroupInfo gi))
                    { gi = new GroupInfo { RootKind = rk, Depth = nodes.Count - 1, Nodes = nodes }; groups[sig] = gi; }
                    gi.Count++;
                }
                int unresolved = analyzed.Count - reached;
                report.Add(new
                {
                    type,
                    totalInstances = totalByType[type],
                    analyzedInstances = analyzed.Count,
                    sampled = analyzed.Count < totalByType[type],   // analyzed is a head-of-heap sample when true
                    rootReached = reached,
                    unresolved,
                    coveragePctOfAnalyzed = analyzed.Count == 0 ? 0.0 : Math.Round(100.0 * reached / analyzed.Count, 1),
                    pathGroups = groups.OrderByDescending(g => g.Value.Count).Select(g => new
                    {
                        objects = g.Value.Count,
                        rootKind = g.Value.RootKind,
                        sticky = g.Value.RootKind != "Stack",
                        depth = g.Value.Depth,
                        signature = g.Key,
                        nodes = g.Value.Nodes
                    }).ToList()
                });
            }

            Directory.CreateDirectory(outDir);
            var bundle = new
            {
                dump = Path.GetFullPath(dumpPath),
                maxDepth,
                maxNodes,
                nodesVisited = (long)parent.Count,
                depthCapped,        // exploration was cut by max-depth somewhere
                nodeBudgetHit,      // BFS aborted at the node budget -> coverage is partial
                candidates = report
            };
            File.WriteAllText(Path.Combine(outDir, "reference-chains.json"),
                JsonSerializer.Serialize(bundle, new JsonSerializerOptions { WriteIndented = true }));
            File.WriteAllText(Path.Combine(outDir, "reference-chains.md"), RenderMarkdown(report, maxDepth, depthCapped, nodeBudgetHit), new UTF8Encoding(false));
            File.WriteAllText(Path.Combine(outDir, "reference-chains.html"), RenderHtml(report), new UTF8Encoding(false));

            Console.WriteLine("wrote reference-chains.{json,md,html} to " + Path.GetFullPath(outDir));
            if (nodeBudgetHit) Console.WriteLine($"  NOTE: node budget ({maxNodes}) hit -- coverage is partial; raise --max-nodes if RAM allows.");
            foreach (dynamic r in report)
                Console.WriteLine($"  {r.type}: total={r.totalInstances} reached={r.rootReached}/{r.analyzedInstances} ({r.coveragePctOfAnalyzed}% of analyzed) groups={((System.Collections.ICollection)r.pathGroups).Count}");
            return 0;
        }

        private sealed class GroupInfo { public int Count; public string RootKind; public int Depth; public List<string> Nodes; }

        private static string MatchKey(string clrName, List<string> wanted)
        {
            if (wanted.Count == 0) return clrName; // no filter -> all (caller usually passes --types)
            string cSimple = SimpleName(clrName, out bool cArr);
            bool cNs = HasNamespace(clrName);
            foreach (string w in wanted)
            {
                if (clrName == w) return w;                       // exact full-name fast path
                string wSimple = SimpleName(w, out bool wArr);    // else match leading type name + array-ness,
                if (cArr == wArr && cSimple == wSimple)           // so Dictionary<...,DeviceViewModel> != "DeviceViewModel".
                {
                    // Guard a cross-namespace collision: if BOTH are namespaced and not exact-equal, they
                    // are different types (Foo.Bar must not absorb Baz.Bar). Only fall back to the simple
                    // name when at least one side is namespace-free (e.g. gcdump lists "RuntimeTypeCache").
                    if (!cNs || !HasNamespace(w)) return w;
                }
            }
            return null;
        }

        private static bool HasNamespace(string n)
        {
            string s = n ?? "";
            int cut = s.IndexOf('<'); if (cut >= 0) s = s.Substring(0, cut);
            cut = s.IndexOf('['); if (cut >= 0) s = s.Substring(0, cut);
            return s.Contains('.');
        }

        // Leading type name without namespace / generic args, plus whether it is an array.
        private static string SimpleName(string n, out bool isArray)
        {
            string s = (n ?? "").Trim();
            isArray = s.EndsWith("[]");
            int lt = s.IndexOf('<');
            if (lt >= 0) s = s.Substring(0, lt);          // drop generic args (and anything after)
            s = s.TrimEnd();
            while (s.EndsWith("[]")) s = s.Substring(0, s.Length - 2);
            int dot = s.LastIndexOf('.');
            return dot >= 0 ? s.Substring(dot + 1) : s;
        }

        private static string ShortName(string full)
        {
            if (string.IsNullOrEmpty(full)) return "?";
            int lt = full.IndexOf('<');
            string head = lt >= 0 ? full.Substring(0, lt) : full;
            int dot = head.LastIndexOf('.');
            string s = dot >= 0 ? head.Substring(dot + 1) : head;
            return lt >= 0 ? s + "<...>" : s;
        }

        private static string RenderMarkdown(List<object> report, int maxDepth, bool depthCapped, bool nodeBudgetHit)
        {
            var sb = new StringBuilder();
            sb.AppendLine("## Reference-chain evidence (from after.dmp)");
            sb.AppendLine();
            sb.AppendLine("Root-chain evidence shows *why* candidates are still alive. A **sticky** root (any non-Stack root --");
            sb.AppendLine("StrongHandle / PinnedHandle / FinalizerQueue) indicates retention; a `Stack` root means the object is");
            sb.AppendLine("currently in use, not leaked. NOTE: a leaked **static field** surfaces as");
            sb.AppendLine("`StrongHandle -> Object[] -> <holder>` in this ClrMD build (there is no `Static` root kind), so read a");
            sb.AppendLine("StrongHandle into an `Object[]` as a likely static/runtime root. Native allocations are not traced");
            sb.AppendLine("unless retained by a managed wrapper.");
            sb.AppendLine();
            sb.AppendLine($"Limits: shortest path is searched to max-depth {maxDepth}; the heap walk is bounded by a node budget.");
            string capNote = (nodeBudgetHit ? " Node budget WAS hit -- coverage is partial; raise --max-nodes if RAM allows."
                              : depthCapped ? " Max-depth WAS hit on some paths." : "");
            sb.AppendLine("**Unresolved** instances may lie beyond these caps rather than being truly unrooted -- treat them as");
            sb.AppendLine("incomplete evidence, not \"no leak\"." + capNote);
            sb.AppendLine();
            foreach (dynamic r in report)
            {
                sb.AppendLine($"### Candidate: {r.type}");
                string samp = r.sampled ? $" (head-of-heap sample of {r.totalInstances})" : "";
                sb.AppendLine($"Total instances: {r.totalInstances}  |  analyzed: {r.analyzedInstances}{samp}  |  rootReached: {r.rootReached} ({r.coveragePctOfAnalyzed}% of analyzed)  |  unresolved: {r.unresolved}");
                sb.AppendLine();
                sb.AppendLine("Path groups (shortest path, root -> ... -> candidate):");
                foreach (dynamic g in r.pathGroups)
                {
                    string tag = g.sticky ? "STICKY" : "stack(in-use?)";
                    sb.AppendLine($"- [{g.objects} objs] root={g.rootKind} ({tag}), depth={g.depth}");
                    sb.AppendLine($"    {g.signature}");
                }
                sb.AppendLine();
            }
            return sb.ToString();
        }

        private static string RenderHtml(List<object> report)
        {
            var sb = new StringBuilder();
            sb.AppendLine("<!doctype html><meta charset=\"utf-8\"><title>Reference chains</title>");
            sb.AppendLine("<style>body{font:14px system-ui;margin:2rem}h3{margin-top:1.5rem}table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:4px 8px;text-align:left}.s{color:#b00;font-weight:600}.t{color:#888}</style>");
            sb.AppendLine("<h1>Reference-chain evidence (after.dmp)</h1>");
            foreach (dynamic r in report)
            {
                sb.AppendLine($"<h3>{Esc((string)r.type)}</h3>");
                sb.AppendLine($"<p>total {r.totalInstances} &middot; analyzed {r.analyzedInstances} &middot; rootReached {r.rootReached} ({r.coveragePctOfAnalyzed}% of analyzed) &middot; unresolved {r.unresolved}</p>");
                sb.AppendLine("<table><tr><th>objs</th><th>root</th><th>depth</th><th>path</th></tr>");
                foreach (dynamic g in r.pathGroups)
                {
                    string cls = g.sticky ? "s" : "t";
                    sb.AppendLine($"<tr><td>{g.objects}</td><td class=\"{cls}\">{Esc((string)g.rootKind)}</td><td>{g.depth}</td><td>{Esc((string)g.signature)}</td></tr>");
                }
                sb.AppendLine("</table>");
            }
            return sb.ToString();
        }

        private static string Esc(string s) => (s ?? "").Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");
    }
}
