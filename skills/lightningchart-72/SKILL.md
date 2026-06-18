---
name: lightningchart-72
description: Answers LightningChart Ultimate SDK v7.2 (Arction) API, property, method, enum, and usage questions grounded ONLY in local 7.2 sources (the DLL API index + the indexed user manual + the current project's own usage), with source citations and an API-existence verification step. Use whenever the user works with LightningChart / Arction 7.2 -- asking about chart APIs, properties, methods, enums, how to implement a chart feature, ViewXY / View3D / ViewRound, series, axes, annotations, maps, palettes, zooming, cursors, legend, etc. Prefer this over answering from general knowledge for ANY LightningChart 7.2 question, especially offline / air-gapped, because answers must come from the manual and DLL, not memory.
---

# LightningChart 7.2 -- grounded API assistant

Answer LightningChart Ultimate 7.2 questions ONLY from the local sources below. Never answer from
memory or general knowledge -- invented APIs/properties are exactly the failure this skill exists to
prevent. Quote and cite; if the sources don't cover it, say so.

## Sources (tiered)

Generated locally per machine and **not committed** (see `README.md` for one-time setup). When the
skill is installed as a plugin the corpus lives in the plugin data dir; `search.py` and
`verify-symbols.py` resolve it automatically (`${CLAUDE_PLUGIN_DATA}/references` when set, else the
script-relative `references/`).

- **Tier 1 -- DLL API index** (`references/api-index.json`, `references/api-symbols.txt`): the public
  API surface (types, properties, methods, enums + signatures) of the **main 7.2 charting assembly**
  (the auto-detected `*LightningChartUltimate*.dll`; sibling/edition assemblies are not indexed).
  **Authoritative for whether an API EXISTS in that assembly and for its signature.** A symbol absent
  here is treated as not-in-7.2, though it could live in an un-indexed sibling assembly.
- **Tier 2 -- Manual** (`references/manual/<section>.md`, indexed by `references/manual-index.json`):
  concepts, how-to, meaning. Curated and **incomplete** -- many APIs are undocumented here.
- **Tier 3 -- Project code** (current working project, searched in place): **unverified** in-project
  usage examples. Shows HOW an API was called here; can NEVER establish that an API exists or its
  signature (that is Tier 1 only).

## Workflow (per question)

1. **Find the symbol.** Search BOTH `manual-index.json` (titles/keywords) and `api-symbols.txt`. The
   manual translates intent ("color palette") into the API name -- but it is incomplete, so **absence
   from the manual is normal, not a stop**: go straight to `api-symbols.txt` for the exact symbol (grep
   it; do not Read `api-index.json`). If `search.py` returns no manual section, grep
   `references/manual/*.md` directly before concluding a topic is undocumented.
2. **Existence + signature ← Tier 1 only.** Confirm every symbol by grepping `api-symbols.txt` (sorted,
   grep-friendly) or `python scripts/search.py "<term>"`. **Never `Read` `api-index.json` directly: it
   is a single ~740 KB line and will blow your context** -- only the verify hook parses it. For a type's
   members or a method/constructor signature, `grep "^TypeName\." references/api-symbols.txt`. Never
   answer an existence question from the manual.
3. **Meaning ← Tier 2.** Read the matched manual chunk for what it does + any C# snippet; cite
   `§<section> (p<page>)`.
4. **Working code ← Tier 3, only on escalation:** the user asks for usage/an example, OR a symbol
   exists in Tier 1 but Tier 2 has no semantics for it. Grep the *exact symbol* (not free text) in the
   current project, restricted to LightningChart/Arction-namespace files; never secrets/config/`bin`/
   `obj`; ≤3-5 short snippets. **A symbol seen only in project code and not in `api-index.json` is
   unverified -- treat it exactly like a hallucination; project code never establishes existence.**
5. **Compose, grounded + cited.** Quote; adapt minimally. **Write every API member in qualified
   `Type.Member` form** (e.g. `IntensityGridSeries.ValueRangePalette`, not a bare `ValueRangePalette`)
   so the verify hook can check it. Under `--strict` the hook **blocks** (exit 1) a bare name that is
   *not* in the index, and **flags for review** (still exit 0, does not block) a bare name that *is* a
   known member somewhere -- qualify those too so the citation is unambiguous about which type. **Put
   every API identifier in `backticks`**: the hook only inspects single-word identifiers inside
   inline-code spans, so a member named only in plain prose (e.g. "set the Smoothing property") can slip
   past verification.
6. **Exists but undocumented:** If a symbol exists in Tier 1 but no Tier 2/Tier 3 source says what it
   DOES, report its existence and signature only and say *"exists in the 7.2 API; behavior not
   documented in the local manual or used in this project -- I won't guess what it does."* **Never infer
   behavior from a type/member name.**
7. **Constructors (`new Type(...)`).** Series/axes/objects are created via constructors. The verify
   hook records constructor arities and flags any `new Type(...)` whose argument count is not a real
   7.2 constructor. Confirm the type exists in Tier 1, but take the exact constructor argument list
   from a Tier 2 manual snippet or Tier 3 project code -- **never reconstruct `new Type(view, xAxis,
   yAxis)` from memory.** If no local source shows the call, say "the type exists; get its exact
   constructor arguments from a manual example or project usage."
8. **Verify hook (required).** Run `python scripts/verify-symbols.py --strict -` on your draft.
   - **exit 0** → all cited symbols verified; you may assert them.
   - **exit 1** → remove or qualify every `X`-flagged symbol before answering (qualified-unknown =
     invented; bare-unknown or an unknown single-word identifier in `backticks` under `--strict` =
     must be qualified or removed; a `new Type(...)` whose argument count is not a real arity).
   - **exit 2** → index not built → say the corpus is unavailable; do NOT answer with citations.
   The hook confirms a member EXISTS and checks constructor argument COUNT (string literals in the call
   are counted as one argument, not split); it does **not** validate method signatures/parameter types
   -- so when you cite a method signature, **quote it verbatim** from the manual snippet or the api
   index entry, never reconstruct it from memory.

## Output rules

- **Cite every fact:** manual `§6.15.5 (p85)`, API `[api: IntensityGridSeries.ValueRangePalette : ValueRangePalette]`,
  project `[project: <file>:<line> -- usage example, not verified as correct]`.
- **Tier 1 wins conflicts** (project/manual vs DLL index → trust the index, and say so).
- Phrase project findings as "this project does X", never "the recommended way is X".
- **One operating rule:** assert only what a cited source establishes. If none does, say "not found in
  the 7.2 manual or API index" or "exists but behavior undocumented" -- never fill the gap from memory.
- **Prefer quoting** documented snippets / real code over generating new code.

## Scope

Answers from the 7.2 sources only; does not modify the licensed SDK or invent APIs. v1 sources = DLL
index + manual (+ in-project usage). Official vendor demos may be added later under
`references/demos/` (see that folder's README) when manual + project prove insufficient -- add them
with a symbol index so retrieval stays precise.
