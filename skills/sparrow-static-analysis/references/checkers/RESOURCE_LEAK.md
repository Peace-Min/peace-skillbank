# RESOURCE_LEAK — 자원 누수

- **건수**: 14  |  **심각도**: 매우위험  |  **트랙**: C
- **Sparrow 설명**: 리소스 누수 체커는 파일, 소켓 등 리소스를 할당한 후에 해제하지 않는 코드를 검출합니다.

## 지켜야 할 규칙 (무엇을 왜 검출)
관리되지 않는 자원을 해제하지 않으면 **핸들/메모리 고갈**로 이어져 장시간 상주하는 방산 소프트웨어에서 점진적 성능 저하·기능 실패를 유발한다(가용성 결함). GC는 관리 메모리만 회수하며 파일 핸들·소켓·DB 커넥션은 비결정적으로만 정리되어 실질적 누수가 된다.

## 표준 매핑 (교차참조)
- CWE: **CWE-772** (Missing Release of Resource after Effective Lifetime); 연관 **CWE-404**(Improper Resource Shutdown)
- 무기체계 보안약점 점검 목록: **187 항목 100% 적용(설정 확정)**; 개별 항목번호는 Sparrow 체커↔표준 매핑 추출 후 기입(대기)
- 행안부 SW보안약점(2021): "부적절한 자원 해제"
- .NET Framework Design Guideline: IDisposable 자원은 `using`/Dispose 패턴으로 해제

## 진성 판별 기준
- 지역에서 `new`/팩토리로 **IDisposable 을 생성·소유**하고(예: `new FileStream`, `SqlConnection`, `Bitmap`, `StreamReader`), 그 스코프에서 소비 후 종료된다.
- 생성부터 마지막 사용까지 사이에 **예외 발생 가능 호출**이 있는데 `using`/`try-finally` 로 감싸이지 않음 → 예외 시 Dispose 누락.
- 또는 조기 `return`/`break` 경로에서 Dispose 를 건너뜀.

## 이렇게 보여도 넘기지 말 것
아래처럼 "여기서 해제하면 안 됨"으로 보여도 **스킵하지 말고**, 소유권 계약을 확인해 처리한다(전건 수정).
- **소유권 이전처럼 보이는 경우**: 만든 자원을 필드에 저장하거나 호출측에 반환/전달하여 **해제 책임이 이 스코프에 없어 보임**(예: `return reader;`, DI 컨테이너·팩토리 반환). 여기서 Dispose 하면 오히려 버그이므로, 호출자/필드 소유자가 실제로 해제하는지 확인한다. 확인되면 `verdict=보류` + `needs_context=true`(missing_context에 "호출자/소유자 Dispose 계약")로 두고, 소유자 측에서 Dispose 패턴을 갖추도록 수정한다. 근거 없이 스킵하지 않는다.
- 이미 `using` 바깥의 상위 `try-finally`나 소유 객체(`Component.components`)가 해제를 보장하는 것처럼 보이면 — 그 보장 코드가 실제로 있는지 확인하고, 없으면 `using`/`try-finally`로 감싼다.
- 프레임워크가 소유하는 스트림(예: `HttpContext.Response.OutputStream`)은 닫으면 안 되므로, 이 경우 Dispose 를 추가하지 말고 소유 관계를 근거로 남긴다(스킵이 아니라 판정 근거 기록).
- **주의**: `StreamReader`/`StreamWriter` 를 닫으면 내부 Stream 도 닫힘 → 이중 해제/소유 혼동에 유의해 수정한다.


## LLM 판단에 필요한 필수 문맥
- IDisposable 자원 생성 지점부터 모든 return/throw/break 경로까지의 흐름.
- Dispose/Close/using/try-finally가 모든 경로에서 실행되는지.
- 자원이 현재 scope 소유인지, 반환/필드 저장/외부 컨테이너/DI로 소유권이 이전되는지.
- 예외 가능 호출이 자원 생성 후 Dispose 전 사이에 있는지.

## 문맥 부족 시 보류 기준
- 자원 생성 한 줄만 있고 생명주기 전체가 없으면 진성 단정 금지.
- 반환 또는 필드 저장으로 소유권이 이전되는지 알 수 없으면 `needs_context=true`로 둔다.
- 상위 객체의 Dispose 패턴이 있는지 확인할 수 없으면 보류한다.

## 추가로 요청해야 할 코드 범위
- 검출 라인을 포함하는 전체 메서드.
- 자원 변수의 모든 사용, 반환, 필드 저장, Dispose 호출.
- 같은 클래스의 `Dispose`/`Close`/finalizer 구현.
- 호출자가 자원을 Dispose하는 계약이 있는 경우 해당 호출자 예시.

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
- [ ] 보류 → 문맥 확보 후 수정 (소유권 흐름 판단 불가 시 needs_context; 확보 후 반드시 수정; frontier-handoff)
