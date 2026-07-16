# Sparrow Static Analysis 사용/확장 가이드

`sparrow-static-analysis`는 Sparrow 정적분석 결과를 줄이기 위한 폐쇄망용 헬퍼다. 일반 사용자는 GUI만 열고, 개발자는 `tools/_internal`과 `references`를 수정해 체커와 룰셋을 확장한다.

## 빠른 실행

Visual Studio에서 아래 솔루션을 연다.

```text
skills/sparrow-static-analysis/SparrowRunner.Gui/SparrowRunner.Gui.sln
```

솔루션 폴더 안에는 `.sln` 하나만 두었다. 사용자가 처음 들어왔을 때 “이걸 열면 된다”가 보이도록 하기 위한 진입점이다. 실제 소스와 내부 엔진은 `tools/` 아래에 있다.

CLI로 바로 실행해야 하면 다음 파일을 사용한다.

```text
skills/sparrow-static-analysis/tools/Run-SparrowRunnerGui.cmd
```

## Track 구성

| Track | 목적 | 주요 위치 |
| --- | --- | --- |
| Track A | C# 코드 규칙 자동수정. var, 괄호, object initializer, 배열 선언 등 Roslyn 기반 변환. | `tools/_internal/SparrowSyntaxFix` |
| Track B | 주석/레이아웃 자동수정. 주석 공백/마침표/평탄화, member blank, one statement 등. | `tools/_internal/SparrowCommentFix` |
| Track C | 보안/품질 잔여 항목을 LLM 작업 요청으로 패키징. 예외, null, resource leak, TOCTOU, encapsulation 등. | `tools/_internal/SparrowXlsExport.Core`, `references/checkers`, `references/triage` |

GUI 소스는 `tools/SparrowRunner.Gui`에 있다. GUI는 사용자가 규칙을 고르는 진입점이고, 실제 수정 로직은 Track A/B/C 내부 엔진에 둔다.

## 디렉터리 구조

```text
skills/sparrow-static-analysis/
  SparrowRunner.Gui/
    SparrowRunner.Gui.sln        # 사용자/Visual Studio 진입점
  tools/
    SparrowRunner.Gui/           # 실제 WPF GUI 소스
    _internal/
      SparrowSyntaxFix/          # Track A 자동수정 엔진
      SparrowCommentFix/         # Track B 자동수정 엔진
      SparrowXlsExport/          # Track C XLS CLI/테스트용
      SparrowXlsExport.Core/     # Track C 파싱/request 생성 코어
  references/
    checkers/                    # 체커별 LLM 가이드
    sparrow-official-rules/      # 공식 룰셋/근거 정리
    triage/                      # Track C 요청 템플릿/검증
    real-fix-patterns/           # 폐쇄망 실제 수정 패턴을 익명화해 정리
```

## 체커 가이드 추가/수정

LLM이 체커를 보고 판단해야 하는 항목은 `references/checkers/<CHECKER_KEY>.md`에 작성한다.

권장 내용:

- Sparrow 체커명과 설명.
- 고쳐야 하는 이유. “코드상 문제없으면 스킵”이 아니라 Sparrow 검출을 줄이는 것이 목표임을 명시.
- 수정 전/후 예시.
- C# 7.3 / .NET Framework 4.7.2 호환 제약.
- 자동화 가능 여부: Track A, Track B, Track C, human-review.
- 빌드나 의미 변경 위험이 있는 케이스.

새 체커가 Track C 요청에 들어가야 하면 `references/checkers/<CHECKER_KEY>.md`만 추가하는 것이 1차다. GUI의 Track C는 XLS의 체커 키와 이 파일명을 매칭해 `requests/`에 가이드를 병합한다.

## 공식 룰셋 보완

Sparrow 공식 규칙, 장표, XLS에서 확인한 룰 근거는 `references/sparrow-official-rules/`에 정리한다.

보완 기준:

- 원문 체커명과 한국어 설명을 보존한다.
- 실제 XLS 대표 위치나 예시가 있으면 함께 적는다.
- Track A/B/C 중 어느 경로에서 처리할지 표시한다.
- 자동화하지 않는다면 “왜 보류인지”와 LLM/사람 검토 기준을 남긴다.

## 실제 수정 패턴 추가

폐쇄망 코드의 실제 커밋을 학습 자료로 쓰고 싶지만 원본 코드를 옮길 수 없을 때는 `references/real-fix-patterns/`를 사용한다.

절차:

1. 체커별 커밋 diff에서 최소 Before/After 형태만 추출한다.
2. 파일명, 클래스명, 메서드명, 문자열, 도메인 용어를 익명화한다.
3. 전체 함수나 업무 로직을 복사하지 않는다.
4. `references/real-fix-patterns/TEMPLATE.md` 형식으로 저장한다.
5. 해당 패턴이 Track A/B 자동화 후보인지, Track C LLM 지침인지, human-review인지 분류한다.

## Track A 룰 추가

대상: 코드 규칙을 Roslyn으로 결정론 수정할 수 있는 경우.

수정 위치:

- 엔진: `tools/_internal/SparrowSyntaxFix`
- runner 옵션: `tools/_internal/SparrowSyntaxFix/Run-SparrowSyntaxFix.ps1`
- GUI 체크박스/설명: `tools/SparrowRunner.Gui`
- 정책 문서: `references/track-a-roslyn-policy.md`
- 필요 시 체커 가이드: `references/checkers/<CHECKER_KEY>.md`

추가 후 검증:

```powershell
dotnet build .\skills\sparrow-static-analysis\tools\_internal\SparrowSyntaxFix\SparrowSyntaxFix.csproj -c Release
dotnet build .\skills\sparrow-static-analysis\SparrowRunner.Gui\SparrowRunner.Gui.sln -c Release
```

가능하면 fixture를 추가해 “검출 패턴처럼 작성한 코드가 실제로 바뀌는지”와 “이미 정상인 코드는 깨지지 않는지”를 같이 확인한다.

## Track B 룰 추가

대상: 주석, 빈 줄, 한 줄 한 문장, LINQ 정렬 등 형식/레이아웃 규칙.

수정 위치:

- 엔진: `tools/_internal/SparrowCommentFix`
- runner 옵션: `tools/_internal/SparrowCommentFix/Run-SparrowCommentFix.ps1`
- GUI 체크박스/설명: `tools/SparrowRunner.Gui`
- 체커 가이드: `references/checkers/<CHECKER_KEY>.md`

주의:

- `dotnet format`처럼 광범위한 포맷터를 전체 적용하지 않는다.
- 기존에 정상인 들여쓰기나 블록 구조를 무너뜨리는 정규식식 전역 수정은 금지한다.
- Roslyn trivia/구문 기반으로 범위를 좁히고 fixture로 양성/음성 케이스를 검증한다.

## Track C 체커 추가

대상: 자동수정이 위험하거나 문맥 판단이 필요한 보안/품질 항목.

수정 위치:

- 체커 가이드: `references/checkers/<CHECKER_KEY>.md`
- 요청 템플릿: `references/triage/triage-prompt.md`
- 작업 계약: `references/triage/triage-contract.md`
- 필요 시 코어 파서/패키저: `tools/_internal/SparrowXlsExport.Core`

검증:

```powershell
powershell -ExecutionPolicy Bypass -File .\skills\sparrow-static-analysis\references\triage\fixtures\run-validate.ps1
powershell -ExecutionPolicy Bypass -File .\skills\sparrow-static-analysis\references\triage\e2e-lab\run-e2e.ps1
```

GUI Track C의 최종 출력은 LLM에게 넘길 `requests/` 폴더만이다. `items`, `index.csv`, `checkers.md`, `worklist.csv`, `unresolved.csv`는 내부/검증용 산출물이며 일반 LLM 입력으로 넘기지 않는다.

## 변경 후 기본 검증

GUI/엔진 변경 후 최소 검증:

```powershell
dotnet build .\skills\sparrow-static-analysis\SparrowRunner.Gui\SparrowRunner.Gui.sln -c Release
dotnet build .\skills\sparrow-static-analysis\tools\_internal\SparrowSyntaxFix\SparrowSyntaxFix.csproj -c Release
dotnet build .\skills\sparrow-static-analysis\tools\_internal\SparrowCommentFix\SparrowCommentFix.csproj -c Release
dotnet build .\skills\sparrow-static-analysis\tools\_internal\SparrowXlsExport\SparrowXlsExport.csproj -c Release
```

PowerShell runner를 수정했다면 파서 검사를 수행한다.

```powershell
$files = @(
  ".\skills\sparrow-static-analysis\tools\Run-SparrowAll.ps1",
  ".\skills\sparrow-static-analysis\tools\_internal\SparrowSyntaxFix\Run-SparrowSyntaxFix.ps1",
  ".\skills\sparrow-static-analysis\tools\_internal\SparrowCommentFix\Run-SparrowCommentFix.ps1"
)
foreach ($f in $files) {
  $tokens=$null; $errors=$null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$tokens, [ref]$errors) | Out-Null
  $errors
}
```

## 운영 원칙

- 일반 사용자는 `SparrowRunner.Gui.sln`만 열면 되게 유지한다.
- 실제 룰 구현은 GUI에 직접 넣지 말고 Track A/B/C 엔진에 넣는다.
- GUI는 내부 엔진의 규칙을 선택하고 설명하는 얇은 진입점이다.
- 폐쇄망 실제 코드는 커밋하지 않는다. 필요한 경우 익명화된 패턴만 `references/real-fix-patterns/`에 남긴다.
- Sparrow가 검출한 항목은 기본적으로 수정 대상이다. LLM이 임의로 “문제없으니 스킵”하지 않도록 체커 가이드에 수정 기준을 명확히 쓴다.
