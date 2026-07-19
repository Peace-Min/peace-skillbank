# Sparrow Static Analysis Handoff

## Current Direction

This skill is a closed-network helper for Sparrow static-analysis remediation.

- Deterministic coding/comment findings are handled only when they match predefined patterns.
- Those deterministic fixes are implemented in Roslyn-based CLI tools under `tools/_internal`.
- Security/quality findings that need judgment are converted from Sparrow XLS/items into Markdown requests for LLM or human review.
- The normal operator surface is the integrated GUI launched from `tools/Run-SparrowRunnerGui.cmd` or the top-level Visual Studio solution at `SparrowRunner.Gui/SparrowRunner.Gui.sln`.

## Tool Map

| Area | Tooling | Notes |
| --- | --- | --- |
| Coding-rule fixes | `tools/_internal/SparrowSyntaxFix` | Roslyn syntax rewriter for predefined C# patterns. |
| Comment/layout fixes | `tools/_internal/SparrowCommentFix` | Roslyn trivia/layout rewriter for predefined comment and layout patterns. |
| XLS parsing | `tools/_internal/SparrowXlsExport` | Parses Sparrow XLS without Excel/COM. |
| Markdown packaging | `tools/_internal/SparrowXlsExport.Core` | Generates `requests/`, `worklist.csv`, and `unresolved.csv`. |
| GUI | `tools/SparrowRunner.Gui` | Thin wrapper; keep business logic in internal tools. |

## Operating Policy

- Do not ask normal users to memorize rule keys. Use the GUI or runner prompts.
- Direct `-Rules` usage is for tests, automation, and precise re-runs.
- Deterministic fixers are not general repair tools. They should only encode proven, repeatable patterns.
- Judgment-required items must remain Markdown requests; do not auto-edit target source from this skill.
- The `requests/` folder is the LLM handoff unit. Parser indexes and worklists are support/debug artifacts.
- Re-run Sparrow after deterministic fixes; Roslyn success is not the same as Sparrow clearance.

## Validation Checklist

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\validate.ps1
dotnet build .\skills\sparrow-static-analysis\SparrowRunner.Gui\SparrowRunner.Gui.sln -c Release
dotnet build .\skills\sparrow-static-analysis\tools\_internal\SparrowSyntaxFix\SparrowSyntaxFix.csproj -c Release
dotnet build .\skills\sparrow-static-analysis\tools\_internal\SparrowCommentFix\SparrowCommentFix.csproj -c Release
dotnet build .\skills\sparrow-static-analysis\tools\_internal\SparrowXlsExport\SparrowXlsExport.csproj -c Release
```

Optional heavier gates are exposed through `tests/validate.ps1` switches, for example `-IncludeSyntaxFixE2E`, `-IncludeCommentE2E`, and Sparrow real-XLS regression switches.
