# frontier-handoff

You're working offline on a weak local model and you hit a wall -- a bug it can't fix, or it keeps
inventing APIs. Instead of hand-writing a long prompt to ask a stronger model on another machine, this
skill builds that prompt for you: it packages your current code, the exact error, what you tried, your
environment, and your ask into ONE paste-ready prompt a frontier model can act on with zero access to
your files.

Full human guide: [docs/frontier-handoff-usage.md](../../docs/frontier-handoff-usage.md).

## How to use it (you prepare nothing)

When you're stuck on the offline box:

1. **Just say what's wrong**, or ask for a handoff prompt. You don't paste code or fill a form -- the
   skill reads the relevant file(s) and error itself. For example:
   - "이 함수가 자꾸 NullReference 나는데 로컬 모델이 못 고쳐. **프론티어한테 넘길 프롬프트 만들어줘**"
   - "make me a handoff prompt for this JSON parsing bug"
   - "로컬 모델이 없는 메서드를 자꾸 추천해. 상위 모델한테 물어보게 정리해줘"
2. The skill collects the context, masks any secrets, and gives you **ONE copy-ready block**.
3. **Copy that block** and paste it into a frontier model (Claude / GPT / Gemini) on an internet machine.
4. The answer comes back as a **small-step plan**; paste each step back into your local model to apply it.

## Example

**You say:**

> parser.py에서 JSON 파싱이 깨지는데 로컬 모델이 자꾸 엉뚱한 답만 줘. 프론티어한테 물어볼 핸드오프 프롬프트 만들어줘

**You get** (one copy-ready block -- this is what you paste into the frontier model):

````markdown
## Goal
Parse a vendor's UTF-8-BOM JSON config in a Python 3.12 CLI on Windows.

## Problem
`json.load(f)` raises, verbatim:
`json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)`
Expected a parsed dict. Fails only for files exported by the vendor tool.

## What I already tried
`encoding="utf-8"` still fails; a hexdump shows the file starts with bytes `EF BB BF` (a UTF-8 BOM).

## Relevant code
`parser.py:1`
```python
def load_config(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)   # fails on BOM-prefixed files
```

## Environment & constraints
Python 3.12, Windows, offline / air-gapped, standard library only.

## Ask
Give the corrected `load_config` as a complete stdlib-only code block that handles the BOM.

## How to answer (the implementer is a weak offline model)
- Open with ONE recommended approach -- decide, don't just list options.
- Then a numbered plan of SMALL steps: exact `file:line`, complete code to add/replace, a one-line check.
- Be explicit; assume offline (no internet, no new packages).
````

The final "How to answer" section is **added automatically every time** -- it tells the frontier model
to reply as a step-by-step plan your weak local model can actually apply, instead of one big answer.

## How it works (under the hood)

You don't need this to use the skill, but for the curious: it fills a fixed 6-section template (Goal /
Problem / What I tried / Relevant code / Environment / Ask), then runs `scripts/finalize-handoff.py`,
which deterministically (a) masks secrets and flags absolute paths/emails/IPs for your review, and
(b) appends the response directive -- so the redaction and the directive happen on every handoff even
when a weak model runs the skill.

## No setup

Standard-library Python only -- no corpus, no dependencies, no install. Verified end-to-end against a
real weak local model (`qwen2.5-coder:7b` via Ollama): it fills the template, and the script masks the
secrets the weak model left in the draft.

## Privacy (the one thing to check)

The prompt leaves the air-gapped box for an external model, so **glance at the redaction report before
you paste**. Secrets are auto-masked, but absolute paths / internal names are only *flagged* -- you
decide whether to keep them. A leaked secret going to an outside model is the one irreversible mistake.
