# Peace.Skillbank

## 목적

`Peace.Skillbank`는 개인용 LLM/에이전트 스킬 저장소다. 각 스킬은 특정 작업을 반복 가능하게 만드는 절차, 스크립트, 프롬프트 템플릿을 포함한다.

## 새 스킬을 만들 때

**먼저 [Skill Production Playbook](docs/skill-authoring-guide.md)를 읽고, 그 구조를 참고해 *작업계획*부터 세운다.** 체크리스트를 외우는 게 아니라 잘 된 실제 사례(diagsession)를 보고 적응하며, 검증의 깊이는 스킬의 취약도/객관성에 비례시킨다. 보통은 이 레포를 작업 폴더로 연 뒤 Anthropic `skill-creator`에게 "플레이북·AGENTS.md 참고해서 `<목적>` 스킬 작업계획부터 세워줘"라고 맡기면 된다.

항상 지키는 비협상 규약:

- `skills/<kebab-name>/SKILL.md` 필수 · 결정적·반복 작업은 `scripts/` · 상세 문서·모델 프롬프트는 `references/`. SKILL.md는 lean하게.
- 생성물·덤프·로그·모델 I/O(`LLM_MEMORY_INPUT.txt`, `MANIFEST.txt`, `reports/`, `ANALYSIS.md`, `extracted-gcdumps/` 등)는 커밋 금지(`.gitignore`). 외부 공유물은 전체 경로를 redact한다.
- 도구 설치를 가정하지 않는다. 미설치·권한·미지원 입력은 스크립트가 직접 처리하고 **구체적으로 보고**한다(지어내지 않음).
- **검증 없이 발행하지 않는다.** 취약하거나 객관적 출력인 스킬은 실제 fixture로 **양성+음성 경로**를 검증한다.
- 스킬을 특정 도구 전용으로 가두지 않는다(Codex 밖 LLM도 입출력 파일 기준이 명확하게). 호출은 네이티브 셸에서 직접 — 셸 중첩 금지.
- `.claude-plugin/marketplace.json`·`plugin.json` 버전을 동기화하고, plugin 커맨드는 namespaced(`/plugin:skill`)로 호출됨을 문서화한다.

## 검증

PowerShell 스크립트는 최소한 파서 검사를 통과해야 한다.

```powershell
$tokens=$null; $errors=$null
[System.Management.Automation.Language.Parser]::ParseFile("path\to\script.ps1", [ref]$tokens, [ref]$errors)
$errors
```

스킬 수정 후에는 가능하면 Codex skill validator도 실행한다.
Claude Code 호환성은 `claude plugin validate .`로 확인한다.
