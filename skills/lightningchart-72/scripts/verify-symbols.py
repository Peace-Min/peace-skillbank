#!/usr/bin/env python3
"""
Verify hook (Tier 1). Check that every *qualified* API symbol (Type.Member) cited in a draft
answer actually exists in the local DLL API index. Qualified symbols not found are reported as
UNVERIFIED so they get demoted, never asserted. Bare PascalCase words are reported as info only
(too noisy to fail on).

Usage:
  python verify-symbols.py <draft.md> [references_dir]
  type draft.md | python verify-symbols.py - [references_dir]

Exit code 1 if any qualified API symbol is unverified. Reads references/api-index.json
(falls back to api-symbols.txt). Stdlib only -> air-gapped friendly.
"""
import sys, os, re, json

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def load_index(ref_dir):
    types, qualified, members = set(), set(), {}
    j = os.path.join(ref_dir, "api-index.json")
    if os.path.exists(j):
        data = json.load(open(j, encoding="utf-8-sig"))
        for t in data.get("types", []):
            types.add(t["name"])
            if t.get("kind") == "enum":
                names = t.get("values", [])
            else:
                names = [x["n"] for x in t.get("props", [])] + [x["n"] for x in t.get("methods", [])]
            for nm in names:
                qualified.add(f'{t["name"]}.{nm}')
                members.setdefault(nm, set()).add(t["name"])
        return types, qualified, members
    s = os.path.join(ref_dir, "api-symbols.txt")
    if os.path.exists(s):
        for ln in open(s, encoding="utf-8-sig"):
            ln = ln.strip()
            if not ln:
                continue
            if "." in ln:
                a, b = ln.split(".", 1)
                qualified.add(ln); types.add(a); members.setdefault(b, set()).add(a)
            else:
                types.add(ln)
    return types, qualified, members


def candidates(text):
    qual, bare = set(), set()
    # strip fenced code? keep it -- code is where symbols live. Drop citation hints like [api: ...]
    for m in re.findall(r"\b([A-Z][A-Za-z0-9]+\.[A-Za-z_][A-Za-z0-9_]+)\b", text):
        qual.add(m)
    for m in re.findall(r"\b([A-Z][a-z0-9]+(?:[A-Z][a-z0-9]*)+)\b", text):
        bare.add(m)
    return qual, bare


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "-"
    ref_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "references")
    text = sys.stdin.read() if src == "-" else open(src, encoding="utf-8-sig").read()

    types, qualified, members = load_index(ref_dir)
    if not types:
        print("api-index not built (run scripts/build-api-index.ps1). Cannot verify.")
        sys.exit(2)

    qual, bare = candidates(text)
    verified, unverified = [], []
    for c in sorted(qual):
        base, mem = c.split(".", 1)
        mem0 = mem.split(".")[0]
        if c in qualified or f"{base}.{mem0}" in qualified:
            verified.append(c)
        else:
            unverified.append(c)

    bare_known = sorted(b for b in bare if b in types or b in members)
    bare_unknown = sorted(b for b in bare if b not in types and b not in members)

    print(f"VERIFIED qualified ({len(verified)}): " + ", ".join(verified[:40]))
    print(f"KNOWN types/members referenced ({len(bare_known)}): " + ", ".join(bare_known[:40]))
    if unverified:
        print(f"UNVERIFIED qualified ({len(unverified)}) -- NOT in the 7.2 API index, must NOT be asserted:")
        for u in unverified:
            print(f"  X {u}")
    else:
        print("UNVERIFIED qualified (0)")
    if bare_unknown:
        print(f"(info) bare PascalCase not in index ({len(bare_unknown)}): " + ", ".join(bare_unknown[:30]))

    sys.exit(1 if unverified else 0)


if __name__ == "__main__":
    main()
