# Sparrow Static Analysis 사용/확장 가이드

`sparrow-static-analysis`는 Sparrow 정적분석 결과 조치를 반복 가능하게 만들기 위한 폐쇄망용 헬퍼다. 정형화된 코딩/주석 위반 패턴은 Roslyn 기반 CLI로 자동 조치하고, 보안/품질 판단 항목과 예외 케이스는 Markdown으로 변환해 LLM 또는 개발자가 체커별로 작업한다.

## 빠른 실행

Visual Studio 사용자는 다음 솔루션을 연다.

```text
skills/sparrow-static-analysis/SparrowRunner.Gui/SparrowRunner.Gui.sln
```

명령줄에서 GUI를 바로 실행하려면 다음 파일을 사용한다.

```text
skills/sparrow-static-analysis/tools/Run-SparrowRunnerGui.cmd
```

## 구성

| 구분 | 목적 | 위치 |
| --- | --- | --- |
| 코딩 규칙 자동 조치 | `var`, 괄호, object initializer, 배열 선언 등 사전 정의된 C# 위반 패턴을 Roslyn 기반으로 수정 | `tools/_internal/SparrowSyntaxFix` |
| 주석/레이아웃 자동 조치 | 주석 공백, 마침표, trailing comment, member blank, one statement 등 사전 정의된 주석/레이아웃 패턴을 수정 | `tools/_internal/SparrowCommentFix` |
| 판단 필요 항목 패키징 | 예외 처리, null, resource leak, TOCTOU, encapsulation 등 보안/품질 항목을 LLM 작업 요청으로 변환 | `tools/_internal/SparrowXlsExport.Core`, `references/checkers`, `references/triage` |

## 디렉터리 구조

```text
skills/sparrow-static-analysis/
  SparrowRunner.Gui/
    SparrowRunner.Gui.sln        # 사용자/Visual Studio 진입점
  tools/
    Run-SparrowRunnerGui.cmd     # GUI 실행
    Run-SparrowAll.ps1           # 코딩/주석 자동 조치 일괄 실행
    SparrowRunner.Gui/           # WPF GUI 소스
    _internal/
      SparrowSyntaxFix/          # 코딩 규칙 자동 조치 엔진
      SparrowCommentFix/         # 주석/레이아웃 자동 조치 엔진
      SparrowXlsExport/          # Sparrow XLS 파서 CLI
      SparrowXlsExport.Core/     # Markdown request 생성 코어
  references/
    checkers/                    # 체커별 LLM/개발자 조치 가이드
    sparrow-official-rules/      # 공식 규칙 근거
    triage/                      # Markdown 요청 템플릿/검증
    real-fix-patterns/           # 폐쇄망 수정 사례의 익명화 패턴
```

## 확장 기준

- 자동 조치는 반드시 반복 발생하는 정형 패턴에 한정한다.
- Roslyn 구문 트리 또는 trivia 범위 안에서 수정하고, 문자열 리터럴 같은 비대상 영역은 건드리지 않는다.
- 판단이 필요한 보안/품질 항목은 자동수정하지 않고 Markdown 요청으로 만든다.
- 새 체커를 추가할 때는 `references/checkers/<CHECKER_KEY>.md`에 조치 기준, 예시, C# 7.3/.NET Framework 4.7.2 제약을 적는다.
- Track C는 전용 체커 가이드가 없는 항목도 버리지 않는다. XLS의 체커명/체커 설명/소스 코드/파일/라인을 근거로 fallback request를 생성한다. 반복 검출되는 fallback 체커는 전용 md로 승격한다.
- 폐쇄망 실제 코드를 학습 자료로 남길 때는 `references/real-fix-patterns/`에 최소 before/after 형태만 익명화해서 기록한다.

## Track C 검수 기록

Track C의 P1/P2 보완 계획은 `skills/sparrow-static-analysis/references/triage/track-c-review-plan-20260719.md`에 기록한다.

핵심 결정:

- Track C 실행 시점의 Track A/B 잔여 체커는 자동화가 놓친 엣지케이스이므로 LLM/사람에게 무조건 전달한다.
- GUI의 Track A/B 포함 옵션은 제거 대상이다.
- Track C GUI는 최종 `requests/` 안에서 unresolved 항목까지 확인 가능해야 한다.

## 기본 검증

```powershell
dotnet build .\skills\sparrow-static-analysis\SparrowRunner.Gui\SparrowRunner.Gui.sln -c Release
dotnet build .\skills\sparrow-static-analysis\tools\_internal\SparrowSyntaxFix\SparrowSyntaxFix.csproj -c Release
dotnet build .\skills\sparrow-static-analysis\tools\_internal\SparrowCommentFix\SparrowCommentFix.csproj -c Release
dotnet build .\skills\sparrow-static-analysis\tools\_internal\SparrowXlsExport\SparrowXlsExport.csproj -c Release
```

PowerShell runner를 수정한 경우 파서 검사를 수행한다.

```powershell
$files = @(
  ".\skills\sparrow-static-analysis\tools\Run-SparrowAll.ps1",
  ".\skills\sparrow-static-analysis\tools\_internal\SparrowSyntaxFix\Run-SparrowSyntaxFix.ps1",
  ".\skills\sparrow-static-analysis\tools\_internal\SparrowCommentFix\Run-SparrowCommentFix.ps1",
  ".\skills\sparrow-static-analysis\references\triage\Run-Triage.ps1"
)
foreach ($f in $files) {
  $tokens=$null; $errors=$null
  [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f), [ref]$tokens, [ref]$errors) | Out-Null
  $errors
}
```

Track C Markdown 요청 흐름을 바꾼 경우:

```powershell
powershell -ExecutionPolicy Bypass -File .\skills\sparrow-static-analysis\references\triage\fixtures\run-validate.ps1
powershell -ExecutionPolicy Bypass -File .\skills\sparrow-static-analysis\references\triage\e2e-lab\run-e2e.ps1
```
