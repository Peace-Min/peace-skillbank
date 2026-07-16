# PRACTICE.LOOP_VARIABLE.NOT_USED_IMPLICIT_TYPING — 루프 변수의 암시적 타입(var) 미사용

- **건수**: (실측 시 변동)  |  **심각도**: 보통  |  **트랙**: A
- **Sparrow 설명**: for문과 foreach의 루프변수의 타입은 암시적 타입을 사용해야 합니다.

> **대부분 Track A(SparrowSyntaxFix/SparrowSyntaxFix) 또는 Track B(SparrowCommentFix/SparrowCommentFix layout)가 자동 처리한다. 이 가이드는 도구가 못 고친 잔여를 LLM이 처리할 때 사용**한다.

## 지켜야 할 규칙 (무엇을 왜 검출)
`for`문의 초기화 변수와 `foreach`문의 루프 변수는 명시 타입 대신 `var`(암시적 타입)로 선언해야 한다. **보안 결함이 아니라 스타일·가독성·표준 준수** 항목이다. `for (int i = 0; ...)`, `foreach (char ch in laugh)`처럼 루프 변수 타입을 반복 도메인에서 유추 가능하므로 명시 표기는 중복이다. Sparrow는 명시 타입 루프 변수를 가진 `for`/`foreach`문을 검출한다.

## 표준 매핑 (교차참조)
- MSDN C#:2015 코딩 규칙 **5.5** — for 및 foreach 루프의 루프 변수 형식을 결정하려면 암시적 형식을 사용합니다.
- C# Coding conventions : 2023 — for 및 foreach 루프의 루프 변수 형식을 결정하려면 암시적 형식을 사용합니다.
- CWE: 스타일 항목이라 직접 매핑 없음(광의 **CWE-1078** 계열).
- 무기체계 보안약점 점검 목록: **187 항목 100% 적용**; 개별 항목번호는 Sparrow 체커↔표준 매핑 추출 후 기입(대기).

## 진성 판별 기준
- `for (T i = ...; ...; ...)`에서 초기화 선언이 명시 타입(`int i` 등).
- `foreach (T x in coll)`에서 루프 변수가 명시 타입(`char ch`, `string s` 등).
- 예: `for (int i = 0; i < 10; i++)`, `foreach (char ch in laugh)` — 모두 진성.

## 이렇게 보여도 넘기지 말 것
스타일 항목이라도 **전건 수정**한다. 명시 타입 루프 변수가 관례처럼 보여도 `var`로 통일한다.
- `foreach`의 루프 변수를 요소 타입보다 **상위 타입으로 명시**해 다운캐스트/업캐스트를 유도하는 경우(예: `foreach (object o in ints)`)는 의미가 있을 수 있다 — `var`로 바꾸면 요소 실제 타입으로 유추되어 동작이 달라질 수 있으므로, 의도를 확인한 뒤 처리하고 필요 시 그 근거를 기록한다.
- 비제네릭 컬렉션(`ArrayList` 등)의 `foreach`에서 명시 타입 캐스트가 필요한 경우 `var`로 바꾸면 `object`가 되므로, 이 경우는 요소 캐스트 의도를 확인해 처리한다.
- 그 외 명시 타입 루프 변수는 표준(`var`)으로 수정한다.

## 수정 패턴 (C# 예시)
```csharp
// Before — 명시 타입 루프 변수
for (int i = 0; i < 10; i++)
{
    laugh += syllable;
}
foreach (char ch in laugh)
{
    Console.Write(ch);
}

// After — 암시적 타입(var)
for (var i = 0; i < 10; i++)
{
    laugh += syllable;
}
foreach (var ch in laugh)
{
    Console.Write(ch);
}
```

## 검증 확인 조건 (G2)
- 빌드 통과(net472 / C# 7.3).
- 재분석 시 해당 라인 PRACTICE.LOOP_VARIABLE.NOT_USED_IMPLICIT_TYPING 소멸.
- 신규 검출 0 — 특히 비제네릭 컬렉션/상위 타입 루프 변수를 `var`로 바꿔 요소 타입·캐스트 의미가 달라지지 않았는지 확인.

## 기본 처리 분류
- [ ] 진성 → 수정 (명시 타입 루프 변수 → var)
- [ ] 보류 → 문맥 확보 후 수정 (요소 캐스트/상위 타입 의도 판단 불가 시 needs_context; 확보 후 반드시 수정)
