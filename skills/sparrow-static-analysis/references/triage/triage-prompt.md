# Track C 트리아지 판정 프롬프트 (triage-prompt)

> 이 파일은 **판단 단계의 프롬프트 템플릿**이다. `Run-Triage.ps1 prepare`가 `{{GUIDE}}`를 해당
> 체커 가이드 전문으로, `{{ITEM}}`을 검출 항목 md 전문으로 치환해 `requests/{ID}_{체커키}.md`를 만든다.
> 그 요청 파일 하나가 곧 **self-contained 프롬프트**다(다른 파일 참조 불필요 → frontier-handoff 그대로 전달 가능).

---

## 지시 (모델/사람에게)

당신은 Sparrow(파수) 정적분석 **Track C** 검출 1건을 판정한다. 아래 **[체커 가이드]** 와 **[검출 항목]** 을
읽고, 이 항목이 **진성(true positive) / 보류** 중 무엇인지 판정하라.

> **이 프로젝트는 전건(全件) 수정 정책** — false-positive 스킵 없음. Sparrow가 잡은 항목은 빼지 말고 전부 처리한다.
> 고칠 수 있으면 `진성`으로 수정하고, 지금 문맥이 부족해 못 고치면 `보류`로 두되 이는 "안 함"이 아니라 **문맥 확보 후 반드시 수정**하는 대기 상태다.

규칙:

1. **판정 근거는 반드시 [체커 가이드]의 `## 진성 판별 기준` 또는 `## 이렇게 보여도 넘기지 말 것`에서 인용**하라.
   가이드에 없는 일반론으로 판정하지 마라.
2. 항목의 **`## 소스 코드` 를 실제로 보고** 판단하라. 코드에 근거가 보이지 않으면 진성이라고 단정하지 마라.
3. **확신이 없으면 지어내지 마라.** 소스가 잘린 경우, null/자원 근원이 이 스니펫 밖(외부 경로)이라
   판단 불가한 경우 → `verdict = 보류`, `needs_context = true`, `missing_context`에 필요한 파일/심볼/코드 범위를 적어라.
   자료는 충분하지만 로컬 모델 판단이 어려운 경우에만 `needs_frontier = true`로 둔다.
4. **진성**이면 가이드의 `## 수정 패턴 (C# 예시)`를 따라 **.NET Framework 4.7.2 / C# 7.3** 문법으로
   `before`/`after` 수정을 작성하라.
   - `using (...) { }` **블록** 문법만(using 선언 금지), switch 식·nullable 참조형 금지.
   - `after`는 검출 소멸이 목표이되, 조용한 무시(빈 catch, 무의미한 널병합)로 결함을 은폐하지 마라.
5. **보류**면 `hold_reason`에 왜 지금 못 고치는지를 적고, 소스/예외목록 등 문맥이 부족하면
   `needs_context = true` + `missing_context`(필요한 파일/심볼/코드 범위)를 채워라. `fix`는 비운다.
   보류는 스킵이 아니라 **문맥 확보 후 반드시 수정**하는 대기 상태다.
6. `cwe`는 가이드 `## 표준 매핑`의 CWE를 그대로 기입(예: `CWE-476`). `weapon_item`은 아직
   187 매핑 추출 전이므로 `미매핑(187 추출 후 기입)`으로 둔다.
7. **출력은 아래 JSON 스키마 객체 하나만.** 다른 텍스트·마크다운·설명을 앞뒤에 붙이지 마라.

### 출력 JSON 스키마 (키를 정확히 사용)

```json
{
  "id": "string", "checker": "string", "file": "string", "line": "string",
  "verdict": "진성|보류",
  "rationale": "가이드 기준을 인용한 판정 근거",
  "fix": { "lines": "string", "before": "C# 코드", "after": "C# 코드" },
  "hold_reason": "보류일 때만",
  "needs_context": false,
  "missing_context": ["필요한 추가 문맥"],
  "needs_frontier": false,
  "cwe": "CWE-476", "weapon_item": "미매핑(187 추출 후 기입)"
}
```

채움 규칙:
- **진성** → `fix.lines`/`fix.before`/`fix.after` 채우고, `hold_reason`은 `""`.
- **보류** → `hold_reason` 채우고, 자료 부족이면 `needs_context=true` 및 `missing_context`를 채운다.
  자료는 충분하지만 상위 모델 판단이 필요하면 `needs_frontier=true`, `fix`는 `""`.
  (보류는 스킵이 아니라 문맥 확보 후 반드시 수정하는 대기 상태다.)

`id`/`checker`/`file`/`line`은 [검출 항목]의 표(`| 필드 | 값 |`)와 H1(`# 체커키 @ 파일:라인`)에서 그대로 옮긴다.

---

## [체커 가이드]

{{GUIDE}}

---

## [검출 항목]

{{ITEM}}
