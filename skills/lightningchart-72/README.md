# lightningchart-72

Grounded assistant for **LightningChart Ultimate SDK v7.2** (Arction). Answers API / property /
method / enum / usage questions **only from local 7.2 sources**, with citations and an
API-existence check. It never answers from memory — see `SKILL.md` for the runtime contract.

## Setup & usage

The full one-time corpus setup — the single `setup-local-corpus.ps1` command, auto-detection,
air-gapped notes, the self-check, and how the corpus resolves when the skill is installed as a
plugin — lives in the human usage guide (kept canonical there to avoid duplication):

➜ **[docs/lightningchart-72-usage.md](../../docs/lightningchart-72-usage.md)**

In short: drop the 7.2 SDK DLLs **and** the User's Manual PDF into one folder, then run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/setup-local-corpus.ps1 -SourceDir "<that folder>"
```

It builds the local corpus into `references/` (or the plugin data dir) and self-checks. Requires
Python 3 + `pypdf`. The two underlying build scripts (`build-api-index.ps1`, `build-manual-index.py`)
remain available for manual/advanced use; `setup-local-corpus.ps1` just orchestrates them.

## Privacy / licensing

The licensed DLLs, the manual PDF, and everything derived from them (`api-index.json`,
`api-symbols.txt`, `manual-index.json`, manual chunks) stay **local and gitignored** — never
committed. The DLL is read for its public API surface only; its binary is never copied or
redistributed.
