# FORMATTING.BETWEEN_MEMBER_DEFINITION.MISSING_BLANK_LINE — 멤버 정의 사이 빈 줄 누락

- **건수**: (실측 시 변동)  |  **심각도**: 낮음  |  **트랙**: B
- **Sparrow 설명**: 메소드나 프로퍼티 선언문들 사이에 한 줄 이상이 빈 줄이 있어야 합니다.

> **대부분 Track A(dotnet format/SparrowSyntaxFix) 또는 Track B(SparrowCommentFix/dotnet format whitespace)가 자동 처리한다. 이 가이드는 도구가 못 고친 잔여를 LLM이 처리할 때 사용**한다.

## 지켜야 할 규칙 (무엇을 왜 검출)
메서드/프로퍼티 등 멤버 정의 사이에는 **빈 줄을 하나 이상** 넣어 시각적으로 구분해야 한다. **보안 결함이 아니라 스타일·가독성·표준(MSDN C# 코딩 규칙) 준수** 항목이다. 멤버가 빈 줄 없이 붙어 있으면 경계가 흐려져 판독성이 떨어진다. Sparrow는 앞 멤버의 닫는 `}` 다음 줄에 곧바로 다음 멤버 선언이 오는 경우를 검출한다.

## 표준 매핑 (교차참조)
- MSDN C#:2015 코딩 규칙 **2.5** — 메서드 정의와 속성 정의 간에는 빈 줄을 하나 이상 추가합니다.
- C# Coding conventions : 2023 — 메서드 정의와 속성 정의 간에는 빈 줄을 하나 이상 추가합니다.
- CWE: 스타일 항목이라 직접 매핑 없음(광의 **CWE-1078** 계열).
- 무기체계 보안약점 점검 목록: **187 항목 100% 적용**; 개별 항목번호는 Sparrow 체커↔표준 매핑 추출 후 기입(대기).

## 결함 판별 기준
- 한 멤버 정의(메서드/프로퍼티)의 끝과 다음 멤버 정의의 시작 사이에 빈 줄이 하나도 없다.
- 예: 앞 메서드의 닫는 중괄호 줄 바로 다음 줄에서 다음 메서드가 시작.

## 이렇게 보여도 넘기지 말 것
스타일 항목이라도 **전건 수정**한다. 붙여 쓴 멤버가 의도된 밀집 배치처럼 보여도 빈 줄을 넣는다.
- 자동 구현 프로퍼티가 여러 개 연속(`public int A { get; set; }` / `public int B { get; set; }`)이라 밀집이 자연스러워 보여도, 규칙 정의가 이를 대상으로 잡으면 사이에 빈 줄을 넣는다(규칙 기준을 따른다).
- `#region`/전처리 지시문·주석이 사이에 끼어 있어도 그것이 빈 줄을 대신하지는 않으므로, 규칙이 요구하면 빈 줄을 추가한다.
- 멤버 밀집이 관례처럼 보여도 표준은 멤버 사이 빈 줄 1개 이상이다 — 근거 확인 후 수정한다.

## 수정 패턴 (C# 예시)
```csharp
// Before — 멤버 사이 빈 줄 없음
public static void BadCase1_1()
{
    Console.WriteLine("Before");
}
public static void BadCase1_2()
{
    Console.WriteLine("Current");
}

// After — 멤버 사이 빈 줄 1개
public static void GoodCase1_1()
{
    Console.WriteLine("Before");
}

public static void GoodCase1_2()
{
    Console.WriteLine("Current");
}
```

## 검증 확인 조건 (G2)
- 빌드 통과(net472 / C# 7.3) — 공백 변경은 의미에 영향 없음.
- 재분석 시 해당 라인 FORMATTING.BETWEEN_MEMBER_DEFINITION.MISSING_BLANK_LINE 소멸.
- 신규 검출 0 — 빈 줄 추가로 다른 서식 규칙(연속 빈 줄 과다 등)을 새로 위반하지 않았는지 확인.

## 기본 처리 분류
- [ ] 수정 → 검출 라인을 위 패턴으로 고침 (멤버 정의 사이 빈 줄 1개 삽입)
- [ ] 보류 → 문맥 확보 후 수정 (멤버 경계 판단 불가 시 needs_context; 확보 후 반드시 수정)
