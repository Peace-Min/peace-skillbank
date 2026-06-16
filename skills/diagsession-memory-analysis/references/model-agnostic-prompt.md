# Model-Agnostic LLM Prompt

You are analyzing a .NET managed memory leak using Visual Studio profiler snapshots.

Input evidence:

- The user repeated a specific action that is known to increase memory.
- The prompt should include the action count, approximate timing, and snapshot order when available.
- `LLM_MEMORY_INPUT.txt` contains one or more `dotnet-gcdump report` outputs generated from `.gcdump` snapshots extracted from `.diagsession` files.
- Treat the snapshots as before/after in the order provided by the user or manifest.
- `.gcdump` evidence represents managed heap retention, not full process/native memory.

Analyze the evidence with this process:

1. Identify types that increased materially by `Size`.
2. Identify types that increased materially by `Count`.
3. Prioritize application-owned types over framework/container types, but use framework containers as retention clues.
4. Look for container clues and retention hypotheses: static caches, dictionaries, lists, observable collections, event handlers, timers, task continuations, closures, dispatcher queues, service singletons, view models, views, bitmaps, byte arrays, and strings.
5. Connect growing types to the supplied project structure and action entry point.
6. Avoid claiming native, GDI, COM, unmanaged, or handle leaks unless the managed evidence supports only a wrapper-retention hypothesis.

Return:

```text
1. Top leak candidates
2. Evidence table
3. Most likely retention hypothesis
4. Source files/code paths to inspect
5. Confirmation steps
6. Evidence limitations
```

If the `.gcdump` evidence does not explain the observed memory growth, say that clearly and recommend full `.diagsession`/native/handle/allocation-stack analysis.
