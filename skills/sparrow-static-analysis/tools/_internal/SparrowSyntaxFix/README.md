# SparrowSyntaxFix

Deterministic Roslyn source rewriter for Sparrow (?뚯닔 ?뺤쟻遺꾩꽍) Track A code-rule findings that `SparrowSyntaxFix`
does not fully clear on the legacy **OSTES** project (.NET Framework 4.7.2, non-SDK `.csproj`). It parses C#
source text with Roslyn **syntax** APIs only ??it never loads an MSBuild project ??and rewrites at the syntax
level, preserving all trivia (comments/whitespace/newlines). No string/regex editing of code, ever.

Current implementation covers the Track A Roslyn expansion in `references/track-a-roslyn-policy.md`:
`nullvar`, `parens`, `objectvar-safe`, `foreachcast`, `obviousvar`, `objectvar-narrowing`, `localconst`,
`objectinitializer`, `arrayvar-safe`, and `arrayvar-narrowing`.
`foreachcast`, `objectinitializer`, `objectvar-narrowing`, `arrayvar-narrowing`, `localconst`, and `nullvar` are review-needed or operator-confirmed rules and must stay isolated in their
own rule run/commit.

## Implemented rules

### Rule 1 ??`nullcast`  (checker `PRACTICE.OBVIOUS_VARIABLE_TYPE.NOT_USED_IMPLICIT_TYPING`)

Sparrow wants `var`, but `var x = null;` is illegal C# so IDE0007 declines it. A cast lets `var` infer the
**identical** static type, so the transform is 100% semantics-preserving.

```
CComponentInfo clsComponentInfo = null;   ->   var clsComponentInfo = (CComponentInfo)null;
List<PropData> lst = null;                ->   var lst = (List<PropData>)null;
A.B.CThing x = null;                      ->   var x = (A.B.CThing)null;
IFoo c = null;                            ->   var c = (IFoo)null;
```

Matches ONLY a plain, single-declarator **local** statement whose sole initializer is the bare `null`
literal. Hard skips (left byte-identical):

- `= new ...` (object creation) ??not handled by current `nullcast`. The next policy splits this into
  `objectvar-safe` and `objectvar-narrowing` (review-needed); see `track-a-roslyn-policy.md`.
- `= default` / `= default(T)` ??out of scope.
- any non-`null` initializer (method call, member access, ternary, ...).
- already `var`; multi-declarator (`Foo a = null, b = null;`); `const`; `using` locals; fields/properties.

### Rule 2 ??`parens`  (checker `MISSING_PARENTHESIS_IN_EXPRESSION`)

Roslyn's IDE0048 treats "relational binds tighter than logical" as commonly understood and skips it; Sparrow
does not. Sparrow requires **every** operand of `&&` / `||` to be parenthesized ??not just the ambiguous ones.
(Confirmed by re-analysis: `(a) || b` is still flagged; only `(a) || (b)` clears it.)

```
if (nIndex > 0 && nIndex <= nCount - 1)          ->  if ((nIndex > 0) && (nIndex <= nCount - 1))
if (clsComponentInfo != null && clsDataTypeInfo != null)
                                                 ->  if ((clsComponentInfo != null) && (clsDataTypeInfo != null))
var z = a || b;                                  ->  var z = (a) || (b);              // atoms wrapped too
if (x > 0 || flag)                               ->  if ((x > 0) || (flag))           // comparison + atom
finfile.Name.Equals("x") || finfile.Name.Equals("y")
                                                 ->  (finfile.Name.Equals("x")) || (finfile.Name.Equals("y"))
if (a || b && c)                                 ->  if ((a) || ((b) && (c)))
```

**Every** operand is wrapped ??atoms (identifiers, literals, member access `a.b.c`, invocations `f()` /
`x.Equals(y)`, element access, `this`, unary `!x` / `-x`, casts), comparisons, arithmetic/bitwise, and the
**other** logical operator ??**except** (1) anything already parenthesized, and (2) a **same-operator** chain
(`a && b && c`), which is left flat so its leaves become `(a) && (b) && (c)` (not `((a) && (b)) && (c)`). A
partially-parenthesized expression from an earlier pass (`(a) || b`) is completed to `(a) || (b)`.

Both rules are **idempotent**: running twice makes no further change.

## Track A expansion rules

The CLI supports these rules:

| Rule | Transform | Commit policy |
|---|---|---|
| `objectvar-safe` | `Foo x = new Foo()` ??`var x = new Foo()` when declaration type and construction type match | normal |
| `foreachcast` | `foreach (XmlNode n in xs)` ??`foreach (var n in System.Linq.Enumerable.Cast<XmlNode>(xs))` | `review-needed` |
| `obviousvar` | `string s = "A"` ??`var s = "A"`; `double d = 20` ??`var d = (double)20` | normal |
| `objectvar-narrowing` | `IList<T> x = new List<T>()` ??`var x = new List<T>()` | `review-needed` |
| `localconst` | `const string s = "A"` ??`var s = "A"` | `review-needed` |
| `nullvar` | `Foo x;` / `Foo x = null;` ??`var x = (Foo)null;` | `review-needed` |
| `objectinitializer` | `Foo x = new Foo(); x.A = 1;` ??`var x = new Foo { A = 1 };` for consecutive assignments only | `review-needed` |
| `arrayvar-safe` | `int[] a = new int[] { 1, 2 };` ??`int[] a = { 1, 2 };` when array types match | normal |
| `arrayvar-narrowing` | `object[] a = new string[] { "A" };` ??`var a = new[] { "A" };` | `review-needed` |
| `forvar` | `for (int i = 0; ...)` ??`for (var i = 0; ...)` for a single-declarator, obvious-init for-loop (multi-declarator / method-call init never touched) | `review-needed` (opt-in, not in default set) |
| `fieldsplit` | `private double a, b, c;` ??one field per line, same indent, initializers/leading comment preserved (fields only) | `review-needed` (opt-in, not in default set) |
| `emptystmt` | `stmt; ;` ??`stmt;` — removes a redundant empty statement (`for(;;)` / labels / loop-body empties kept) | `review-needed` (opt-in, not in default set) |
| `forhoist` | `for (int i = 0, count = queue.Count; ...)` ??`var count = queue.Count;` + `for (var i = 0; ...)` — hoists non-loop declarators out of a multi-declarator for-init so the for stays single-declarator (dependency / name-collision / undeterminable-loop-var cases skipped) | `review-needed` (opt-in, not in default set) |

`review-needed` rules are still CLI-applied, but must be isolated in their own rule run and commit. Suggested
commit names:

```text
sparrow(A)! review-needed: static type narrowing to var
sparrow(A)! review-needed: simplify array declaration with static type narrowing
sparrow(A)! review-needed: demote local const to var
sparrow(A)! review-needed: initialize explicit locals as typed null
```

## One-shot runner policy

Normal operation must use `Run-SparrowSyntaxFix.ps1`, not direct `SparrowSyntaxFix --rules ...` calls.
When `-Rules` is omitted, the runner asks for the solution/folder path, then asks Y/N for
`foreachcast`, `objectinitializer`, `nullvar`, `objectvar-narrowing`, `localconst`, and
`arrayvar-narrowing`, then asks whether to commit. Direct `-Rules` usage is reserved for tests,
automation, and precise re-runs.

Default safe rules are `objectvar-safe`, `obviousvar`, `arrayvar-safe`, and `parens`.

## CLI

```
SparrowSyntaxFix <file-or-dir>... [options]

  --files-from <index.csv>  read target .cs paths from a CSV (?뚯씪紐?寃쎈줈 column) or a newline list;
                            relative paths resolve against --root
  --root <dir>              base directory for resolving relative paths (default: current dir)
  --rules <list>            comma list of Track A rules or 'all' (default: safe subset)
  --dry-run                 report per-file / per-rule counts without writing

exit codes: 0 = success (whether or not changes were made), 1 = real error, 2 = usage
```

When given a directory it recurses for `*.cs`, **excluding** generated/backup files by default:
`*.Designer.cs`, `*.g.cs`, `*.g.i.cs`, `*.AssemblyInfo.cs`, `AssemblyInfo.cs`, `TemporaryGeneratedFile_*.cs`,
`*.generated.cs`, and any file whose first ~3 lines contain `<auto-generated`.

Console output is greppable ??one line per changed file plus an aligned summary:

```
changed C:\...\Foo.cs  nullcast=2 parens=3
rules:            nullcast,parens
files found:      420
generated skip:   12
non-UTF8 skip:    0
files changed:    137
nullcast edits:   285
parens edits:     741
```

## One-call runner ??`Run-SparrowSyntaxFix.ps1` (沅뚯옣, Run-SparrowSyntaxFix.ps1 ???

?붾（??寃쎈줈留?二쇰㈃ ?숈옉?섎뒗 PowerShell ?щ꼫(Track A 2?④퀎). ?대??먯꽌 exe ?뺣낫 ??洹쒖튃蹂??ㅽ뻾 ??洹쒖튃蹂?而ㅻ컠(寃??媛?ν븳 ?⑥쐞). `references/Run-SparrowSyntaxFix.ps1`(SparrowSyntaxFix 1?④퀎)??吏?

```powershell
# ?먰걧: 洹몃깷 ?ㅽ뻾?섎㈃ ?붾（??寃쎈줈瑜?臾산퀬, ?댁뼱??而ㅻ컠 ?щ?(Y/N)瑜?臾쇱뼱遊?
.\Run-SparrowSyntaxFix.ps1

# 寃쎈줈瑜?誘몃━ 以섎룄 ??而ㅻ컠 ?щ????ъ쟾??臾쇱쓬). ?붾（??.sln) ?먮뒗 ?뚯뒪 ?대뜑 寃쎈줈.
.\Run-SparrowSyntaxFix.ps1 -Solution C:\Work\OSTES\OSTES.sln

.\Run-SparrowSyntaxFix.ps1 -Solution ...\OSTES.sln -DryRun                 # 誘몃━蹂닿린(蹂寃?????
.\Run-SparrowSyntaxFix.ps1 -Solution ...\OSTES.sln -Commit                 # 洹쒖튃蹂??먮룞 而ㅻ컠
.\Run-SparrowSyntaxFix.ps1 -Solution ...\OSTES.sln -Rules nullcast         # 테스트/자동화/정밀 재실행용 예외
.\Run-SparrowSyntaxFix.ps1 -Solution ...\OSTES.sln -FilesFrom index.csv    # (?뺣?) 寃異??뚯씪留?
.\Run-SparrowSyntaxFix.ps1 -Solution ...\OSTES.sln -ExePath C:\tools\SparrowSyntaxFix.exe  # ?먯뇙留?諛섏엯 exe
```

???뺣낫 ?쒖꽌: `-ExePath` ???ㅽ겕由쏀듃 ??`publish\SparrowSyntaxFix.exe` ??`bin\Release\net8.0\SparrowSyntaxFix.dll`
???놁쑝硫?`dotnet build`(?⑦궎吏 蹂듭썝 媛?ν븷 ??. **?명꽣???녿뒗 PC??`-ExePath`/`publish\`濡?諛섏엯 exe瑜?二쇱꽭??**
`.sln`??二쇰㈃ 洹??대뜑 ?꾨옒 `*.cs`瑜??ш? 泥섎━(?앹꽦/諛깆뾽 ?쒖쇅); ?⑹뼱吏??꾨줈?앺듃??`-FilesFrom index.csv`濡??뺣? ?源?

## Safety / encoding

- Preserves the file's UTF-8 **BOM** presence and its exact **newlines** (Roslyn keeps every existing newline
  in unchanged trivia; the tool inserts none, so even mixed line endings survive verbatim ??no normalization).
- If a file does **not** round-trip cleanly as UTF-8 (e.g. UTF-16, or invalid bytes), it is **skipped** with a
  warning ??never corrupted.
- **Atomic write**: a temp file in the same directory is written, then moved over the target, so a crash
  cannot truncate source. Only files whose tree text actually changed are written.

## Air-gapped usage

net8 + Roslyn (`Microsoft.CodeAnalysis.CSharp` 4.11.0) only ??no other NuGet dependency, no network at
runtime. Restore/build once on a connected machine, then carry the published output into the closed network.
Typical flow against the legacy solution:

```
# 1) see what would change (safe)
SparrowSyntaxFix C:\src\OSTES --dry-run

# 2) apply only the null-cast rule to a checker's file list from the pipeline index
SparrowSyntaxFix --files-from index.csv --root C:\src\OSTES --rules nullcast

# 3) apply both across a subtree
SparrowSyntaxFix C:\src\OSTES\Components
```

## Honest boundary

**A Roslyn edit is not a guaranteed Sparrow clearance.** The Roslyn AST boundary is not identical to
Sparrow's. These rewrites are designed to satisfy the two checkers above, but the real gate is
**re-running Sparrow**: the target checker's findings must drop to zero for the edited files, with zero new
findings introduced. Confirm by re-analysis (pipeline gate G2), then build (G1) and human review (G3).

Note: code inside inactive `#if` branches is parsed as disabled-text trivia and is intentionally **not**
edited (conservative ??it cannot be safely rewritten without knowing the build configuration).

## Tests

`FixtureTests/` is a nested test-only harness that compiles the real rewriter sources and asserts the exact
real-world before?뭓fter cases (positives, negatives, the hard `= new` rule, string-literal safety,
idempotency, CRLF preservation). Run the full offline gate:

```
dotnet run --project FixtureTests/FixtureTests.csproj -c Release
# or the on-disk E2E (BOM/CRLF/atomic-write/generated-skip/dry-run/idempotency):
pwsh tests/sparrow-syntaxfix-fixtures.ps1          # from the repo root
pwsh tests/validate.ps1 -IncludeSyntaxFixE2E
```
