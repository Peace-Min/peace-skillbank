#!/usr/bin/env python3
"""
Finalize a frontier-handoff prompt deterministically (stdlib only -> air-gapped friendly).

Two jobs, done by the SCRIPT (not left to the model) so they can never be forgotten:
  1. REDACT: mask high-severity secrets (keys, tokens, passwords, private keys) and flag review
     items (absolute paths, emails, IPs) -- the prompt is about to leave the box.
  2. APPEND the mandatory response directive: the fix will be applied by a WEAK offline local model,
     so every handoff MUST end by telling the frontier model to answer as a small-step, explicit,
     offline-aware plan. Because the script appends it verbatim, it is guaranteed in every prompt.

Usage:
  python finalize-handoff.py <draft-file>     # draft = the assembled Goal..Ask sections
  type draft.md | python finalize-handoff.py -
Prints a findings report, then the FINAL HANDOFF PROMPT (redacted body + appended directive).
Exit 0 always. Reads UTF-8 (BOM-safe), prints UTF-8.
"""
import sys, re

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

SECRET_ASSIGN = re.compile(
    r'(?i)\b(api[_-]?key|secret|client[_-]?secret|token|access[_-]?token|password|passwd|pwd|access[_-]?key)\b'
    r'(\s*[:=]\s*)(["\']?)([^\s"\']+)\3')
HIGH = [
    ("aws-access-key", re.compile(r'\bAKIA[0-9A-Z]{16}\b')),
    ("bearer-token", re.compile(r'(?i)\bbearer\s+[A-Za-z0-9._\-]{20,}')),
    ("connstring-password", re.compile(r'(?i)\bpassword\s*=\s*[^;\s]+')),
    ("private-key-block",
     re.compile(r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----', re.S)),
]
REVIEW = [
    ("windows-path", re.compile(r'\b[A-Za-z]:\\[^\s"\'<>|*?\r\n]+')),
    ("unix-home-path", re.compile(r'/(?:home|Users)/[^\s"\'<>|*?\r\n]+')),
    ("email", re.compile(r'\b[\w.+-]+@[\w-]+\.[\w.-]+\b')),
    ("ipv4", re.compile(r'\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b')),
]


def preview(s, keep=4):
    s = s.replace("\n", " ").strip()
    return s if len(s) <= keep * 2 + 3 else s[:keep] + "..." + s[-keep:]


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "-"
    text = sys.stdin.read() if src == "-" else open(src, encoding="utf-8-sig").read()

    high = []

    def repl_secret(m):
        high.append(("secret-assignment", m.group(0)))
        return f"{m.group(1)}{m.group(2)}<REDACTED:secret>"

    masked = SECRET_ASSIGN.sub(repl_secret, text)
    for name, rx in HIGH:
        def r(m, name=name):
            high.append((name, m.group(0)))
            return f"<REDACTED:{name}>"
        masked = rx.sub(r, masked)

    review = []
    for name, rx in REVIEW:
        for m in rx.finditer(masked):
            review.append((name, m.group(0)))

    # Guard: never duplicate the directive if the draft already pasted it.
    body = masked.rstrip()
    if "How to answer (the implementer is a weak offline model)" not in body:
        final = body + "\n\n" + RESPONSE_DIRECTIVE.rstrip() + "\n"
    else:
        final = body + "\n"

    print("=== REDACTION: HIGH (masked automatically) ===")
    print("\n".join(f"  [{n}] {preview(v)}" for n, v in high) or "  (none)")
    print("=== REDACTION: REVIEW (decide before sending -- left in text) ===")
    if review:
        seen = {}
        for n, v in review:
            seen.setdefault(n, set()).add(v)
        for n, vs in seen.items():
            print(f"  [{n}] x{len(vs)}: " + ", ".join(preview(x) for x in list(vs)[:5]))
    else:
        print("  (none)")
    print("=== FINAL HANDOFF PROMPT (redacted + mandatory response directive appended) ===")
    print(final)
    sys.exit(0)


if __name__ == "__main__":
    main()
