# ClrMdRootChainReport

Managed **paths-to-root** reporter for issue #29. Given an `after.dmp` and a candidate type list, it
reads the managed heap with [ClrMD](https://www.nuget.org/packages/Microsoft.Diagnostics.Runtime) and
emits `reference-chains.{json,md,html}`: per-candidate path **groups** (shortest path, root → … →
candidate) with **coverage** accounting and **per-root-kind interpretation**. A `Stack` root means the
object is in use, not leaked; every other kind is retained but read differently (`rootInterpretation` /
`rootKindSummary` in the report): **StrongHandle** = static / long-lived cache (a leaked static field
appears as `StrongHandle -> Object[] -> holder`, not a `Static` kind in this ClrMD build),
**PinnedHandle / AsyncPinnedHandle** = pinning / interop / native pressure, **FinalizerQueue** =
Dispose / finalizer-backlog delay, **RefCountedHandle** = COM / interop lifetime.

This is the optional second stage of `diagsession-memory-analysis`. HeapStat (`dotnet-gcdump report`)
shows *what* grew; this shows *why* candidates are still retained. It is orchestrated by
`../../scripts/enrich-root-chains.ps1`, which degrades gracefully when no dump or tool is present.

## Capture the dump (standard)

```text
dotnet-dump collect -p <PID> --type heap -o after.dmp
```

(Visual Studio "Save dump as…" / Task Manager "Create dump file" are alternatives; a heap dump is enough.)

## Run

```text
ClrMdRootChainReport after.dmp --types-file candidates.txt --out <dir> [--max-depth 40] [--max-instances 20000]
# or:  ClrMdRootChainReport after.dmp --types LeakSample.DeviceViewModel,System.Byte[] --out <dir>
```

`--max-depth` is a **safety cap on graph exploration, not a guarantee** of reaching a root; instances
not reached within it are reported as `unresolved`. Use `--types-file` (one type per line) for
candidates with commas inside generic names.

**Scale / memory.** The reporter walks the whole reachable managed heap (a `Dictionary` keyed by every
visited object), so its memory use scales with the **dumped heap size**, not the candidate count. Run
it on a machine with RAM comparable to the dumped process. `--max-nodes` (default 5,000,000) bounds the
walk so a multi-GB dump can't OOM the tool; when it is hit, `nodeBudgetHit` is set, `coverage` is
partial, and the report says so (raise it only if RAM allows). Likewise `coverage` is "of analyzed",
and `analyzed` is a **uniform seeded reservoir sample** (reproducible) once a type exceeds
`--max-instances` (default 20,000) -- not a head-of-heap slice, so a minority retention group is not
silently dropped.

## Build / bundle (air-gapped)

The graph reader is internal to the runtime, so this is built **once on an internet-connected machine**
and the resulting self-contained exe is shipped to the closed network — the same model as the offline
`dotnet-gcdump` bundle. Nothing is restored on the air-gapped box.

```powershell
dotnet publish ClrMdRootChainReport.csproj -c Release -r win-x64 --self-contained -p:PublishSingleFile=true -o pub
# ship pub\ClrMdRootChainReport.exe to the closed network; point enrich-root-chains.ps1 -ToolExe at it,
# or drop it next to this README / under pub\ where the orchestrator auto-discovers it.
```

`bin/`, `obj/`, and `pub/` are gitignored — only the `.csproj` + `.cs` machinery is committed.
