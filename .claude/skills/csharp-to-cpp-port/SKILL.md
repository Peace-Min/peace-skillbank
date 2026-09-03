---
name: csharp-to-cpp-port
description: Clone-time Claude Code entrypoint for porting a C# project to Windows C++17 one unit at a time with a deterministic loop built for weak/local models (inventory -> per-unit prompt -> build check -> error feedback -> parity). Use whenever the user asks to convert, translate, migrate or port C# / .NET code to C++ (C#을 C++로 변환, C# 코드 C++ 포팅, 닷넷을 네이티브 C++로 이식), directory by directory or file by file.
---

# C# to C++ Port Entrypoint

This is the Claude Code project-skill entrypoint that makes `/csharp-to-cpp-port` available immediately
after cloning this repository and starting Claude Code from the repo root.

Before acting, read and follow the canonical skill contract at:

```text
skills/csharp-to-cpp-port/SKILL.md
```

Use the bundled scripts and references from:

```text
skills/csharp-to-cpp-port/scripts/inventory-csharp.ps1
skills/csharp-to-cpp-port/scripts/make-unit-prompt.ps1
skills/csharp-to-cpp-port/scripts/apply-unit-response.ps1
skills/csharp-to-cpp-port/scripts/scan-forbidden.ps1
skills/csharp-to-cpp-port/scripts/build-check.ps1
skills/csharp-to-cpp-port/scripts/parity-check.ps1
skills/csharp-to-cpp-port/scripts/port-status.ps1
skills/csharp-to-cpp-port/references/mapping-table.md
skills/csharp-to-cpp-port/references/PortSupport.h
```

Treat user arguments passed to `/csharp-to-cpp-port` as `<C# source root> [scope subdirectory] [C++ output root]`.
Run `inventory-csharp.ps1 -SourceRoot <root> -CppRoot <cpp root> [-Scope <dir>]`, then the per-unit loop from
the canonical skill: one unit per step (a partial class counts as one unit), dependencies first, never the whole
project in one prompt.
