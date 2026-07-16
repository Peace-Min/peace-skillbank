---
name: sparrow-static-analysis
description: Use when handling Sparrow static-analysis XLS findings for C#/.NET Framework 4.7.2, including Track A/B deterministic autofix runners and Track C local-Claude repair request packaging for exception, null, resource, TOCTOU, and encapsulation findings.
---

# Sparrow Static Analysis

Use this skill for handling Sparrow static-analysis findings for the OSTES-style C#/.NET Framework 4.7.2 codebase, especially when converting Sparrow XLS output into deterministic Track A/B fixes or Track C LLM/human triage decisions.

## Operating Mode

Work only inside `skills/sparrow-static-analysis` and the explicit Sparrow XLS/source inputs provided by the user. Do not inspect other skills unless the user explicitly asks.

Track A and Track B are deterministic tooling tracks. Track C is not an autofix track; it packages Sparrow XLS findings into self-contained LLM/human repair requests.

## Real Fix Pattern Corpus

When the user has manually fixed Sparrow findings in a closed network and wants those fixes reused without exposing source code, document them as anonymized before/after patterns under `references/real-fix-patterns/`.

- Use `references/real-fix-patterns/README.md` as the workflow.
- Use `references/real-fix-patterns/TEMPLATE.md` for each checker file.
- Extract only the minimum diff shape needed to explain the checker fix.
- Anonymize filenames, symbols, string literals, paths, and domain terms.
- Classify whether the pattern is Track A/B CLI-automatable, Track C LLM guidance, or human-review only.
- Do not copy closed-network source code, full functions, or business logic into this repo.

## Windows Launcher UX

For normal one-shot local execution, prefer the `.cmd` launchers next to the PowerShell scripts:

- `tools/Run-SparrowRunnerGui.cmd` for the integrated Track A/B/C Sparrow Helper GUI. This is the normal user entrypoint.
- `tools/Run-SparrowAll.cmd`

The WPF wrapper is the single closed-network Sparrow Helper GUI. It lets the user choose a solution/project/folder, select Track A/B rules with checkboxes, choose commit/dry-run behavior, prepare Track C XLS/LLM repair-request packages, and view live logs. Keep Track A/B rewrite logic in the internal CLI scripts under `tools/_internal/` and keep Track C parsing/prepare logic in `tools/_internal/SparrowXlsExport.Core`; future rule improvements should update the underlying deterministic tool first and the GUI should only expose/select those options. For Track C, the closed-network GUI output is the LLM handoff `requests/` folder only; parser indexes and worklist files are internal/debug artifacts and must not be presented as the normal LLM input.

The `.cmd` launchers call the matching `.ps1` with `powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File ...`.
This preserves the existing prompt flow (solution path, optional rules, commit choice) while preventing a newly opened PowerShell window from closing before the user can read errors or completion output.
They also switch the console to UTF-8 and start from the launcher directory, so Korean console output does not become mojibake and logs are not written to `C:\Windows\System32` when launched elevated.
Use raw `.ps1` files from an already-open PowerShell terminal, tests, or automation.

## Track A

For code-rule fixes, use the one-shot runner UX. Do not ask the user to memorize `-Rules` values for normal operation.

- Prefer the integrated GUI: `tools/Run-SparrowRunnerGui.cmd`.
- Advanced direct runner path: `tools/_internal/SparrowSyntaxFix/Run-SparrowSyntaxFix.ps1`.
- If `-Rules` is omitted, the runner asks for the solution/folder path, optional review-needed rules, and commit choice.
- Direct `-Rules` usage is reserved for tests, automation, and precise re-runs.

## Track B

For comment/layout fixes, prefer the integrated GUI: `tools/Run-SparrowRunnerGui.cmd`.

- Default rules are safe comment rules.
- `flatten` and layout rules are opt-in through the runner prompts.
- Direct `-Rules` usage is reserved for tests, automation, and precise re-runs.
- Advanced direct runner path: `tools/_internal/SparrowCommentFix/Run-SparrowCommentFix.ps1`.

## Track C

Track C covers security/quality findings requiring judgment, including exception handling, null dereference, resource leaks, TOCTOU, and encapsulation exposure.

Required workflow:

1. For GUI-based preparation, run `tools/Run-SparrowRunnerGui.cmd` and use the `Track C XLS/LLM 작업` tab to create the `requests/` folder only. This folder is the unit handed to the closed-network LLM.
2. Use `references/triage/triage-contract.md` as the workflow contract.
3. Use `references/triage/triage-prompt.md` as the model prompt template.
4. For each finding, read the exact checker guide at `references/checkers/<CHECKER_KEY>.md`.
5. If the checker is `NULL_RETURN_STD`, also consult `references/dotnet-contracts/null-return-std.md`.
6. Write a concrete repair instruction from the checker guide and the finding/source context.
7. If source context is missing, do not guess. Mark the request as `문맥 필요` in the Markdown output and list the exact missing files, symbols, or code ranges.
8. Do not auto-edit Track C target source code from this skill. The request output guides the closed-network developer/LLM working against the real source tree.

Track C requests must end in either `수정 가능` or `문맥 필요`:

- `수정 가능`: include concrete Before/After guidance using C# 7.3-compatible syntax.
- `문맥 필요`: list the missing source/exception/ownership context. This is not a skip; it is pending until the context is obtained.

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

Local .NET reference XML documentation can help `OVERLY_BROAD_CATCH` handling when its `<exception>` tags are used to list possible exception types from calls inside a `try` block. Treat those lists as supporting evidence; still check the source context, boundary-handler role, and checker guide.

## Validation

After changing scripts, run PowerShell parser checks. For Track A/B tool changes, run the corresponding fixture tests. For Track C workflow changes, run the triage fixtures:

```powershell
powershell -ExecutionPolicy Bypass -File .\skills\sparrow-static-analysis\references\triage\fixtures\run-validate.ps1
powershell -ExecutionPolicy Bypass -File .\skills\sparrow-static-analysis\references\triage\e2e-lab\run-e2e.ps1
```
