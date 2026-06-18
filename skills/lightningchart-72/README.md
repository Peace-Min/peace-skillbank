# lightningchart-72

Grounded assistant for **LightningChart Ultimate SDK v7.2** (Arction). Answers API / property /
method / enum / usage questions **only from local 7.2 sources**, with citations and an
API-existence check. It never answers from memory — see `SKILL.md` for the contract.

## One-time local setup (per machine)

The corpus is **generated locally from your own licensed SDK + manual** and is **never committed**
(gitignored). Only the scripts (`scripts/`) and docs are in the repo. Paths are passed as arguments
— nothing is hardcoded.

### Quick: one command

Drop the 7.2 SDK DLLs **and** the User's Manual PDF into one folder, then run the script — either from
**inside that folder** (no paths at all) or by naming it with `-SourceDir`:

```powershell
# simplest: from inside the folder that holds the DLLs + PDF (no arguments)
cd D:\lc72-deps
powershell -NoProfile -ExecutionPolicy Bypass -File C:\path\to\scripts\setup-local-corpus.ps1

# or from anywhere, naming the folder:
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/setup-local-corpus.ps1 -SourceDir "D:\lc72-deps"

# or pass the two paths explicitly (if auto-detection can't find them):
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/setup-local-corpus.ps1 `
  -DllDir "D:\lc72-deps\Lib\Arction" -ManualPdf "D:\lc72-deps\LightningChart Users Manual.pdf"
```

The **corpus output always goes to the skill's `references/`** (or the plugin data dir) regardless of
where you run it or where the source files are — output is anchored to the script's own location, not
the source folder, so the two never get confused.

`setup-local-corpus.ps1` resolves the DLL folder + manual PDF, verifies Python + `pypdf`, builds both
tiers, and self-checks the result (expects e.g. `api types: 627`, `manual sections: 289 == md files`).
It needs **Python 3 + `pypdf`** for the manual index; if Python, pypdf, the DLL folder, or the PDF is
missing it **aborts with specific guidance** rather than leaving a half-built corpus. Offline pypdf:
`python -m pip install --no-index --find-links <wheelhouse-dir> pypdf`.

### Manual: the two underlying build scripts

`setup-local-corpus.ps1` only orchestrates the scripts below — run them directly for finer control:

1. **Tier 1 — DLL API index** (existence / signature):
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-api-index.ps1 -DllDir "<...>\Lib\Arction"
   ```
   Skips `Arction.Licensing.dll`; reads public names + signatures only (no license data).
   → `references/api-index.json`, `references/api-symbols.txt`
2. **Tier 2 — Manual** (semantics / how-to):
   ```
   python scripts/build-manual-index.py "<...>\LightningChart Users Manual.pdf"
   ```
   (needs `pip install pypdf` on the build machine) → `references/manual/`, `references/manual-index.json`
3. **Tier 3 — Project code** (usage): nothing to set up — searched in place in your working project.
4. **(Phase 2, optional)** official 7.2 demos → drop into `references/demos/` (see its README).

## Use

In a session (with this repo / your project as the working dir so `SKILL.md` is in context), ask any
LightningChart 7.2 question. The skill translates intent → manual/DLL → escalates to project code if
needed → answers with citations → verifies every cited API symbol against the DLL index
(`scripts/verify-symbols.py`).

`scripts/search.py "<query>"` is a stdlib-only retrieval helper for runtimes without good grep.

## Privacy / licensing

The licensed DLLs, the manual PDF, and everything derived from them (`api-index.json`, manual chunks)
stay **local and gitignored**. Do not commit them. The DLL is read for its public API surface only;
its binary is never copied or redistributed.
