---
name: lightningchart-72
description: Answers LightningChart Ultimate SDK v7.2 (Arction) API, property, method, enum, and usage questions grounded ONLY in local 7.2 sources (the DLL API index + the indexed user manual + the current project's own usage), with source citations and an API-existence verification step. Use whenever the user works with LightningChart / Arction 7.2 — asking about chart APIs, properties, methods, enums, how to implement a chart feature, ViewXY / View3D / ViewRound, series, axes, annotations, maps, palettes, zooming, cursors, legend, etc. Prefer this over answering from general knowledge for ANY LightningChart 7.2 question, especially offline / air-gapped, because answers must come from the manual and DLL, not memory.
---

# LightningChart 7.2 — grounded API assistant

Answer LightningChart Ultimate 7.2 questions ONLY from the local sources below. Never answer from
memory or general knowledge — invented APIs/properties are exactly the failure this skill exists to
prevent. Quote and cite; if the sources don't cover it, say so.

## Sources (tiered)

Generated locally per machine and **not committed** (see `README.md` for one-time setup).

- **Tier 1 — DLL API index** (`references/api-index.json`, `references/api-symbols.txt`): the complete
  public API surface (types, properties, methods, enums + signatures) of the 7.2 assemblies.
  **Authoritative for whether an API/property/method/enum EXISTS and for its signature.**
- **Tier 2 — Manual** (`references/manual/<section>.md`, indexed by `references/manual-index.json`):
  concepts, how-to, meaning. Curated and **incomplete** — many APIs are undocumented here.
- **Tier 3 — Project code** (current working project, searched in place): **unverified** in-project
  usage examples. Shows HOW an API was called here; can NEVER establish that an API exists or its
  signature (that is Tier 1 only).

## Workflow (per question)

1. **Translate intent → API symbol.** Search `manual-index.json` (titles/keywords) and/or
   `api-symbols.txt` to turn the user's words ("color palette") into the exact symbol
   (`ValueRangePalette`). The manual/index is the translator from human intent to API names.
2. **Read the matched manual chunk(s)** for documented meaning + any C# snippet. Cite `§<section> (p<page>)`.
3. **Confirm existence/signature against Tier 1** — look the symbol up in `api-index.json` (exact type,
   property type, method params/return).
4. **Escalate to project code only when needed:** the user asks for usage/an example, OR Tier 1
   confirms a symbol but Tier 2 has no semantics for it (undocumented-API gap). Then grep the *exact
   symbol* (not free text) in the current project, restricted to files that reference the
   LightningChart/Arction namespace; never search secrets/config/`bin`/`obj`; take ≤3–5 short
   call-site snippets.
5. **Compose, grounded + cited.** Meaning ← manual; existence/signature ← DLL index; working pattern ←
   project (Tier 3, hedged). Quote code; adapt minimally; never invent.
6. **Verify hook (required).** Run `scripts/verify-symbols.py` on your draft (or grep each cited symbol
   against `api-symbols.txt`). Any symbol NOT in Tier 1 is unverified → remove it or mark
   "not found in the 7.2 API" — never assert it. A symbol that appears only in project code but not in
   the DLL index fails the same as a hallucination.

## Output rules

- **Cite every fact:** manual `§6.15.5 (p85)`, API `[api: IntensityGridSeries.ValueRangePalette : ValueRangePalette]`,
  project `[project: <file>:<line> — usage example, not verified as correct]`.
- **Tier 1 wins conflicts.** If the project uses something the DLL index doesn't list, say so; trust the index.
- Phrase project findings as "this project does X", never "the recommended way is X".
- If a topic is in **none** of the sources: answer "not found in the 7.2 manual or API index" — do not guess.
- **Prefer quoting** documented snippets / real code over generating new code (the runtime model may be small).

## Scope

Answers from the 7.2 sources only; does not modify the licensed SDK or invent APIs. v1 sources = DLL
index + manual (+ in-project usage). Official vendor demos may be added later under
`references/demos/` (see that folder's README) when manual + project prove insufficient — add them
with a symbol index so retrieval stays precise.
