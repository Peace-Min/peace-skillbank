---
name: sparrow-static-analysis
description: Use when handling Sparrow static-analysis XLS findings for C#/.NET Framework 4.7.2, including Track A/B deterministic autofix runners and Track C local-Claude triage for exception, null, resource, TOCTOU, and encapsulation findings.
---

# Sparrow Static Analysis

Use this skill for handling Sparrow static-analysis findings for the OSTES-style C#/.NET Framework 4.7.2 codebase, especially when converting Sparrow XLS output into deterministic Track A/B fixes or Track C LLM/human triage decisions.

## Operating Mode

Work only inside `skills/sparrow-static-analysis` and the explicit Sparrow XLS/source inputs provided by the user. Do not inspect other skills unless the user explicitly asks.

Track A and Track B are deterministic tooling tracks. Track C is not an autofix track; it is an LLM/human judgment workflow.

## Windows Launcher UX

For normal one-shot local execution, prefer the `.cmd` launchers next to the PowerShell scripts:

- `references/Run-TrackA.cmd`
- `tools/SparrowSyntaxFix/Run-SparrowSyntaxFix.cmd`
- `tools/SparrowCommentFix/Run-SparrowCommentFix.cmd`
- `tools/Run-SparrowAll.cmd`

The `.cmd` launchers call the matching `.ps1` with `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File ...`.
This preserves the existing prompt flow (solution path, optional rules, commit choice) while preventing a newly opened PowerShell window from closing before the user can read errors or completion output.
They also switch the console to UTF-8 and start from the launcher directory, so Korean `dotnet` output does not become mojibake and logs are not written to `C:\Windows\System32` when launched elevated.
Use raw `.ps1` files from an already-open PowerShell terminal, tests, or automation.

## Track A

For code-rule fixes, use the one-shot runner UX. Do not ask the user to memorize `-Rules` values for normal operation.

- First pass: `references/Run-TrackA.ps1`.
- Roslyn expansion: `tools/SparrowSyntaxFix/Run-SparrowSyntaxFix.ps1`.
- If `-Rules` is omitted, the runner asks for the solution/folder path, optional review-needed rules, and commit choice.
- Direct `-Rules` usage is reserved for tests, automation, and precise re-runs.

## Track B

For comment/layout fixes, use `tools/SparrowCommentFix/Run-SparrowCommentFix.ps1`.

- Default rules are safe comment rules.
- `flatten` and layout rules are opt-in through the runner prompts.
- Direct `-Rules` usage is reserved for tests, automation, and precise re-runs.

## Track C

Track C covers security/quality findings requiring judgment, including exception handling, null dereference, resource leaks, TOCTOU, and encapsulation exposure.

Required workflow:

1. Use `references/triage/triage-contract.md` as the workflow contract.
2. Use `references/triage/triage-prompt.md` as the model prompt template.
3. For each finding, read the exact checker guide at `references/checkers/<CHECKER_KEY>.md`.
4. If the checker is `NULL_RETURN_STD`, also consult `references/dotnet-contracts/null-return-std.md`.
5. Judge only from the checker guide and the finding/source context.
6. If source context is missing, do not guess. Return `verdict = 보류`, `needs_context = true`, and list `missing_context`.
7. Use `needs_frontier = true` only when enough context is present but the local model still cannot make a reliable decision.
8. Do not auto-edit Track C target source code. Provide verdict JSON and fix guidance only.

Track C verdicts must classify each item as either `진성` or `보류` (this project fixes every finding — there is no false-positive skip):

- `진성`: true positive; include concrete `fix.before` and `fix.after` guidance using C# 7.3-compatible syntax.
- `보류`: cannot fix yet (missing source/exception-list context); set `needs_context = true` + `missing_context`, or `needs_frontier = true` when enough context is present but the local model cannot decide. 보류 is NOT a skip — it is a pending state that MUST be fixed once the context is obtained.

전건 수정 정책: every Sparrow finding is fixed. Do not drop items as false positives.

## Evidence Priority

Use sources in this order:

1. User-provided Sparrow XLS/item markdown.
2. `references/sparrow-official-rules`.
3. `references/checkers`.
4. Target source code context from the inspected project.
5. Optional exception evidence produced from local .NET reference XML documentation, such as call/API exception candidate lists derived from `<exception>` tags.
6. Local reference tables such as `references/dotnet-contracts`.
7. External official references only when local materials are insufficient.

Local .NET reference XML documentation can help `OVERLY_BROAD_CATCH` triage when its `<exception>` tags are used to list possible exception types from calls inside a `try` block. Treat those lists as supporting evidence, not as a final verdict; still check the source context, boundary-handler role, and checker guide.

## Validation

After changing scripts, run PowerShell parser checks. For Track A/B tool changes, run the corresponding fixture tests. For Track C workflow changes, run the triage fixtures:

```powershell
powershell -ExecutionPolicy Bypass -File .\skills\sparrow-static-analysis\references\triage\fixtures\run-validate.ps1
powershell -ExecutionPolicy Bypass -File .\skills\sparrow-static-analysis\references\triage\e2e-lab\run-e2e.ps1
```
