# frontier-handoff 사용 가이드

폐쇄망에서 약한 로컬 모델(qwen 등)로 작업하다 **막히거나 할루시네이션**이 날 때, 지금 상황을
**프론티어 모델이 바로 이해할 수 있는 self-contained 프롬프트 1개**로 뽑아주는 스킬이다. 매번 같은
템플릿이라 직접 정리할 필요가 없다.

## 언제 발동하나

- "이거 정리해서 **프론티어 모델한테 물어볼 프롬프트** 만들어줘"
- "상위/더 똑똑한 모델한테 넘길 핸드오프 프롬프트"
- "로컬 모델이 자꾸 **없는 API/엉뚱한 답**을 줘 — 상위 모델한테 물어보게 정리해줘"
- "make a prompt I can paste into Claude / GPT"

LightningChart·diagsession 같은 다른 스킬과 달리 **트리거하면 바로 동작**한다 — 코퍼스나 설치가 없다.

## 어떻게 쓰나 (준비 불필요)

그냥 막힌 상황을 말하면 된다. 스킬이:

1. **요청을 핀**한다(프론티어가 *무엇을* 해주길 원하나: 버그 수정 / 설명 / 접근법 제안 / 리뷰).
2. **컨텍스트를 자동 수집**한다 — 작업 중인 파일, 에러 verbatim, 최근 변경(git diff), 환경.
3. **6섹션 템플릿**으로 조립한다: Goal / Problem / What I tried / Relevant code(`file:line`) /
   Environment & constraints / Ask.
4. **`scripts/finalize-handoff.py`로 마무리**한다 — **필수 응답 지시문**을 verbatim으로 끝에
   결정론적으로 붙인다(약한 모델이 돌려도 안 빠짐).
5. **복사용 블록 1개**를 내놓는다 → 인터넷 되는 PC의 프론티어 모델에 붙여넣기.

## 예시 — 막혔을 때 어떻게 요청하고 무엇을 받나

**상황**: 로컬 qwen이 LightningChart에 없는 `AddRainbowAxis()`를 자꾸 추천해서 빌드가 안 된다.

**당신은 이렇게만 말하면 된다:**

> 로컬 모델이 없는 메서드(AddRainbowAxis 같은)를 자꾸 추천해. 상위 모델한테 정리해서 물어볼 프롬프트 만들어줘. 코드는 chart_setup.cs.

**받는 것** — 복사용 블록 1개 (인터넷 PC의 프론티어 모델에 그대로 붙여넣음):

````markdown
## Goal
Build a LightningChart (Arction) WPF XY chart in C# -- add an axis and a point-line series.

## Problem
The local model keeps generating `chart.ViewXY.AddRainbowAxis();`, but it won't compile and isn't in
IntelliSense. I suspect AddRainbowAxis() is a hallucinated API.

## What I already tried
Let the local Qwen model autocomplete it -- it insists on AddRainbowAxis(). Searched IntelliSense; nothing.

## Relevant code
`chart_setup.cs:1`
```csharp
chart.ViewXY.AddRainbowAxis();   // <-- suspected hallucinated API; does not compile
var series = new PointLineSeries(chart.ViewXY, chart.ViewXY.XAxes[0], chart.ViewXY.YAxes[0]);
```

## Environment & constraints
C#, WPF, Arction LightningChart Ultimate. I do NOT know the exact LightningChart version -- flag any
version-dependent API. Offline / air-gapped on a weak local model, no internet, no LightningChart docs.

## Ask
Confirm whether AddRainbowAxis() is a real Arction API; if not, give the corrected code using only real
ViewXY axis/series APIs, as a complete C# block.

## How to answer (the implementer is a weak offline model)
- Open with ONE recommended approach -- decide, don't just list options.
- Then a numbered plan of SMALL steps: exact `file:line`, the complete code to add/replace, a one-line check.
- Be explicit; assume offline (no internet, no new packages), stay on the stated versions.
````

**그다음**: 이 블록을 인터넷 PC의 Claude/GPT에 붙여넣으면 → "AddRainbowAxis는 7.2에 없다, 대신 ~를
써라" + **단계별 수정 계획**을 받는다 → 각 단계를 로컬 qwen에 붙여 그대로 적용. (마지막 지시문 덕에
큰 덩어리 답이 아니라 약한 모델이 따라갈 수 있는 작은 단계로 옴.)

## 결과 프롬프트가 항상 보장하는 것

- **자기완결성** — 프론티어는 당신 파일을 못 여니, 필요한 코드/에러/제약이 프롬프트 안에 다 있다.
- **API 질문이면 라이브러리 정확 버전 요구** — 버전마다 API가 다르므로.
- **방향 가르는 제약 명시** — 예: "렌더 전에 호출됨 → 지연 허용? 동기 필수?".
- **마지막에 응답 지시문(항상)** — "구현 주체가 약한 오프라인 모델이니: ① 추천안 1개로 결정 ②
  잘게 쪼갠 실행 단계(정확한 `file:line` + 완성 코드 + 한 줄 확인) ③ 명시적으로 ④ 오프라인(인터넷·
  패키지 없음, 버전 고정) 고려." → 받은 답을 약한 로컬 모델이 그대로 실행 가능.

이 지시문은 `finalize-handoff.py`가 붙이므로 **약한 모델이 이 스킬을 돌려도 절대 빠지지 않는다.**

> 보안 필터링(시크릿 자동 마스킹)은 없다 — 외부 모델에 보낼 질문에 민감정보를 *애초에 넣지 않는다*는
> 전제. 무엇을 보낼지는 사용자가 입력 단계에서 직접 관리한다.

## 검증됨

`qwen2.5-coder:7b`(Ollama, 배포 타깃 27b보다 더 약함)로 E2E 확인: 약한 모델이 6섹션 템플릿을 채우고,
`finalize-handoff.py`가 응답 지시문을 항상 끝에 붙였다.
