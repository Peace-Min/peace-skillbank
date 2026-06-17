# references/demos/ — official 7.2 demo source (Tier 2.5, optional · Phase 2)

Empty by design. **Add this only when the manual + your project code prove insufficient** (measured
gaps), not upfront — for a small/air-gapped model, an unindexed pile of demo code adds retrieval
noise more than value.

When you do add it:
1. Drop the **official LightningChart 7.2 demo source** (`.cs` files) here. They compile against 7.2,
   so they are real usage evidence (Tier 2.5 — stronger than your project's Tier 3, weaker than the
   DLL index's Tier 1 for existence).
2. Optionally generate a symbol index (API name → file:line) so retrieval stays precise.

Contents are **gitignored** (licensed) — only this README is committed.
