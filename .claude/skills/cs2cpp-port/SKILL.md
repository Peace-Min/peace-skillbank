---
name: cs2cpp-port
description: Clone-time Claude Code entrypoint for porting C# (.NET Framework 4.7.2/4.8 console) to C++17 1:1 (features with no C++ counterpart must already be replaced inside C#; otherwise it reports them and stops), one file at a time, bottom-up by project, with fixed rules for weak/local models (VS2022 v143 x64, std + Win32 only, NetCompat semantics, thread/queue/timer/UDP/byte-serialization patterns, API_MAP, test classification). Use for requests like "C# 코드를 C++로 포팅/변환해줘", "이 클래스 C++로 옮겨줘", "C#→C++", "port/convert/translate C# to C++". Cleanup inside C# is not done by this skill; references/input-contract.md and csharp-helpers.md describe what it expects.
---

# C# to C++17 Port Entrypoint

This is the Claude Code project-skill entrypoint that makes `/cs2cpp-port` available immediately
after cloning this repository and starting Claude Code from the repo root.

Before acting, read and follow the canonical skill contract at:

```text
skills/cs2cpp-port/SKILL.md
```

Read only the reference files the contract routes you to:

```text
skills/cs2cpp-port/references/input-contract.md
skills/cs2cpp-port/references/csharp-helpers.md
skills/cs2cpp-port/references/env.md
skills/cs2cpp-port/references/project.md
skills/cs2cpp-port/references/types.md
skills/cs2cpp-port/references/idioms.md
skills/cs2cpp-port/references/netcompat.md
skills/cs2cpp-port/references/concurrency.md
skills/cs2cpp-port/references/serialization.md
skills/cs2cpp-port/references/net.md
skills/cs2cpp-port/references/testing.md
skills/cs2cpp-port/references/pitfalls-checklist.md
```

If the target repository has `PORT_CONFIG.md`, read it before porting.

Treat user arguments passed to `/cs2cpp-port` as `<C# file or class> [C++ output folder]`. Port exactly one
file per request; if its dependencies are not ported yet, report them and stop.
