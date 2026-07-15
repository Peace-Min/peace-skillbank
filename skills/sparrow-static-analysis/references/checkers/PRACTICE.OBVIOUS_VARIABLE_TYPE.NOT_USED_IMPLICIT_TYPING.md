# PRACTICE.OBVIOUS_VARIABLE_TYPE.NOT_USED_IMPLICIT_TYPING — 명확한 타입의 암시적 타입(var) 미사용

- **건수**: (실측 시 변동)  |  **심각도**: 낮음  |  **트랙**: A
- **Sparrow 설명**: 할당문을 통해 명확한 타입 유추가 가능하거나 타입이 중요하지 않을 때, 암시적 타입을 사용해야 합니다.

> **대부분 Track A(dotnet format/SparrowSyntaxFix) 또는 Track B(SparrowCommentFix/dotnet format whitespace)가 자동 처리한다. 이 가이드는 도구가 못 고친 잔여를 LLM이 처리할 때 사용**한다.

## 지켜야 할 규칙 (무엇을 왜 검출)
할당문 오른쪽에서 변수 형식이 명확하거나(리터럴·형변환·캐스트 등) 정확한 형식이 중요하지 않은 지역 변수는 명시 타입 대신 `var`(암시적 타입)로 선언해야 한다. 이것은 **보안 결함이 아니라 스타일·가독성·표준(MSDN C# 코딩 규칙) 준수** 항목이다. 명시 타입을 중복 표기하면 좌우가 같은 타입을 반복하여 시각적 잡음이 늘고, 팀 코드 스타일과 어긋난다. Sparrow는 `string s = "..."`, `int n = 27`, `Int32 v = Convert.ToInt32(...)`처럼 할당 우변에서 타입이 자명한 명시 타입 지역 변수 선언을 검출한다.

## 표준 매핑 (교차참조)
- MSDN C#:2015 코딩 규칙 **5.1** — 할당 오른쪽에서 변수 형식이 명확하거나 정확한 형식이 중요하지 않으면 지역 변수에 대해 암시적 형식을 사용합니다.
- C# Coding conventions : 2023 — 할당 오른쪽에서 변수 형식이 명확하거나 정확한 형식이 중요하지 않으면 지역 변수에 대해 암시적 형식을 사용합니다.
- CWE: 스타일 항목이라 직접 매핑 없음(광의 **CWE-1078** 계열, Inappropriate Source Code Style/Formatting).
- 무기체계 보안약점 점검 목록: **187 항목 100% 적용**; 개별 항목번호는 Sparrow 체커↔표준 매핑 추출 후 기입(대기).

## 진성 판별 기준
- 지역 변수 선언이 명시 타입이고, 우변만으로 타입이 자명하다(문자열/숫자 리터럴, `new T()`, `(T)expr`, `Convert.ToXxx`, 명시 반환형 메서드 등).
- 예: `string var1 = "...";`, `int var2 = 27;`, `Int32 var3 = Convert.ToInt32(Console.ReadLine());` — 모두 진성.
- 필드·프로퍼티·상수(`const`)·메서드 파라미터는 대상이 아니다(지역 변수 선언만).

## 이렇게 보여도 넘기지 말 것
스타일 항목이라도 **전건 수정**한다. "명시 타입이 더 읽기 좋아 보인다"는 이유로 스킵하지 말고 표준(`var`)으로 통일한다.
- 우변이 익명 타입·LINQ 결과·긴 제네릭이라 명시 타입이 불가능/장황해 보여도, 우변 타입이 자명하면 `var`로 바꾼다.
- 초기화 없이 선언만 있는 경우(`int x;`)나 우변으로 타입 유추가 불가능한 경우(예: `var`가 컴파일 불가)는 대상이 아니므로 그대로 두되, 그 근거(유추 불가)를 판정에 기록한다(스킵이 아니라 판정 근거).
- 의도적으로 명시 타입을 남긴 것처럼 보여도 표준은 `var`이다 — 근거를 확인한 뒤 처리한다.

## 수정 패턴 (C# 예시)
```csharp
// Before — 우변에서 타입이 자명한데 명시 타입 사용
string var1 = "This is clearly a string.";
int var2 = 27;
Int32 var3 = Convert.ToInt32(Console.ReadLine());

// After — 암시적 타입(var)
var var1 = "This is clearly a string.";
var var2 = 27;
var var3 = Convert.ToInt32(Console.ReadLine());
```

## 검증 확인 조건 (G2)
- 빌드 통과(net472 / C# 7.3).
- 재분석 시 해당 라인 PRACTICE.OBVIOUS_VARIABLE_TYPE.NOT_USED_IMPLICIT_TYPING 소멸.
- 신규 검출 0 — 특히 타입 변경으로 인한 오버로드 해석 변화·의도치 않은 암시적 변환이 발생하지 않았는지 확인.

## 기본 처리 분류
- [ ] 진성 → 수정 (명시 타입 → var)
- [ ] 보류 → 문맥 확보 후 수정 (우변 타입 유추 가능성 판단 불가 시 needs_context; 확보 후 반드시 수정)
