# references/ — local corpus (generated, gitignored)

_This file is a committed placeholder that documents the directory's purpose and keeps it in git; it
holds no setup narrative. Canonical human setup lives in [`docs/lightningchart-72-usage.md`](../../../docs/lightningchart-72-usage.md)._

Nothing here except the READMEs is committed. The corpus is generated on your machine from your own
licensed SDK + manual:

- `api-index.json` / `api-symbols.txt`  ← `scripts/build-api-index.ps1`  (Tier 1: API existence/signature)
- `manual/` + `manual-index.json`        ← `scripts/build-manual-index.py` (Tier 2: semantics/how-to)
- `demos/`                               ← your official 7.2 demos (Tier 2.5, optional, Phase 2)

These are derived from licensed material and must stay local.
