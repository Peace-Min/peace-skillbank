# lightningchart-72

Grounded assistant for **LightningChart Ultimate SDK v7.2** (Arction). Answers API / property /
method / enum / usage questions **only from local 7.2 sources**, with citations and an
API-existence check. It never answers from memory — see `SKILL.md` for the contract.

## One-time local setup (per machine)

The corpus is **generated locally from your own licensed SDK + manual** and is **never committed**
(gitignored). Only the scripts (`scripts/`) and docs are in the repo. Paths are passed as arguments
— nothing is hardcoded.

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
