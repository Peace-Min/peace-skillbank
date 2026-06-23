#!/usr/bin/env python3
"""
Verify step / script (Tier 1) -- an agent-run verifier, NOT an automatic Claude Code hook (nothing
in the harness runs it for you). Check that every API symbol cited in a draft answer exists in the
local DLL API index:
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

# Common BCL / LINQ / collection members. These are .NET framework members, NOT LightningChart 7.2
# API, so they are absent from the index by design -- yet they appear constantly in real usage
# answers (e.g. `ViewXY.XAxes.Count`, `series.Add(...)`, `XAxes.First()`). Treat them as
# non-flagging on the dotted-path nets, the symmetric escape hatch the constructor-arity check
# already grants to legitimate BCL types. They are not the hallucination this script targets
# (invented LC-specific members like RainbowMode/AddRainbowAxis), and a model "inventing" a member
# named exactly `Count`/`Add` on the wrong type is not the failure mode worth false-rejecting for.
BCL_MEMBERS = {
    "Count", "Length", "Add", "AddRange", "Remove", "RemoveAt", "RemoveRange", "Clear",
    "Insert", "Contains", "IndexOf", "First", "FirstOrDefault", "Last", "LastOrDefault",
    "Item", "ToString", "Equals", "GetHashCode", "GetType", "ToList", "ToArray", "AsEnumerable",
    "Where", "Select", "Any", "All", "Key", "Value", "Keys", "Values", "Sort", "Reverse",
    "Min", "Max", "Sum", "Average", "CopyTo", "Find", "Exists", "ForEach", "GetEnumerator",
}


def default_ref_dir():
    # Resolve where the local corpus lives, kept SYMMETRIC with setup-local-corpus.ps1's output dir:
    #   1. ${CLAUDE_PLUGIN_DATA}/references -- installed-plugin persistent data dir (env set inside
    #      Claude Code). Honored even if not built yet, so the "not built" message points at the real
    #      location instead of the read-only plugin cache.
    #   2. ~/.claude/plugins/data/*peace-skillbank*/references -- the same data dir discovered on disk
    #      when running from the read-only plugin cache outside Claude Code (no env var).
    #   3. the script-relative references/ -- repo / dev checkout.
    data = os.environ.get("CLAUDE_PLUGIN_DATA")
    if data:
        return os.path.join(data, "references")
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if (os.sep + "plugins" + os.sep + "cache" + os.sep) in (here.replace("/", os.sep) + os.sep):
        import glob
        home = os.environ.get("USERPROFILE") or os.path.expanduser("~")
        hits = sorted(glob.glob(os.path.join(home, ".claude", "plugins", "data", "*peace-skillbank*", "references")))
        if hits:
            return hits[0]
    return os.path.join(here, "references")


def _strip_arity(name):
    # Reflection renders a generic type as "Name`N" (e.g. EventArgs`2); the model cites it
    # without the backtick arity. Normalize both sides so real generic members still verify.
    return re.sub(r"`\d+$", "", name)


def load_index(ref_dir):
    types, qualified, members, ctor_arities = set(), set(), {}, {}
    j = os.path.join(ref_dir, "api-index.json")
    if os.path.exists(j):
        data = json.load(open(j, encoding="utf-8-sig"))
        for t in data.get("types", []):
            tname = _strip_arity(t["name"])
            types.add(tname)
            if t.get("kind") == "enum":
                names = t.get("values", [])
            else:
                names = [x["n"] for x in t.get("props", [])] + [x["n"] for x in t.get("methods", [])]
                arities = set(len(c.get("params", [])) for c in t.get("ctors", []))
                if arities:
                    ctor_arities[tname] = arities
            for nm in names:
                qualified.add(f"{tname}.{nm}")
                members.setdefault(nm, set()).add(tname)
        return types, qualified, members, ctor_arities
    s = os.path.join(ref_dir, "api-symbols.txt")
    if os.path.exists(s):
        for ln in open(s, encoding="utf-8-sig"):
            ln = ln.strip()
            if not ln:
                continue
            m = re.match(r"^(.+)\.\.ctor\((\d+)\)$", ln)
            if m:
                tname = _strip_arity(m.group(1))
                ctor_arities.setdefault(tname, set()).add(int(m.group(2)))
                types.add(tname)
                continue
            if "." in ln:
                a, b = ln.split(".", 1)
                a = _strip_arity(a)
                qualified.add(f"{a}.{b}"); types.add(a); members.setdefault(b, set()).add(a)
            else:
                types.add(_strip_arity(ln))
    return types, qualified, members, ctor_arities


def _strip_namespace_lines(text):
    """Drop C# `using ...;` directives and `namespace ...` declarations before symbol extraction.
    They are import/scoping lines, not API assertions; their dotted namespace paths (e.g.
    `Arction.Wpf.Charting`) would otherwise be misread as qualified Type.Member citations and
    false-flagged as unverified. The snippet's actual API usage lives on its own lines and is still
    checked. SKILL.md tells the agent to QUOTE real code, so quoted `using` lines are expected input."""
    out = []
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith("using ") and s.endswith(";"):
            continue
        if s.startswith("namespace "):
            continue
        out.append(ln)
    return "\n".join(out)


def candidates(text):
    qual, bare = set(), set()
    for m in re.findall(r"\b([A-Z][A-Za-z0-9]+\.[A-Za-z_][A-Za-z0-9_]+)\b", text):
        qual.add(m)
    for m in re.findall(r"\b([A-Z][a-z0-9]+(?:[A-Z][a-z0-9]*)+)\b", text):
        bare.add(m)
    return qual, bare


def _strip_code_literals(s):
    """Replace double-quoted string literals with a single placeholder and drop comments, so commas
    or parens inside them cannot corrupt constructor argument counting. A literal still counts as one
    argument, so it collapses to a non-delimiter placeholder rather than vanishing. NOTE: a lone ASCII
    apostrophe is NOT treated as a char-literal opener -- the input is English prose+code where
    apostrophes are overwhelmingly contractions/possessives, and treating `'` as a delimiter would let
    "the series' new ChartXY(...)" swallow the following constructor call and skip the arity check."""
    out = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == '"':
            q = c
            i += 1
            while i < n:
                if s[i] == "\\":
                    i += 2
                    continue
                if s[i] == q:
                    i += 1
                    break
                i += 1
            out.append("0")
            continue
        if c == "/" and i + 1 < n and s[i + 1] == "/":
            while i < n and s[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and s[i + 1] == "*":
            i += 2
            while i + 1 < n and not (s[i] == "*" and s[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def constructor_calls(text):
    """Find `new Type(...)` (incl. `new Type<T>(...)`) and count its top-level arguments,
    paren/bracket aware and ignoring commas/parens inside string literals or comments."""
    text = _strip_code_literals(text)
    out = []
    # Optional <...> generic argument list between the type name and `(` (one nesting level).
    for m in re.finditer(r"\bnew\s+([A-Z][A-Za-z0-9_]*)\s*(?:<[^()]*>)?\s*\(", text):
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


def inline_code_tokens(text):
    """Contents of single-backtick inline-code spans (`like.this`) -- the high-signal place a
    model cites an API. A single-word PascalCase member (`Visible`, `Smoothing`) is invisible to
    candidates() (which needs 2+ humps), so an invented one would otherwise slip through unchecked.
    Restricting this to backtick spans keeps ordinary capitalized prose from being flagged."""
    return [m.strip() for m in re.findall(r"`([^`\n]+)`", text)]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv
    src = args[0] if len(args) > 0 else "-"
    ref_dir = args[1] if len(args) > 1 else default_ref_dir()
    text = sys.stdin.read() if src == "-" else open(src, encoding="utf-8-sig").read()
    # Strip `using`/`namespace` lines once; all symbol nets below scan this, never the raw text,
    # so quoted import directives don't get misread as invented qualified symbols.
    scan = _strip_namespace_lines(text)

    types, qualified, members, ctor_arities = load_index(ref_dir)
    if not types:
        print(f"api-index not built at {ref_dir} (run scripts/setup-local-corpus.ps1). Cannot verify.")
        sys.exit(2)

    qual, bare = candidates(scan)
    verified, unverified = [], []
    for c in sorted(qual):
        base, mem = c.split(".", 1)
        mem0 = mem.split(".")[0]
        if c in qualified or f"{base}.{mem0}" in qualified:
            verified.append(c)
        elif mem0 in BCL_MEMBERS:
            continue  # BCL/collection member (e.g. .Count/.Add), not an invented 7.2 API -- do not flag
        else:
            unverified.append(c)

    bare_known = sorted(b for b in bare if b in types or b in members)
    bare_unknown = sorted(b for b in bare if b not in types and b not in members)

    # Chained citations Type.A.B... -- candidates() only verifies the head Type.A pair, so a deeper
    # invented segment (e.g. an extra .Frobnicate) would otherwise escape every net. Flag any chain
    # whose deeper segment is not a known member/type name.
    chain_unverified = []
    for ch in sorted(set(re.findall(r"\b[A-Z][A-Za-z0-9]+(?:\.[A-Za-z_][A-Za-z0-9_]+){2,}\b", scan))):
        deeper = ch.split(".")[2:]
        if any(seg not in members and seg not in types and seg not in BCL_MEMBERS for seg in deeper):
            chain_unverified.append(ch)

    # Single-word PascalCase identifiers cited inside inline-code spans. These bypass candidates()
    # entirely, so they are the main leak path for invented members on a weak model.
    code_single = set()
    for tok in inline_code_tokens(scan):
        if re.match(r"^[A-Z][A-Za-z0-9]+$", tok):  # one PascalCase word (no dot/space/parens)
            code_single.add(tok)
    code_unknown = sorted(t for t in code_single if t not in types and t not in members)
    code_member_bare = sorted(t for t in code_single if t in members and t not in types)

    ctor_issues = []
    # NOTE: we check constructor ARITY but deliberately do not flag an unknown ctor type as invented.
    # A multi-hump invented type (new TotallyMadeUpSeries(...)) is already caught by the strict
    # bare-name net; flagging every unknown ctor type would false-positive on legitimate BCL types
    # used in examples (new List<int>(), new StringBuilder(), new Point(...)), which are out of the
    # 7.2 API scope but not hallucinations.
    for typ, count in constructor_calls(scan):
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
    if chain_unverified:
        print(f"UNVERIFIED chained members ({len(chain_unverified)}) -- a deeper segment is not in the 7.2 API index:")
        for c in chain_unverified:
            print(f"  X {c}")
    if bare_unknown:
        tag = "REVIEW -- strict: qualify as Type.Member or remove" if strict else "info"
        print(f"({tag}) bare PascalCase not in index ({len(bare_unknown)}): " + ", ".join(bare_unknown[:30]))
    if code_unknown:
        tag = "UNVERIFIED inline-code -- NOT in the 7.2 API index" if strict else "info"
        print(f"({tag}) inline-code identifiers not found ({len(code_unknown)}): " + ", ".join(code_unknown[:30]))
    if strict and code_member_bare:
        print(f"(REVIEW -- strict: qualify as Type.Member) bare inline members ({len(code_member_bare)}): "
              + ", ".join(code_member_bare[:30]))

    fail = (bool(unverified) or bool(ctor_issues) or bool(chain_unverified)
            or (strict and bool(bare_unknown)) or (strict and bool(code_unknown)))
    sys.exit(1 if fail else 0)


if __name__ == "__main__":
    main()
