# RESOURCE_LEAK — 자원 누수 (resource leak)

- **건수**: 14  |  **심각도**: 매우위험  |  **트랙**: C
- **Sparrow 설명**: `IDisposable` 자원(파일/스트림/소켓/DB 연결/GDI 핸들 등)을 획득한 뒤 **모든 경로에서 해제(Dispose/Close)되지 않는다**. 예외 경로나 조기 반환에서 해제가 누락되거나 `using`/`try-finally` 로 감싸이지 않은 지점을 잡는다.

## 지켜야 할 규칙 (무엇을 왜 검출)
관리되지 않는 자원을 해제하지 않으면 **핸들/메모리 고갈**로 이어져 장시간 상주하는 방산 소프트웨어에서 점진적 성능 저하·기능 실패를 유발한다(가용성 결함). GC는 관리 메모리만 회수하며 파일 핸들·소켓·DB 커넥션은 비결정적으로만 정리되어 실질적 누수가 된다.

## 표준 매핑 (교차참조)
- CWE: **CWE-772** (Missing Release of Resource after Effective Lifetime); 연관 **CWE-404**(Improper Resource Shutdown)
- 무기체계 보안약점 점검 목록: 미매핑 (187 확보 시 "부적절한 자원 해제" 계열)
- CERT-C/행안부/OWASP: 행안부 "부적절한 자원 해제"; CERT FIO04-J(개념 대응)

## 진성 판별 기준
- 지역에서 `new`/팩토리로 **IDisposable 을 생성·소유**하고(예: `new FileStream`, `SqlConnection`, `Bitmap`, `StreamReader`), 그 스코프에서 소비 후 종료된다.
- 생성부터 마지막 사용까지 사이에 **예외 발생 가능 호출**이 있는데 `using`/`try-finally` 로 감싸이지 않음 → 예외 시 Dispose 누락.
- 또는 조기 `return`/`break` 경로에서 Dispose 를 건너뜀.

## 흔한 위양성 패턴
- **소유권 이전**: 만든 자원을 필드에 저장하거나 호출측에 반환/전달하여 **해제 책임이 이 스코프에 없음**(예: `return reader;`, DI 컨테이너·팩토리 반환) → 여기서 Dispose 하면 오히려 버그. 위양성 사유서.
- 이미 `using` 바깥의 상위 `try-finally`나 소유 객체(`Component.components`)가 해제를 보장.
- 프레임워크가 소유하는 스트림(예: `HttpContext.Response.OutputStream`) — 닫으면 안 됨.
- **주의**: `StreamReader`/`StreamWriter` 를 닫으면 내부 Stream 도 닫힘 → 이중 해제/소유 혼동에 유의.

## 수정 패턴 (C# 예시, net472 = using 블록 문법)
```csharp
// Before — 예외 시 Dispose 누락
var fs = new FileStream(path, FileMode.Open);
var data = Parse(fs);          // 여기서 예외 나면 fs 누수
fs.Close();
return data;

// After (A) using 블록 (net472는 using 선언 아님)
using (var fs = new FileStream(path, FileMode.Open))
{
    return Parse(fs);
}

// After (B) 필드 자원은 Dispose 패턴으로 소유자에서 해제
public void Dispose()
{
    _conn?.Dispose();
    _conn = null;
}

// 다중 자원 — 중첩 using
using (var conn = new SqlConnection(cs))
using (var cmd = new SqlCommand(sql, conn))
{
    conn.Open();
    ...
}
```

## 검증 확인 조건 (G2)
- 빌드 통과.
- Sparrow 재분석 시 해당 라인 RESOURCE_LEAK 소멸.
- 신규 검출 0 — 특히 **이중 해제(USE_AFTER_FREE 성격)·소유권 오이전으로 인한 신규 결함 없음**. 소유권 이전 케이스를 using 으로 감싸 회귀시키지 않았는지 확인.

## 기본 처리 분류
- [ ] 진성 → 수정 (using / try-finally / Dispose 패턴)
- [ ] 위양성 → 사유서 (소유권 이전·프레임워크 소유 근거)
- [ ] 보류 → 사유 (소유권 흐름 판단 불가 시; frontier-handoff)
