---
name: sparrow-static-analysis
description: Use when handling Sparrow static-analysis XLS findings for C#/.NET Framework 4.7.2, including deterministic Roslyn CLI fixes for coding/comment rules and Markdown request packaging for LLM/human review items.
---

# Sparrow Static Analysis

Use this skill when processing Sparrow static-analysis findings for an OSTES-style C#/.NET Framework 4.7.2 codebase.

## Scope

Work only inside `skills/sparrow-static-analysis` and the explicit Sparrow XLS/source inputs provided by the user. Do not inspect unrelated skills unless the user asks.

The workflow has two kinds of work:

- Deterministic fixes: coding-rule and comment/layout findings that match predefined, repeatable patterns are handled by Roslyn-based CLI tools.
- Judgment-required fixes: security/quality findings such as exception handling, null handling, resource leaks, TOCTOU, and encapsulation exposure are converted from Sparrow XLS/items into Markdown requests for LLM or human review.

Every Sparrow finding remains a work item. Do not drop findings as false positives unless the user explicitly changes the policy.

## Entry Points

Normal users should start from one of these:

- `SparrowRunner.Gui/SparrowRunner.Gui.sln`: Visual Studio entry point. This top-level folder intentionally contains only the solution file.
- `tools/Run-SparrowRunnerGui.cmd`: launches the integrated GUI.
- `tools/Run-SparrowAll.cmd`: runs deterministic coding/comment fixers from the console.

The WPF GUI is the single closed-network helper surface. It lets the user choose a solution/project/folder, select deterministic fix rules, choose dry-run/commit behavior, prepare Markdown request packages from Sparrow XLS, and view logs.

Keep implementation logic out of the GUI:

- Coding-rule fixer: `tools/_internal/SparrowSyntaxFix`
- Comment/layout fixer: `tools/_internal/SparrowCommentFix`
- XLS parser and request packager: `tools/_internal/SparrowXlsExport` and `tools/_internal/SparrowXlsExport.Core`

## 폐쇄망 반입(오프라인 배포)

The GUI/runners normally `dotnet run`/`dotnet build`, which needs a .NET SDK and NuGet restore — impossible on an air-gapped PC. For offline use, publish the tools once on an internet PC and carry the whole skill folder over:

1. On an internet PC with the .NET SDK, run `tools\publish-airgap.ps1` (default: self-contained `win-x64`; add `-FrameworkDependent` for smaller output, `-DryRun` to preview). It publishes all four projects into per-project `publish\` folders.
2. Copy the **entire `skills/sparrow-static-analysis` tree** — including the generated `publish\` folders and `references/` — to the air-gapped PC.
3. On the target, run `tools\Run-SparrowRunnerGui.cmd`. It auto-uses `SparrowRunner.Gui\publish\SparrowRunner.Gui.exe` when present, and the runners auto-pick `publish\SparrowSyntaxFix.exe` / `publish\SparrowCommentFix.exe` (no build/restore). Self-contained needs no .NET runtime on the target; framework-dependent needs the .NET 8 Desktop Runtime (GUI) / .NET 8 Runtime (CLI).

See `docs/sparrow-static-analysis-usage.md` (폐쇄망 반입 절) for the operator steps and runtime checklist.

## Deterministic CLI Fixes

Use deterministic CLI fixes only for predefined patterns. These tools are not general-purpose repair agents.

For coding-rule fixes, prefer:

```powershell
.\skills\sparrow-static-analysis\tools\_internal\SparrowSyntaxFix\Run-SparrowSyntaxFix.ps1
```

For comment/layout fixes, prefer:

```powershell
.\skills\sparrow-static-analysis\tools\_internal\SparrowCommentFix\Run-SparrowCommentFix.ps1
```

Normal operation should use the GUI or runner prompts. Direct `-Rules` use is reserved for tests, automation, and precise re-runs.

## Markdown Request Packaging

Use Markdown request packaging for findings that need judgment.

Required workflow:

1. Run `tools/Run-SparrowRunnerGui.cmd` and use the Track C XLS/LLM tab, or run the internal XLS tooling directly for tests.
2. Generate the `requests/` folder. This folder is the normal handoff unit for the closed-network LLM.
3. Use `references/triage/triage-contract.md` as the workflow contract.
4. Use `references/triage/triage-prompt.md` as the model prompt template.
5. For each finding, read `references/checkers/<CHECKER_KEY>.md` when it exists.
6. If a checker guide is missing, do not drop the row. The packager creates a fallback request from the XLS checker name, description, source, file, and line; use that request as the working guide.
7. If the checker is `NULL_RETURN_STD`, also read `references/dotnet-contracts/null-return-std.md`.
8. Produce concrete C# 7.3-compatible repair guidance when enough context exists.
9. If context is missing, mark the request as `context required` and list the exact missing files, symbols, or code ranges.

Do not auto-edit target source code for judgment-required findings from this skill. The output is a repair request for the developer or LLM working against the real source tree.

## Real Fix Pattern Corpus

When manually fixed closed-network findings should be reused without exposing source code, document only anonymized patterns under `references/real-fix-patterns/`.

- Use `references/real-fix-patterns/README.md` as the workflow.
- Use `references/real-fix-patterns/TEMPLATE.md` for each checker file.
- Extract only the minimum before/after shape needed to explain the checker fix.
- Anonymize filenames, symbols, string literals, paths, and domain terms.
- Classify the pattern as deterministic CLI, Markdown/LLM guidance, or human-review only.
- Do not copy closed-network source code, full functions, or business logic into this repo.

## Evidence Priority

Use sources in this order:

1. User-provided Sparrow XLS/item Markdown.
2. `references/sparrow-official-rules`.
3. `references/checkers`.
4. Target source code context from the inspected project.
5. Optional local .NET reference XML evidence for exception candidates.
6. Local reference tables such as `references/dotnet-contracts`.
7. External official references only when local materials are insufficient.

## Validation

After changing scripts, run PowerShell parser checks. For deterministic tool changes, run the matching fixture tests. For request-packaging changes, run the triage fixtures:

```powershell
powershell -ExecutionPolicy Bypass -File .\skills\sparrow-static-analysis\references\triage\fixtures\run-validate.ps1
powershell -ExecutionPolicy Bypass -File .\skills\sparrow-static-analysis\references\triage\e2e-lab\run-e2e.ps1
```
