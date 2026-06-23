#!/usr/bin/env python3
"""
Finalize a frontier-handoff prompt: append the mandatory response directive deterministically.

The fix will be applied by a WEAK offline local model, so every handoff MUST end by telling the
frontier model to answer as a small-step, explicit, offline-aware plan. Because the SCRIPT appends it
verbatim (not the model), it is guaranteed on every prompt even when a weak model runs this skill.

(No secret/redaction filtering: the user controls what goes into the prompt and won't put sensitive
data into a question meant for an external model.)

Usage:
  python finalize-handoff.py <draft-file>      # draft = the assembled Goal..Ask sections
  type draft.md | python finalize-handoff.py -
Exit 0 on success; exit 2 if <draft-file> cannot be read. Reads UTF-8 (BOM-safe) from a file or
stdin, prints UTF-8.
"""
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass
try:
    # Without this, Windows decodes stdin with the locale codepage (cp949 here), so a piped UTF-8
    # draft -- Korean text, or a BOM -- mis-decodes and print() then raises. The file path already
    # reads UTF-8 explicitly; this makes the documented `... | finalize-handoff.py -` form safe too.
    sys.stdin.reconfigure(encoding="utf-8")
except Exception:
    pass

# The constant that MUST end every handoff. Single source of truth; appended verbatim.
RESPONSE_DIRECTIVE = """## How to answer (the implementer is a weak offline model)
Your answer will be applied by a WEAK local LLM with no internet, not by me directly. So:
- Open with ONE recommended approach -- decide for me; do not just list options. If you compare
  alternatives, pick a winner and give the reason in one line.
- Then give a numbered plan of SMALL, independently-applyable steps. For each step: the exact
  `file:line` to touch, the precise code to add or replace (a COMPLETE snippet -- never "adjust X"
  or "handle the case"), and a one-line check that it worked.
- Be EXPLICIT over clever: spell out exact names, values, and conditions. Avoid any step that needs
  judgment a weak offline model cannot make.
- Assume an OFFLINE / air-gapped environment: no internet, no new packages or tools, and stay within
  the language / framework / library versions stated above.
"""


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "-"
    if src == "-":
        text = sys.stdin.read()
    else:
        try:
            text = open(src, encoding="utf-8-sig").read()
        except OSError as e:
            sys.stderr.write(f"finalize-handoff: cannot read draft file {src!r}: {e}\n")
            sys.exit(2)
    body = text.rstrip()
    # Guard: never duplicate the directive if the draft already contains it. Anchor to the actual
    # heading LINE, not a bare substring -- otherwise a draft that merely *mentions* the directive's
    # title in prose (e.g. "the model ignores the How to answer (...) section") would suppress the
    # append and silently drop the one thing this script exists to guarantee.
    heading = "## How to answer (the implementer is a weak offline model)"
    already = any(ln.strip() == heading for ln in body.splitlines())
    if already:
        final = body + "\n"
    else:
        final = body + "\n\n" + RESPONSE_DIRECTIVE.rstrip() + "\n"
    print(final)
    sys.exit(0)


if __name__ == "__main__":
    main()
