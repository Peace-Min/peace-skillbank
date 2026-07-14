# SparrowCommentFix

Deterministic net8 console tool that fixes **comment-trivia-only** style issues flagged by the Sparrow
(파수) static analyzer. It is the **Track B** deterministic fixer of the Sparrow pipeline: the mechanical,
judgement-free comment clean-ups that a weak local/air-gapped LLM should never touch.

It uses **Roslyn** (`Microsoft.CodeAnalysis.CSharp`) to parse each `.cs` file with
`CSharpSyntaxTree.ParseText`, edits **only comment trivia**, and atomically rewrites the file. It **never
loads a project**, so legacy non-SDK `.csproj` / .NET Framework 4.7.2 targets are irrelevant — it operates
on `.cs` text directly.

## Correctness guarantee (non-negotiable)

It is **not regex-based.** Because every edit is confined to spans Roslyn identifies as comment trivia, a
`//` or `/*` that appears **inside a string or char literal is never touched** — e.g. `"http://example.com"`
and `"a//b"` are left byte-identical. This guarantee is covered by the SAFETY fixtures.

## CLI

```
SparrowCommentFix <file.cs> [<file2.cs> ...] [--files-from <index.csv>] [--root <dir>] --rules <k1,k2,...|all> [--dry-run]
```

- Positional args are `.cs` file paths.
- `--files-from <csv>` reads a SparrowXlsExport `index.csv` and takes the **distinct `파일명`** values (CSV
  quoting handled). Paths are resolved against `--root` (default: current directory).
- Positional files + `--files-from` files are **unioned, de-duplicated** by full path, order-stable.
- `--rules` is **required**. Comma-separated keys, or `all` for all four.
- `--dry-run` computes and reports would-change counts but **writes nothing**.
- A missing input file is a `WARN:` to stderr and is skipped; if **no** valid files remain, exit code `2`.

Exit codes: `0` success, `1` runtime error, `2` usage/validation error.

## Rules (this increment: 4)

| key | Sparrow checker | what it does | key guards |
|---|---|---|---|
| `space` | `FORMATTING.COMMENT.MISSING_SPACE_AFTER_DELIMITER` | `//x`→`// x`, `///x`→`/// x`, `/*x*/`→`/* x*/` | untouched if next char is whitespace, another `/`, or (block) `*`; `//`/`////` untouched |
| `period` | `FORMATTING.COMMENT.MISSING_PERIOD` | append `.` to comment content | only when the last content char is a **letter** (ASCII / Hangul / CJK) or **digit**; skips dividers (`// ----`, `/****/`) and content already ending in punctuation |
| `capitalize` | `FORMATTING.COMMENT.LOWERCASE_FIRST_LETTER` | uppercase the first content letter | only an **ASCII** lowercase first letter; Hangul/CJK/digit/already-uppercase left alone |
| `blankline` | `MISSING_BLANK_LINE_BEFORE_COMMENT` | insert one blank line before a comment that directly follows a code line | skipped if the preceding line is blank, is itself a comment, ends by opening a block (`{`), or the comment is the file's first line; only the first comment of a run gets one |

Every rule is **idempotent** — running it twice changes nothing.

### `asterisk` is intentionally pending

A 5th rule `asterisk` (`FORMATTING.COMMENT.BLOCK_OF_ASTERISK`) is **not implemented yet**, pending real
Sparrow examples. Passing `--rules asterisk` (or any unknown key) exits `2` with a message naming the valid
keys. The rule registry is structured so `asterisk` slots in later as a small diff.

## Per-checker commits

Run **one rule at a time** (e.g. `--rules period`) so that run's diff equals exactly that one Sparrow
checker's fixes — matching the pipeline's "규칙/체커별 커밋" gate.

## Encoding / newline preservation

Each edited file keeps its original **UTF-8 BOM presence** and its existing **newlines**; the `blankline`
insert uses the file's **dominant** newline (CRLF vs LF). Files whose bytes do not round-trip as UTF-8 are
skipped with a `WARN` (never risk corrupting non-UTF-8 bytes). Writes are atomic (temp file in the same
directory, then replace) and happen **only when the bytes actually change** (no mtime churn).

## How it's tested

`tests/sparrow-commentfix-fixtures.ps1` builds the tool and runs synthetic `.cs` fixtures covering each
rule (before/after), the string-literal safety guarantee, idempotency, `--dry-run`, `--files-from`, and the
unknown-rule exit code. Wired into the validate gate:

```
powershell -ExecutionPolicy Bypass -File tests/validate.ps1 -IncludeCommentE2E
```

## Air-gap bundling

The built `SparrowCommentFix` exe ships in the `dotnet-gcdump-offline` bundle, mirroring how SparrowXlsExport
is delivered into the closed network.
