---
description: Port a C# project to Windows C++17 one unit at a time (inventory -> per-unit prompt -> build check -> parity), never the whole project in one prompt.
argument-hint: "<C# source root> [scope subdirectory] [C++ output root]"
---

Use the `csharp-to-cpp-port` skill for the following request:

```text
$ARGUMENTS
```

Treat this command as a terse entry point:

1. Run `scripts/inventory-csharp.ps1 -SourceRoot <root> -CppRoot <cpp root>` (add `-Scope <dir>` when a sub-directory is given). Read `<cpp root>/port-work/PORT_INVENTORY.md` and `PORT_ORDER.txt`; summarise project kind, unit count, skipped files, feature totals needing a human decision (winforms, wpf, pinvoke, reflection, unsafe, dynamic, threading), cycle groups, and external dependencies.
2. If the project is WinForms/WPF, ask which C++ UI framework to target before porting UI units.
3. Port units in `PORT_ORDER.txt` order, one at a time: `make-unit-prompt.ps1 -Unit <U> -CppRoot <cpp root>` (if it prints `UnportedDeps: N>0`, port those first; `BlockedDeps: M>0`, mark this unit blocked and continue) -> write the file(s) with the file tool -> run the `finish-unit.ps1` command printed at the end of the prompt and follow its `RESULT:` / `NEXT:` lines (FAIL: re-prompt and fix only the embedded errors, max 3 rounds; BLOCKED: continue with NEXT).
4. After the last unit, `build-check.ps1 -CppRoot <cpp root> -All -Link -OutputExe <exe>`, then `parity-check.ps1 -CppRoot <cpp root> ...` if the original C# build and a `cases/` directory exist. Write unit paths with forward slashes.
5. If no source root is provided, ask for it and for the C++ output root.

Never put more than one unit into a prompt. Never invent declarations: missing pieces become `// TODO(port): needs ...`.

If both this command and the namespaced plugin skill are available, this command is only a short alias for the skill.
