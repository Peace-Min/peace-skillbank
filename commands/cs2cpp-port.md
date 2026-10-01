---
description: Port one cleaned C# file to C++17 1:1 (bottom-up by project), using the fixed cs2cpp-port rules and patterns.
argument-hint: "<C# file or class> [C++ output folder]"
---

Use the `cs2cpp-port` skill for the following request:

```text
$ARGUMENTS
```

Treat this command as a terse entry point:

0. If the target repository has `PORT_CONFIG.md`, read it first (allowed extra libraries, config/XML/format/regex decisions, code page, replacement-class names).
1. Input check (`references/input-contract.md`): if code lines still contain features with no C++ counterpart (Dispatcher, DevExpress, reflection, async, LINQ, Timer, ...), report each location with the C# form to change it to and stop with "pre-port cleanup first". Do not edit the C#. Do not translate the C# replacement-class files themselves; use the matching C++ pattern headers.
2. Dependency check: read already-ported headers and the library `API_MAP.md`; if a dependency is not ported yet, report it and stop.
3. Port exactly one file at a time (lambdas that run later capture locals by value and `this` only when its lifetime is guaranteed) into `<name>.h` + `<name>.cpp` with the Write tool (no code in the chat), then build with MSBuild (`-p:Platform=x64`). Stop after 3 failed builds or 2 shell timeouts.
4. Report: dependencies, written files, behavior differences, test classification with input lists, API_MAP additions, `TODO(PORT)` list, build result, applicable checklist items.
5. If no file is provided, ask for it.

If both this command and the namespaced plugin skill are available, this command is only a short alias for the skill.
