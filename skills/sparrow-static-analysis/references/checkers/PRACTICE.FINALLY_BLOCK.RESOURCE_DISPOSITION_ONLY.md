# PRACTICE.FINALLY_BLOCK.RESOURCE_DISPOSITION_ONLY — finally가 자원해제 전용 (prefer using)

- **건수**: 2  |  **심각도**: 보통  |  **트랙**: C
- **Sparrow 설명**: `try/finally` 의 `finally` 블록이 **오직 자원 해제(Dispose/Close)만** 수행한다. 이 패턴은 `using` 문으로 대체하는 것이 더 안전·간결하다(예외 안전성·가독성). 대체가 항상 기계적이지 않아(자원 소유·조건부 해제 판단) 트랙 C.

## 지켜야 할 규칙 (무엇을 왜 검출)
`finally { x.Dispose(); }` 패턴은 (1) `x`가 null 일 때 방어가 빠지기 쉽고, (2) 자원 획득이 `try` 안/밖 어디인지에 따라 예외 안전성이 달라진다. `using` 은 컴파일러가 null 안전·예외 안전 해제를 보장하므로 **결함 여지를 줄이는 표준형**이다. 자원 누수([[RESOURCE_LEAK]], CWE-772)와 같은 도메인의 예방적 개선.

## 표준 매핑 (교차참조)
- CWE: 직접 결함 아님(권고성). 인접 **CWE-460**(Improper Cleanup on Thrown Exception)·**CWE-772** 예방
- 무기체계 보안약점 점검 목록: 미매핑 (관례/유지보수 개선 — 187 매핑 대상 아닐 가능성 높음)
- CERT-C/행안부/OWASP: .NET Framework Guidelines(IDisposable → using 권장)

## 진성 판별 기준
- `finally` 본문이 **자원 해제 호출로만** 구성(`Dispose()`/`Close()` 및 null 가드 정도).
- 대상 자원이 해당 `try` 스코프에서 **획득·소유·소비 후 종료**된다(소유권이 스코프 내에 있음).

## 흔한 위양성 패턴
- `finally`가 자원해제 **외 다른 정리**(플래그 복원, 락 해제, 로깅)도 수행 → `using` 단순 치환 불가, 지적 부적합 → 사유서.
- 자원이 **조건부로만** 생성되거나 스코프 밖에서 소유권이 넘어옴 → `using` 부적합, 현행 유지.
- 이미 예외 안전하게 잘 작성된 `try/finally`로 의도된 경우.

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
- [ ] 진성 → 수정 (using 치환)
- [ ] 위양성 → 사유서 (finally가 해제 외 정리 포함·조건부 소유 근거)
- [ ] 보류 → 사유 (소유권 흐름 판단 필요 시; frontier-handoff)
