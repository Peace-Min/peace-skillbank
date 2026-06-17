# Skill Production Playbook

이 문서는 이 레포에서 스킬을 **실제로 어떻게 만들고 검증하는지**를, `diagsession-memory-analysis`
스킬의 실제 제작 과정을 사례로 보여준다.

새 스킬을 만들 때: **이 문서를 읽고 → 이 구조를 참고해 *작업계획*부터 세운다.**
체크리스트를 외워 따르는 게 아니라, 잘 만든 사례 하나를 보고 *적응*한다. 각 단계의 깊이는
**스킬의 취약도/객관성에 비례**시킨다 — 과한 ceremony는 그 자체로 병목이다.

## 제작 구조 (전이 가능한 뼈대)

### Phase 0 — 이해
무엇을 만들지, 현재 상태가 어떤지, *진짜 목표*가 뭔지부터 파악한다.
- 실제로: 레포 구조·기존 스킬·사용자가 겪은 실패(다른 PC에서 커맨드 못 찾음)를 먼저 봤다.
- 왜: 증상이 아니라 원인을 본다. 엉뚱한 문제를 비싸게 풀지 않기 위해.

### Phase 1 — 방향 결정 (정직한 트레이드오프)
대안을 비교하고, 한계를 *정직하게* 명시한 채 고른다.
- 실제로: "PowerShell 유지 vs Python 포팅"을 두고, **폐쇄망 Windows엔 Python이 없을 때가
  많다**는 제약 때문에 PowerShell 유지를 택했다. "이식 가능"이라 과장하지 않고 "Windows
  .NET 전용"이라 정직하게 적었다.
- 왜: 모든 선택엔 비용이 있다. 숨기지 말고 문서화한다. 목표(공개/폐쇄망 등)에 따라 답이 갈린다.

### Phase 2 — 증분 빌드
- SKILL.md는 **lean**, 결정적·반복 작업은 `scripts/`, 상세는 `references/`.
- **Solve, don't punt**: 도구 미설치·권한·미지원 입력을 *스크립트가 직접* 처리하고 구체적으로
  보고한다. 모델에게 떠넘기거나 지어내지 않는다.
- **결론을 파일로 저장**(채팅 텍스트로만 두지 않음) → 다음 세션이 이어받게.
- 호출은 네이티브 셸에서 직접 — **셸 중첩 금지**(Bash→cmd→PS는 따옴표·한글 경로를 깨뜨림).

### Phase 3 — 검증 루프 (핵심)
"되겠지"는 신뢰가 아니다. **실제로 돌려본다.**
- **진짜 fixture**를 만든다(합성이라도 실제 도구로 생성). 예: 작은 .NET 앱으로 진짜 before/after `.gcdump`.
- **양성 경로**(정상 동작)와 **음성 경로**(미지원 입력을 *우아하게 거절*) **둘 다** 테스트.
  음성 경로가 더 중요할 때가 많다 — 환각 방지.
- **구조 검증**(validate)으로 규격을, **contract 검증**으로 출력 형식을 자동 확인.
- 외부 프로세스는 두 스트림을 **동시에 읽거나 파일로 리다이렉트** — 순차 `ReadToEnd`는
  **deadlock**(실제로 이 레포 하네스가 멈췄고, 고쳤다).

### Phase 4 — A/B 게이트로 개선
추론/설명문을 손볼 땐 그냥 믿지 말고:
- baseline 스냅샷 → 후보 적용 → **같은 fixture로 둘 다 분석** → **blind judge**(어느 쪽인지
  모르게 비교) → **회귀 없을 때만 채택, 아니면 자동 롤백**.
- 왜: 작은 개선이 몰래 품질을 떨어뜨리는 걸 자동 차단.

### Phase 5 — 배포
- `.claude-plugin/marketplace.json` + `plugin.json` **버전 동기화**.
- `commands/`에 진입점. plugin 설치 시 커맨드는 **namespaced**(`/plugin:skill`)로 호출되고
  `/reload-plugins`가 필요함을 문서화.

## 전이 가능 vs 이 스킬 고유

| 전이 가능 (모든 스킬에) | diagsession 고유 (복붙 금지) |
|---|---|
| 6단계 구조 · solve-don't-punt · lean SKILL.md | PowerShell / .NET / gcdump |
| 진짜 fixture · 양성+음성 검증 · A/B 게이트 | leakapp 더미 · `.gcdump` 추출 |
| 프라이버시(산출물 미커밋) · 정직한 한계 명시 | 8-heading 리포트 contract |

→ **구조와 원리는 빌려쓰고, 도구·형식은 새 스킬에 맞게 갈아끼운다.**

## 취약도에 비례 (과잉 제약 방지)

| 스킬 유형 | 검증 깊이 |
|---|---|
| 파일 변환·추출·코드생성 (객관적·취약) | 전체: fixture + 양성/음성 + contract + A/B |
| 조회·요약 (반결정적) | 가볍게: 대표 입력 1~2개 + 구조 검증 |
| 글쓰기·디자인 (주관적) | eval 강제하지 않음 — 사람 리뷰로 |

## 새 스킬을 만들 때 (실전)

매번 긴 작업지시를 적지 않는다. 레포를 작업 폴더로 연 세션에서 이렇게:

```text
docs/skill-authoring-guide.md 와 AGENTS.md 참고해서,
<목적>을 하는 스킬의 작업계획부터 세워줘.
```

→ 에이전트가 이 구조를 흡수해 **새 스킬에 맞는 plan 제시** → 승인 → 빌드.
(Anthropic `skill-creator`가 draft→test→iterate를 돌리고, 이 레포 규약은 AGENTS.md로 자동 주입된다.)

## 발행 전 체크 (간단 게이트)

```text
[ ] SKILL.md frontmatter 유효 (name=kebab, description=트리거 풍부·3인칭)
[ ] SKILL.md lean; 상세는 references/; 중복 없음
[ ] 도구 가정 X; 실패는 구체적 메시지 (solve-don't-punt)
[ ] 산출물·덤프·로그 .gitignore; 외부 공유물 경로 redact
[ ] (취약/객관 출력이면) 실제 fixture로 양성+음성 검증 통과
[ ] 결론을 파일로 저장
[ ] 개선은 A/B 게이트로
[ ] marketplace/plugin 버전 동기화; namespaced 호출; validate 통과
```

## 참고
- 실제 검증 도구: `tests/build-fixture.ps1`, `tests/run-skill-eval-loop.ps1`, `tests/validate.ps1`
- Anthropic 공식: `skill-creator` 스킬 + [Skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)
