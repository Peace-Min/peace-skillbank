# Peace.Skillbank

개인용 LLM/에이전트 스킬 저장소.

이 저장소는 특정 PC에 바로 설치되는 Codex Skill 묶음이 아니라, 재사용 가능한 분석 절차, 스크립트, 프롬프트 템플릿을 보관하는 스킬뱅크다. Codex에서는 `skills/<skill-name>/SKILL.md`를 Skill로 복사하거나 참조해서 쓰고, 로컬 LLM에서는 스크립트 출력물과 `references/`의 프롬프트를 직접 입력으로 사용한다.

## 구조

```text
skills/
  diagsession-memory-analysis/
    SKILL.md
    scripts/
      extract-gcdump-reports.ps1
    references/
      local-llm-prompt.md
```

## 사용 방식

Codex에서 사용할 때는 해당 스킬 폴더를 Codex skills 경로로 복사하거나, 작업 프롬프트에 스킬 경로를 명시한다.

로컬 LLM에서 사용할 때는 먼저 스크립트로 `LLM_MEMORY_INPUT.txt`를 만든 뒤, `references/local-llm-prompt.md`의 프롬프트와 함께 입력한다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\skills\diagsession-memory-analysis\scripts\extract-gcdump-reports.ps1 -InputPath C:\dumps\before.diagsession,C:\dumps\after.diagsession -ToolPath C:\tools\dotnet-gcdump
```

## 현재 스킬

- `diagsession-memory-analysis`: Visual Studio `.diagsession` 또는 `.gcdump` 스냅샷에서 .NET managed heap 누수 분석용 LLM 입력을 생성하고, before/after 증가 타입을 중심으로 분석하는 절차.

