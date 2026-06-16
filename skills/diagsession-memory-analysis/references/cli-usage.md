# CLI Usage

Use this reference only when detailed script options are needed. The normal skill flow should parse user-provided paths and run the script with defaults.

## Standard `.diagsession` Input

```powershell
$skillDir = "C:\path\to\peace-skillbank\skills\diagsession-memory-analysis"
powershell -NoProfile -ExecutionPolicy Bypass -File "$skillDir\scripts\extract-gcdump-reports.ps1" -InputPath C:\dumps\leak-test.diagsession
```

## Direct `.gcdump` Input

```powershell
$skillDir = "C:\path\to\peace-skillbank\skills\diagsession-memory-analysis"
powershell -NoProfile -ExecutionPolicy Bypass -File "$skillDir\scripts\extract-gcdump-reports.ps1" -InputPath C:\dumps\snapshot-1.gcdump,C:\dumps\snapshot-2.gcdump
```

## Custom Tool Path

Use `-ToolPath` when `dotnet-gcdump` is not on `PATH` or in `C:\tools\dotnet-gcdump`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$skillDir\scripts\extract-gcdump-reports.ps1" -InputPath C:\dumps\leak-test.diagsession -ToolPath C:\tools\dotnet-gcdump
```

`-ToolPath` can point to either a directory containing `dotnet-gcdump.exe` or the full executable path.

## Output Options

- `-OutputDirectory <path>`: write `LLM_MEMORY_INPUT.txt`, `MANIFEST.txt`, and `reports/` to a custom directory.
- `-KeepExtractedGcdump`: preserve extracted `.gcdump` files after reports are generated.
- `-IncludeFullPathsInLlmInput`: include full local paths in `LLM_MEMORY_INPUT.txt`. Do not use this for external LLM sharing unless the user explicitly wants paths included.

By default, `LLM_MEMORY_INPUT.txt` redacts full local paths and keeps file names only. `MANIFEST.txt` keeps the full local path mapping for local traceability.

## Failure Modes

- Missing input path: ask the user for a valid `.diagsession` or `.gcdump` path.
- No `.gcdump` inside `.diagsession`: report that the selected VS profiling session does not contain managed heap snapshots.
- Fewer than two snapshots for leak comparison: ask for another snapshot or state that only single-snapshot inventory is possible.
- `dotnet-gcdump` missing: ask for installation or a `-ToolPath` value.
