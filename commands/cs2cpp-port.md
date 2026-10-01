---
description: Port one cleaned C# file to C++17 1:1 (bottom-up by project), using the fixed cs2cpp-port rules and patterns.
argument-hint: "<C# file or class> [C++ output folder]"
---

Use the `cs2cpp-port` skill for the following request:

```text
$ARGUMENTS
```

Treat this command as a terse entry point:

1. Input check: if code lines still contain items the pre-port cleanup stage must remove (Dispatcher, DevExpress, reflection, async, LINQ, Timer, ...), report their locations and stop with "pre-port cleanup first".
2. Dependency check: read already-ported headers and the library `API_MAP.md`; if a dependency is not ported yet, report it and stop.
3. Port exactly one file at a time into `<name>.h` + `<name>.cpp` with the Write tool (no code in the chat), then build with MSBuild (`-p:Platform=x64`). Stop after 3 failed builds or 2 shell timeouts.
4. Report: dependencies, written files, behavior differences, test classification with input lists, API_MAP additions, `TODO(PORT)` list, build result, applicable checklist items.
5. If no file is provided, ask for it.

If both this command and the namespaced plugin skill are available, this command is only a short alias for the skill.
