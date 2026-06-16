# Peace.Skillbank

## 목적

`Peace.Skillbank`는 개인용 LLM/에이전트 스킬 저장소다. 각 스킬은 특정 작업을 반복 가능하게 만드는 절차, 스크립트, 프롬프트 템플릿을 포함한다.

## 작성 규칙

- 스킬 폴더는 `skills/<skill-name>` 형식을 사용한다.
- 스킬 이름은 lowercase kebab-case를 사용한다.
- 각 스킬은 반드시 `SKILL.md`를 가진다.
- 반복 실행이 필요한 작업은 `scripts/`에 둔다.
- 모델 입력용 프롬프트나 세부 설명은 `references/`에 둔다.
- 생성물, 덤프, 로그, 테스트 산출물은 저장소에 커밋하지 않는다.
- 스킬은 Codex 전용으로만 작성하지 말고, Codex 밖의 LLM도 사용할 수 있게 입력/출력 파일 기준을 명확히 둔다.
- 덤프, 로그, `LLM_MEMORY_INPUT.txt`, `MANIFEST.txt`, `reports/`, `extracted-gcdumps/`는 커밋하지 않는다.
- Claude Code marketplace 호환성을 위해 `.claude-plugin/marketplace.json`과 `.claude-plugin/plugin.json`을 함께 유지한다.

## 검증

PowerShell 스크립트는 최소한 파서 검사를 통과해야 한다.

```powershell
$tokens=$null; $errors=$null
[System.Management.Automation.Language.Parser]::ParseFile("path\to\script.ps1", [ref]$tokens, [ref]$errors)
$errors
```

스킬 수정 후에는 가능하면 Codex skill validator도 실행한다.
Claude Code 호환성은 `claude plugin validate .`로 확인한다.
