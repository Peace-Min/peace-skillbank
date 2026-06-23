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
Exit 0 always. Reads UTF-8 (BOM-safe), prints UTF-8.
"""
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
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
    text = sys.stdin.read() if src == "-" else open(src, encoding="utf-8-sig").read()
    body = text.rstrip()
    # Guard: never duplicate the directive if the draft already pasted it.
    if "How to answer (the implementer is a weak offline model)" in body:
        final = body + "\n"
    else:
        final = body + "\n\n" + RESPONSE_DIRECTIVE.rstrip() + "\n"
    print(final)
    sys.exit(0)


if __name__ == "__main__":
    main()
