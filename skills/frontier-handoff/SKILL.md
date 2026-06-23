---
name: frontier-handoff
description: Package the user's current stuck situation -- the code they're working on, the exact problem or hallucination they hit, what they already tried, their environment, and what they want -- into ONE clean, self-contained prompt that a frontier model on another machine (Claude / GPT / Gemini) can act on immediately with zero access to their files. Use this WHENEVER the user is on a weak, local, offline, or air-gapped model and says they are stuck, hitting hallucinations or quality/performance limits, or asks for a prompt to send to a "stronger / frontier / 상위 / better" model -- phrases like "이거 정리해서 프론티어 모델한테 물어볼 프롬프트 만들어줘", "상위 모델용 프롬프트", "hand this off", "escalate this to a better model", "make a prompt I can paste into Claude", even if they never say the word "handoff". Auto-collects the relevant code/error/diff and always ends the prompt with a directive telling the frontier model to answer as a small-step plan a weak offline model can apply.

# Frontier Handoff Prompt Builder

You are on a weak / offline model and have hit a wall. Your job is to package everything a strong
frontier model on a DIFFERENT machine needs to solve this **cold**, in a single paste-ready prompt.

The one rule that drives everything: **the frontier model has NONE of your local context.** It cannot
open your files, run your code, see your error, or read your repo. If a stranger with zero access to
this machine could not act on the prompt, it is not finished. Build for that reader.

## Workflow

1. **Pin the ask first.** Decide what the user wants the frontier model to *do*: fix a bug, explain a
   behavior, propose an approach, review a design, or unstick a hallucination. If it is not clear from
   the conversation, ask one short question -- do not guess.

2. **Auto-collect the context** (do not make the user retype what you can read yourself):
   - **Code**: read the file(s) in play -- the one being edited, or the ones the user names. Include the
     *minimal relevant span* (the failing function plus the symbols it depends on), each marked with
     `path:line`. Do NOT dump the whole repo; a focused, complete excerpt beats a giant paste.
   - **Problem**: capture the exact symptom -- the error text, stack trace, wrong output, or the
     hallucinated claim -- **quoted verbatim**, not paraphrased. Paraphrasing loses the detail the
     frontier model needs.
   - **What was tried**: recent attempts and why they failed. If this is a git repo, `git diff` /
     `git log -p -3` shows what was just changed; include the relevant part.
   - **Environment & constraints**: language + framework + versions; that you are offline / air-gapped
     on a weak local model; anything the frontier model must not assume it can do (no internet, can't
     run a specific tool, must stay in this framework version). For any library/API question, include
     the **exact library version** -- API availability differs by version, so a vague "LightningChart"
     turns the answer into a guess. Also state the hard constraint that decides the approach (e.g. "this
     runs before render -- is deferring acceptable, or must it work synchronously?").

3. **Assemble** the Goal..Ask sections using the template below.

4. **Finalize deterministically -- always run the script.** Run
   `python scripts/finalize-handoff.py <draft-file>` on the assembled draft. The script **appends the
   mandatory response directive verbatim** -- the block telling the frontier model to answer as a
   small-step, explicit, offline-aware plan -- so it is in EVERY handoff and a weak model running this
   skill can never forget it. Emit the script's output as ONE copy-ready fenced block, nothing else
   around it.

## Template

Fill every section. Drop a section only if it is genuinely not applicable. Keep each section tight.

```markdown
## Goal
<What I am building and what I am trying to achieve. 1-3 sentences.>

## Problem
<The exact failure, quoted verbatim: error/stack trace, wrong output, or the hallucinated claim.
What I expected vs what happened.>

## What I already tried
<Recent attempts and why each did not work. Relevant recent changes (diff) if any.>

## Relevant code
<Minimal but COMPLETE code to understand the problem, each block tagged with its path:line.
Include the symbols the failing code depends on so the reader is not guessing.>

## Environment & constraints
<Language + framework + versions. Offline / air-gapped on a weak local model. Anything the
frontier model must not assume (no internet, cannot run X, must stay on version Y).>

## Ask
<ONE clear sentence: exactly what you want back. Request the answer in a form you can apply
OFFLINE -- e.g. "give the corrected function as a complete code block" or "as a unified diff" --
because you will paste it back into the air-gapped box by hand.>
```

> You do NOT write the closing "## How to answer (the implementer is a weak offline model)" section.
> `finalize-handoff.py` appends it verbatim at the end of every handoff, so it is guaranteed to be
> there even when a weak model runs this skill. Stop your draft at `## Ask`.

## Example

**User (on the air-gapped box):** "json 파싱이 자꾸 깨지는데 로컬 모델은 계속 엉뚱한 답만 줘. 프론티어한테 물어볼 프롬프트 만들어줘"

After reading `parser.py`, the traceback, and the recent diff, you emit:

```markdown
## Goal
Parse a vendor's UTF-8 BOM JSON config in a Python 3.12 CLI on Windows.

## Problem
`json.load(open(path))` raises:
`json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)`
Expected: a parsed dict. Happens only for files exported by the vendor tool.

## What I already tried
Switched to `open(path, encoding="utf-8")` -- still fails. The file starts with bytes EF BB BF (a UTF-8 BOM).

## Relevant code
`config_loader.py:14`
```python
def load_config(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)   # fails on BOM-prefixed files
```

## Environment & constraints
Python 3.12, Windows PowerShell 5.1, offline (no pip). Must use stdlib only.

## Ask
Give the corrected `load_config` as a complete code block that handles the BOM with stdlib only.
```

(You stop at `## Ask`. Then `finalize-handoff.py` appends the standard
"## How to answer (the implementer is a weak offline model)" directive, so the final emitted prompt
ends with the small-step / explicit / offline-aware instruction every time.)

## Why this shape works

A frontier model does its best work when the prompt is **focused and complete**, not when it is a huge
context dump or a vague one-liner. Goal sets direction, the verbatim Problem pins the failure, "What I
tried" stops it from suggesting things you ruled out, minimal-but-complete code lets it reason without
access to your repo, constraints stop it from proposing things you cannot run, and a sharp single Ask
(in an apply-offline format) gives you something you can paste straight back. Self-containment is the
whole game -- the reader has nothing but your prompt.

And critically, this is a **round-trip**: you are not the implementer -- a weak local model is. So the
prompt also tells the frontier model to answer as a small-step executable plan, decided not just
surveyed, because the thing that carries out the fix can't bridge gaps or make judgment calls the way
you could. A brilliant but monolithic answer is worth less here than a plain, step-by-step one a weak
model can follow without thinking.
