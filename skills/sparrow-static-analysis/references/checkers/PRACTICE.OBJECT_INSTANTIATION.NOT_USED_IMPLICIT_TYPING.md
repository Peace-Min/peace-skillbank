# PRACTICE.OBJECT_INSTANTIATION.NOT_USED_IMPLICIT_TYPING — 객체 인스턴스화 시 암시적 타입(var) 미사용

- **건수**: (실측 시 변동)  |  **심각도**: 낮음  |  **트랙**: A
- **Sparrow 설명**: 객체를 인스턴스화할 때, 간략한 형태인 암시적 타입을 사용해야 한다.

> **대부분 Track A(SparrowSyntaxFix/SparrowSyntaxFix) 또는 Track B(SparrowCommentFix/SparrowCommentFix layout)가 자동 처리한다. 이 가이드는 도구가 못 고친 잔여를 LLM이 처리할 때 사용**한다.

## 지켜야 할 규칙 (무엇을 왜 검출)
`new T()`로 객체를 인스턴스화하는 지역 변수 선언은 좌변에 타입을 반복하지 말고 `var`(암시적 타입)로 간결하게 작성해야 한다. **보안 결함이 아니라 스타일·가독성·표준 준수** 항목이다. `TestClass tc = new TestClass();`처럼 좌우에 타입 이름이 두 번 나오는 형태는 중복이며, MSDN C# 코딩 규칙은 이런 경우 `var`를 권장한다. Sparrow는 우변이 `new 클래스이름(...)`인데 좌변이 명시 타입인 지역 변수 선언을 검출한다.

## 표준 매핑 (교차참조)
- MSDN C#:2015 코딩 규칙 **10.1** — 암시적 형식이 포함된 간결한 형태의 개체 인스턴스화를 사용합니다.
- C# Coding conventions : 2023 — 암시적 형식이 포함된 간결한 형태의 개체 인스턴스화를 사용합니다.
- CWE: 스타일 항목이라 직접 매핑 없음(광의 **CWE-1078** 계열).
- 무기체계 보안약점 점검 목록: **187 항목 100% 적용**; 개별 항목번호는 Sparrow 체커↔표준 매핑 추출 후 기입(대기).

## 결함 판별 기준
- 지역 변수 선언의 우변이 `new 타입이름(...)`이고 좌변이 그 타입(또는 호환 타입)의 명시 표기다.
- 예: `TestClass testClass1 = new TestClass();` — 결함.
- 필드·프로퍼티 선언, 파라미터 기본값, 표현식 본문 등은 대상이 아니다(지역 변수 선언만).

## 이렇게 보여도 넘기지 말 것
스타일 항목이라도 **전건 수정**한다. 명시 타입이 관례처럼 보여도 스킵하지 말고 `var`로 통일한다.
- 좌변 타입이 우변 `new`의 타입과 **다른 상위 타입/인터페이스**로 선언된 경우(예: `IList<int> list = new List<int>();`)는 다형성 의도가 있어 타입이 "중요"할 수 있다 — 이때는 우변 타입으로 유추되면 의미가 바뀌므로, `var`로 바꾸면 정적 타입이 `List<int>`가 된다. 의도(인터페이스 타입 유지)를 확인한 뒤 처리하고, 인터페이스 타입 유지가 필요하면 그 근거를 판정에 기록한다.
- 명시 타입이 문서화 목적처럼 보여도 표준은 `var`이다 — 근거 확인 후 수정한다.

## 수정 패턴 (C# 예시)
```csharp
// Before — new 우변인데 좌변 명시 타입
TestClass testClass1 = new TestClass();
testClass1.print("BadCase1");

// After — 암시적 타입(var)
var testClass2 = new TestClass();
testClass2.print("GoodCase1");
```

## 검증 확인 조건 (G2)
- 빌드 통과(net472 / C# 7.3).
- 재분석 시 해당 라인 PRACTICE.OBJECT_INSTANTIATION.NOT_USED_IMPLICIT_TYPING 소멸.
- 신규 검출 0 — 특히 인터페이스/상위 타입 선언을 구현 타입으로 바꿔 다형성 계약이 깨지지 않았는지 확인.

## 기본 처리 분류
- [ ] 수정 → 검출 라인을 위 패턴으로 고침 (명시 타입 → var)
- [ ] 보류 → 문맥 확보 후 수정 (좌변 상위 타입 의도 판단 불가 시 needs_context; 확보 후 반드시 수정)
