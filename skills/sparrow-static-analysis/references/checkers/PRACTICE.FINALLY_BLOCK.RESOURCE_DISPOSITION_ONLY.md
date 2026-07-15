# PRACTICE.FINALLY_BLOCK.RESOURCE_DISPOSITION_ONLY — finally 블록의 자원 해제 전용(→using 대체)

- **건수**: 2  |  **심각도**: 보통  |  **트랙**: C
- **Sparrow 설명**: try-finally 문장에서 finally 블록 안에 Dispose 메소드 호출만 있는 경우에 using문으로 대체해야 합니다.

## 지켜야 할 규칙 (무엇을 왜 검출)
`finally { x.Dispose(); }` 패턴은 (1) `x`가 null 일 때 방어가 빠지기 쉽고, (2) 자원 획득이 `try` 안/밖 어디인지에 따라 예외 안전성이 달라진다. `using` 은 컴파일러가 null 안전·예외 안전 해제를 보장하므로 **결함 여지를 줄이는 표준형**이다. 자원 누수([[RESOURCE_LEAK]], CWE-772)와 같은 도메인의 예방적 개선.

## 표준 매핑 (교차참조)
- CWE: 직접 결함 아님(권고성). 인접 **CWE-460**(Improper Cleanup on Thrown Exception)·**CWE-772** 예방
- 무기체계 보안약점 점검 목록: **187 항목 100% 적용(설정 확정)**; 개별 항목번호는 Sparrow 체커↔표준 매핑 추출 후 기입(대기) — 단 관례/유지보수 개선 계열이라 실매핑 대상이 아닐 수 있음
- .NET Framework Design Guideline: IDisposable 자원은 `try/finally` 대신 `using` 권장

## 결함 판별 기준
- `finally` 본문이 **자원 해제 호출로만** 구성(`Dispose()`/`Close()` 및 null 가드 정도).
- 대상 자원이 해당 `try` 스코프에서 **획득·소유·소비 후 종료**된다(소유권이 스코프 내에 있음).

## 이렇게 보여도 넘기지 말 것
아래처럼 "using 치환 불가"로 보여도 **스킵하지 말고**, 조건을 확인해 처리한다(전건 수정).
- `finally`가 자원해제 **외 다른 정리**(플래그 복원, 락 해제, 로깅)도 수행하는 것처럼 보이면 — `using` 단순 치환은 불가하나, 자원해제만 `using`으로 옮기고 나머지 정리는 별도 `finally`/`try`로 분리해 수정할 수 있는지 확인한다. 불가하면 근거를 판정에 남긴다.
- 자원이 **조건부로만** 생성되거나 스코프 밖에서 소유권이 넘어오는 것처럼 보이면 — 소유권을 확인하고, 스코프 소유면 `using`으로 수정한다. 판단 불가하면 `보류`(needs_context).
- 이미 예외 안전하게 잘 작성된 `try/finally`로 의도된 것처럼 보여도 — `using` 치환이 더 간결·안전한지 확인해 처리한다.


## LLM 판단에 필요한 필수 문맥
- try/finally 전체와 finally 블록의 모든 문장.
- Dispose/Close 대상 변수가 어디서 생성 또는 할당되는지.
- 자원 소유권이 현재 scope에 있는지, 필드/반환값/외부 소유 자원인지.
- null 가능성과 조건부 생성 여부.
- using 블록으로 바꿨을 때 자원 생명주기가 짧아지지 않는지.

## 문맥 부족 시 보류 기준
- finally의 일부만 보이고 자원 생성 위치가 없으면 보류한다.
- 자원이 호출자에게 반환되거나 필드에 저장되는지 알 수 없으면 `needs_context=true`로 둔다.
- finally가 Dispose 외 플래그 복원, 락 해제, 로깅 등 다른 정리를 하는지 확인할 수 없으면 보류한다.

## 추가로 요청해야 할 코드 범위
- 검출 try/finally 전체.
- 자원 변수 선언과 최초 할당 지점.
- 해당 자원이 반환/필드 저장/외부 전달되는 주변 코드.
- 같은 클래스의 Dispose 패턴 구현 여부.

## 수정 패턴 (C# 예시, net472)
```csharp
// Before — finally 가 Dispose 전용
var conn = new SqlConnection(cs);
try
{
    conn.Open();
    Run(conn);
}
finally
{
    conn.Dispose();     // 자원해제만
}

// After — using 블록 (net472는 선언형 아닌 블록형)
using (var conn = new SqlConnection(cs))
{
    conn.Open();
    Run(conn);
}
```

## 검증 확인 조건 (G2)
- 빌드 통과.
- Sparrow 재분석 시 해당 위치 PRACTICE.FINALLY_BLOCK.RESOURCE_DISPOSITION_ONLY 소멸.
- 신규 검출 0 — 치환으로 RESOURCE_LEAK/이중해제 회귀 없음.

## 기본 처리 분류
- [ ] 수정 → 검출 라인을 위 패턴으로 고침 (using 치환)
- [ ] 보류 → 문맥 확보 후 수정 (소유권 흐름 판단 필요 시 needs_context; 확보 후 반드시 수정; frontier-handoff)
