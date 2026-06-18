#!/usr/bin/env python3
"""
Verify hook (Tier 1). Check that every API symbol cited in a draft answer exists in the local DLL
API index:
- qualified Type.Member must exist (unknown -> UNVERIFIED, blocks).
- bare PascalCase not in the index -> info, or (with --strict) blocks.
- new Type(args) constructor calls: the argument count must match a real 7.2 constructor arity
  (the index records constructors); a mismatch -> UNVERIFIED.

Usage:
  python verify-symbols.py <draft.md> [references_dir] [--strict]
  type draft.md | python verify-symbols.py --strict -

Exit 1 if any qualified symbol, strict bare name, or constructor arity is unverified; exit 2 if the
index is not built. Reads references/api-index.json (falls back to api-symbols.txt). Stdlib only.
"""
import sys, os, re, json

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def load_index(ref_dir):
    types, qualified, members, ctor_arities = set(), set(), {}, {}
    j = os.path.join(ref_dir, "api-index.json")
    if os.path.exists(j):
        data = json.load(open(j, encoding="utf-8-sig"))
        for t in data.get("types", []):
            types.add(t["name"])
            if t.get("kind") == "enum":
                names = t.get("values", [])
            else:
                names = [x["n"] for x in t.get("props", [])] + [x["n"] for x in t.get("methods", [])]
                arities = set(len(c.get("params", [])) for c in t.get("ctors", []))
                if arities:
                    ctor_arities[t["name"]] = arities
            for nm in names:
                qualified.add(f'{t["name"]}.{nm}')
                members.setdefault(nm, set()).add(t["name"])
        return types, qualified, members, ctor_arities
    s = os.path.join(ref_dir, "api-symbols.txt")
    if os.path.exists(s):
        for ln in open(s, encoding="utf-8-sig"):
            ln = ln.strip()
            if not ln:
                continue
            m = re.match(r"^(.+)\.\.ctor\((\d+)\)$", ln)
            if m:
                ctor_arities.setdefault(m.group(1), set()).add(int(m.group(2)))
                types.add(m.group(1))
                continue
            if "." in ln:
                a, b = ln.split(".", 1)
                qualified.add(ln); types.add(a); members.setdefault(b, set()).add(a)
            else:
                types.add(ln)
    return types, qualified, members, ctor_arities


def candidates(text):
    qual, bare = set(), set()
    for m in re.findall(r"\b([A-Z][A-Za-z0-9]+\.[A-Za-z_][A-Za-z0-9_]+)\b", text):
        qual.add(m)
    for m in re.findall(r"\b([A-Z][a-z0-9]+(?:[A-Z][a-z0-9]*)+)\b", text):
        bare.add(m)
    return qual, bare


def constructor_calls(text):
    """Find `new Type(...)` and count its top-level arguments (paren/bracket aware)."""
    out = []
    for m in re.finditer(r"\bnew\s+([A-Z][A-Za-z0-9_]*)\s*\(", text):
        typ = m.group(1)
        i = m.end()
        depth = 1
        args = []
        buf = ""
        while i < len(text) and depth > 0:
            ch = text[i]
            if ch in "([{":
                depth += 1; buf += ch
            elif ch in ")]}":
                depth -= 1
                if depth == 0:
                    break
                buf += ch
            elif ch == "," and depth == 1:
                args.append(buf); buf = ""
            else:
                buf += ch
            i += 1
        count = (len(args) + 1) if (buf.strip() or args) else 0
        out.append((typ, count))
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv
    src = args[0] if len(args) > 0 else "-"
    ref_dir = args[1] if len(args) > 1 else os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "references")
    text = sys.stdin.read() if src == "-" else open(src, encoding="utf-8-sig").read()

    types, qualified, members, ctor_arities = load_index(ref_dir)
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

    ctor_issues = []
    for typ, count in constructor_calls(text):
        if typ in ctor_arities and count not in ctor_arities[typ]:
            ctor_issues.append(
                f"new {typ}(...{count} args) -- no 7.2 constructor takes {count} args (valid: {sorted(ctor_arities[typ])})")

    print(f"VERIFIED qualified ({len(verified)}): " + ", ".join(verified[:40]))
    print(f"KNOWN types/members referenced ({len(bare_known)}): " + ", ".join(bare_known[:40]))
    if unverified:
        print(f"UNVERIFIED qualified ({len(unverified)}) -- NOT in the 7.2 API index, must NOT be asserted:")
        for u in unverified:
            print(f"  X {u}")
    else:
        print("UNVERIFIED qualified (0)")
    if ctor_issues:
        print(f"UNVERIFIED constructors ({len(ctor_issues)}) -- arity not in the 7.2 API index:")
        for c in ctor_issues:
            print(f"  X {c}")
    if bare_unknown:
        tag = "REVIEW -- strict: qualify as Type.Member or remove" if strict else "info"
        print(f"({tag}) bare PascalCase not in index ({len(bare_unknown)}): " + ", ".join(bare_unknown[:30]))

    fail = bool(unverified) or bool(ctor_issues) or (strict and bool(bare_unknown))
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
