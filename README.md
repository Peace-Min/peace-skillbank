# Peace.Skillbank

개인용 LLM/에이전트 스킬 저장소.

A personal skill bank for reusable LLM/Codex workflows, scripts, and model-agnostic prompts.

이 저장소는 특정 PC에 바로 설치되는 Codex Skill 묶음이 아니라, 재사용 가능한 분석 절차, 스크립트, 프롬프트 템플릿을 보관하는 스킬뱅크다. Codex에서는 `skills/<skill-name>/SKILL.md`를 Skill로 복사하거나 참조해서 쓰고, Codex 밖의 LLM에서는 스크립트 출력물과 `references/`의 프롬프트를 직접 입력으로 사용한다.

## 목표

- 반복 가능한 작업 절차를 `SKILL.md`로 정리한다.
- 실수하기 쉬운 변환/검증 작업은 `scripts/`에 둔다.
- Codex에만 의존하지 않고 다른 LLM에도 넘길 수 있는 입력 파일과 프롬프트를 함께 둔다.
- 덤프, 로그, 분석 결과처럼 민감할 수 있는 산출물은 저장소에 커밋하지 않는다.

## 구조

```text
skills/
  diagsession-memory-analysis/
    SKILL.md
    agents/
      openai.yaml
    scripts/
      extract-gcdump-reports.ps1
    references/
      model-agnostic-prompt.md
```

## Codex에서 사용

이 저장소는 스킬뱅크 구조를 사용한다. clone만으로 Codex가 자동 발견하는 repo-scoped skill 위치는 아니다.

사용 방법은 둘 중 하나를 선택한다.

- 필요한 스킬 폴더를 Codex skills 경로로 복사한다.
- 작업 프롬프트에 `skills/<skill-name>` 경로를 명시한다.

Codex repo-scoped 자동 발견이 필요하면 해당 스킬 폴더를 대상 프로젝트의 `.agents/skills/` 아래에 복사한다.

예:

```powershell
$skillName = "diagsession-memory-analysis"
$source = "C:\path\to\peace-skillbank\skills\$skillName"
$target = Join-Path $env:USERPROFILE ".codex\skills\$skillName"
Copy-Item -Recurse -Force -LiteralPath $source -Destination $target
```

## Claude Code에서 plugin marketplace로 사용

이 저장소는 Claude Code marketplace 파일을 포함한다. GitHub에 push한 뒤 Claude Code에서 저장소 주소를 marketplace로 추가하면 plugin을 설치할 수 있다.

사람용 전체 사용법은 [diagsession-memory-analysis 사용 가이드](docs/diagsession-memory-analysis-usage.md)를 먼저 본다.

```text
/plugin marketplace add Peace-Min/peace-skillbank
/plugin install peace-skillbank@peace-skillbank
```

이미 설치한 경우 marketplace를 갱신한 뒤 plugin을 업데이트한다.

```text
/plugin marketplace update peace-skillbank
/plugin update peace-skillbank@peace-skillbank
```

설치 후 짧은 command alias를 우선 사용한다.

```text
/diagsession-memory-analysis C:\dumps\leak-test.diagsession

액션은 장비 목록 새로고침 30회 반복.
시작점은 DeviceRefreshService.RefreshAsync.
```

Claude Code가 plugin skill namespace만 노출하는 환경에서는 namespaced skill 호출도 사용할 수 있다.

```text
/peace-skillbank:diagsession-memory-analysis
```

두 방식 모두 같은 분석 스킬을 사용한다. 일반적인 작업 지시는 짧게 작성한다.

```text
/diagsession-memory-analysis C:\dumps\leak-test.diagsession

액션은 장비 목록 새로고침 30회 반복.
시작점은 DeviceRefreshService.RefreshAsync.
```

로컬에서 테스트할 때는 저장소 루트에서 다음 명령을 사용한다.

```powershell
claude plugin validate .
claude --plugin-dir .
```

## Codex 밖의 LLM에서 사용

먼저 스크립트로 `LLM_MEMORY_INPUT.txt`를 만든 뒤, `references/model-agnostic-prompt.md`의 프롬프트와 함께 입력한다.

### 요구사항

- Windows PowerShell 5.1 이상 또는 PowerShell 7 이상
- .NET SDK 또는 runtime
- `dotnet-gcdump`

`dotnet-gcdump`는 PATH에 있거나, `C:\tools\dotnet-gcdump\dotnet-gcdump.exe`에 있거나, `-ToolPath`로 지정할 수 있어야 한다.

일반 온라인 환경에서는 다음 방식으로 설치할 수 있다.

```powershell
dotnet tool install --global dotnet-gcdump
```

오프라인 환경에서는 별도 오프라인 번들로 설치한 뒤 `-ToolPath`를 지정한다.

```powershell
$skillDir = "C:\path\to\peace-skillbank\skills\diagsession-memory-analysis"
powershell -NoProfile -ExecutionPolicy Bypass -File "$skillDir\scripts\extract-gcdump-reports.ps1" -InputPath C:\dumps\leak-test.diagsession
```

출력물:

```text
LLM_MEMORY_INPUT.txt
MANIFEST.txt
reports/
```

`LLM_MEMORY_INPUT.txt`는 기본적으로 전체 로컬 경로를 제거하고 파일명만 포함한다. 전체 경로는 `MANIFEST.txt`에만 기록된다.

외부 LLM에 넘기기 전에는 `LLM_MEMORY_INPUT.txt`를 한번 검토한다. 타입명, 네임스페이스, 프로젝트명 자체가 민감 정보일 수 있다.

`MANIFEST.txt`에서 입력 순서, `.diagsession` 내부 entry, 생성된 report 경로를 확인한다. 하나의 `.diagsession` 안에 여러 `.gcdump`가 있으면 archive entry 순서가 사용되므로 before/after 의미는 사용자가 직접 확인해야 한다.

이 스킬은 분석 전용이다. 실제 코드 수정, 패치, 커밋은 분석 결과의 handoff summary를 바탕으로 별도 작업에서 진행한다.

## 오픈소스 스킬 레포 관리 방식

이 저장소는 "각자 알아서 쓰라"는 형태를 피하기 위해 다음을 함께 유지한다.

- marketplace/plugin manifest: Claude Code에서 repo 주소로 설치 가능하게 한다.
- skill metadata: Codex와 Claude가 스킬을 발견하고 설명할 수 있게 한다.
- command alias: Claude Code에서 짧은 `/diagsession-memory-analysis` 진입점을 제공한다.
- README quick start: 설치, 호출, 출력물, 프라이버시 주의사항을 문서화한다.
- validation script: publish 전에 구조와 manifest를 검증한다.

## 검증

스킬을 수정한 뒤 최소 검증을 수행한다.

```powershell
$tokens=$null; $errors=$null
[System.Management.Automation.Language.Parser]::ParseFile(
  "skills\diagsession-memory-analysis\scripts\extract-gcdump-reports.ps1",
  [ref]$tokens,
  [ref]$errors
)
$errors
```

Codex skill validator가 있는 환경에서는 `skills/diagsession-memory-analysis`를 대상으로 검증한다.

저장소 기본 검증:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\validate.ps1
```

## 현재 스킬

- `diagsession-memory-analysis`: Visual Studio `.diagsession` 또는 `.gcdump` 스냅샷에서 .NET managed heap 누수 분석용 LLM 입력을 생성하고, before/after 증가 타입을 중심으로 분석하는 절차.
