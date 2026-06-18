#!/usr/bin/env python3
"""
Lightweight retrieval helper (stdlib only -> air-gapped friendly). Given query terms, return
matching manual sections (from manual-index.json) and matching API symbols (from api-symbols.txt).
The agent then reads the cited manual chunk(s) and confirms symbols in api-index.json.

Usage: python search.py "value range palette" [references_dir]
"""
import sys, os, re, json

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def default_ref_dir():
    # Resolve the corpus dir, kept SYMMETRIC with setup-local-corpus.ps1 and verify-symbols.py:
    #   1. ${CLAUDE_PLUGIN_DATA}/references (installed plugin, env set inside Claude Code),
    #   2. ~/.claude/plugins/data/*peace-skillbank*/references discovered on disk (cache run, no env),
    #   3. the script-relative references/ (repo / dev checkout).
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


def main():
    if len(sys.argv) < 2:
        print("usage: search.py <query> [references_dir]"); sys.exit(2)
    query = sys.argv[1]
    ref = sys.argv[2] if len(sys.argv) > 2 else default_ref_dir()
    terms = [t for t in re.findall(r"[A-Za-z0-9]+", query.lower())
             if len(t) >= 2 or any(c.isdigit() for c in t)]
    if not terms:
        print("(no usable query terms -- use more specific words)")

    print("== manual sections ==")
    mi = os.path.join(ref, "manual-index.json")
    if os.path.exists(mi):
        secs = json.load(open(mi, encoding="utf-8")).get("sections", [])
        scored = []
        for s in secs:
            hay = (s["title"] + " " + " ".join(s.get("keywords", []))).lower()
            score = sum(1 for t in terms if t in hay)
            if score:
                scored.append((score, s))
        for score, s in sorted(scored, key=lambda x: -x[0])[:8]:
            print(f"  §{s['section']} {s['title']} (p{s['page']}) -> {s['file']}")
        if not scored:
            print("  (no manual section match)")
    else:
        print("  (manual-index.json not built)")

    print("== api symbols ==")
    sp = os.path.join(ref, "api-symbols.txt")
    if os.path.exists(sp):
        syms = [l.strip() for l in open(sp, encoding="utf-8") if l.strip()]
        hits = [s for s in syms if any(t in s.lower() for t in terms)]
        for s in hits[:25]:
            print(f"  {s}")
        if not hits:
            print("  (no symbol match)")
    else:
        print("  (api-symbols.txt not built)")


if __name__ == "__main__":
    main()
