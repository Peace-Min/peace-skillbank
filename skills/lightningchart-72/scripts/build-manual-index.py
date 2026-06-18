#!/usr/bin/env python3
"""
Chunk the licensed LightningChart 7.2 User's Manual PDF into per-section markdown
files + manual-index.json (Tier 2 = semantics / how-to).

- The PDF path is a PARAMETER. The PDF and the generated chunks are LOCAL and
  gitignored; only this script (machinery) is committed.
- Chunking is anchored to the manual's own Table of Contents so body step-lists
  ("1. do this") are not mistaken for section headings.

Usage:
  python build-manual-index.py "C:/path/to/LightningChart Users Manual.pdf" [out_references_dir]

Requires: pypdf  (pip install pypdf) -- only on the one-time build machine.
"""
import sys, os, re, json, glob
from pypdf import PdfReader

DOTLEADER = re.compile(r"\.{4,}")
TOC_LINE = re.compile(r"^\s*(\d+(?:\.\d+)*)\s+(.+?)\s*\.{2,}\s*(\d+)\s*$")
HEAD_LINE = re.compile(r"^\s*(\d+(?:\.\d+)*)\s+(\S.{0,80})$")
NOISE = re.compile(r"LightningChart Ultimate SDK User|Copyright Arction Ltd", re.I)


def clean(s: str) -> str:
    return (s.replace("��", "'").replace("�", "'")
             .replace("´", "'").replace("’", "'"))


def main():
    if len(sys.argv) < 2:
        print("usage: build-manual-index.py <pdf> [out_references_dir]"); sys.exit(2)
    pdf = sys.argv[1]
    ref_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "references")
    manual_dir = os.path.join(ref_dir, "manual")
    os.makedirs(manual_dir, exist_ok=True)
    # Safe cleanup: drop stale section chunks from a previous run, but only inside the
    # intended 'manual' directory (never an arbitrary path).
    if os.path.basename(os.path.normpath(manual_dir)) == "manual":
        for old in glob.glob(os.path.join(manual_dir, "*.md")):
            os.remove(old)

    reader = PdfReader(pdf)
    pages = []
    for p in reader.pages:
        try: pages.append(clean(p.extract_text() or ""))
        except Exception: pages.append("")

    def is_toc(t):
        return sum(1 for ln in t.splitlines() if DOTLEADER.search(ln)) >= 5

    # 1) Authoritative section list from the TOC pages.
    toc = {}            # section -> title
    toc_order = []
    for t in pages:
        if not is_toc(t):
            continue
        for ln in t.splitlines():
            m = TOC_LINE.match(ln.strip())
            if m:
                sec, title = m.group(1), clean(m.group(2)).strip()
                if sec not in toc:
                    toc[sec] = title; toc_order.append(sec)

    # 2) Walk body pages; open a chunk when a known, not-yet-used section heading appears.
    chunks, used = [], set()
    cur = None
    for idx, t in enumerate(pages):
        if is_toc(t):
            continue
        page_no = idx + 1
        for raw in t.splitlines():
            s = raw.strip()
            if NOISE.search(s):
                continue
            if s and not DOTLEADER.search(s):
                m = HEAD_LINE.match(s)
                if m and m.group(1) in toc and m.group(1) not in used and re.search(r"[A-Za-z]", m.group(2)):
                    sec = m.group(1)
                    cur = {"section": sec, "title": toc.get(sec) or clean(m.group(2)).strip(),
                           "page": page_no, "lines": []}
                    chunks.append(cur); used.add(sec)
                    continue
            if cur is not None:
                cur["lines"].append(s)

    # 3) Write per-section markdown + index.
    index = []
    for c in chunks:
        body = "\n".join(c["lines"]).strip()
        slug = c["section"].replace(".", "-")
        fname = f"{slug}.md"
        path = os.path.join(manual_dir, fname)
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"# {c['section']} {c['title']}\n_(manual p{c['page']})_\n\n{body}\n")
        kw = sorted(set(re.findall(r"[A-Za-z][A-Za-z0-9]{2,}", c["title"])))
        index.append({"section": c["section"], "title": c["title"], "page": c["page"],
                      "file": f"manual/{fname}", "keywords": kw})

    with open(os.path.join(ref_dir, "manual-index.json"), "w", encoding="utf-8") as f:
        json.dump({"source": os.path.basename(pdf), "sectionCount": len(index), "sections": index},
                  f, ensure_ascii=False, indent=1)

    print(f"Manual chunked: {len(index)} sections (TOC entries: {len(toc)}) -> {manual_dir}")


if __name__ == "__main__":
    main()
