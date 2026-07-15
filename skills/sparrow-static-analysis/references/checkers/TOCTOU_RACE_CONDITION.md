# TOCTOU_RACE_CONDITION — TOCTOU 경쟁 조건

- **건수**: 4  |  **심각도**: 위험  |  **트랙**: C
- **Sparrow 설명**: TOCTOU 경쟁 조건 체커는 리소스의 상태를 확인하고 실제 사용하는 시간 간의 차이로 인해 발생하는 경쟁 조건을 검출합니다.

## 지켜야 할 규칙 (무엇을 왜 검출)
검사와 사용이 **원자적이지 않으면**, 그 사이에 파일이 삭제/교체되거나 공유 상태가 변경되어 (1) 예외/크래시, (2) 잘못된 대상에 대한 작업, (3) 권한 상승·심볼릭링크 공격에 노출될 수 있다. 방산 다중스레드/파일I/O 코드에서 신뢰성·보안 양면 결함.

## 표준 매핑 (교차참조)
- CWE: **CWE-367** (Time-of-check Time-of-use Race Condition); 파일 경합은 **CWE-362**(Concurrent Execution using Shared Resource) 상위
- 무기체계 보안약점 점검 목록: **187 항목 100% 적용(설정 확정)**; 개별 항목번호는 Sparrow 체커↔표준 매핑 추출 후 기입(대기)
- 행안부 SW보안약점(2021): "검사시점과 사용시점(TOCTOU) 경쟁조건"

## 진성 판별 기준
- **파일**: `File.Exists(p)` / `!File.Exists(p)` 로 분기 후 `File.Open`/`Create`/`Delete` — 사이에 파일 상태가 바뀔 수 있음.
- **공유 상태**: 필드·정적변수를 검사(`if (_x != null)` / `if (!_init)`)한 뒤 락 없이 사용/초기화 — 다른 스레드가 그 사이 변경.
- 검사와 사용이 **동일 락으로 보호되지 않으며** 다중 스레드/외부 프로세스 접근이 가능.

## 이렇게 보여도 넘기지 말 것
아래처럼 "경합 없음"으로 보여도 **스킵하지 말고**, 보장을 확인해 처리한다(전건 수정).
- 단일 스레드 전용 경로이며 외부 프로세스도 그 파일을 건드리지 않음이 보장되는 것처럼 보여도 — 그 보장 근거를 확인한다. 확정되면 판정 근거로 남기되, 파일삭제 TOCTOU면 `SafeFileUtil.SafeDelete`로 원자화하는 편이 안전하니 가능하면 수정한다.
- 이미 동일 락(`lock (_sync)`) 안에서 검사+사용이 원자적으로 수행되는 것처럼 보여도 — 검사와 사용이 정말 같은 락 범위인지 확인하고, 아니면 원자적 시도+예외로 수정한다.
- 검사 결과에 의존하지 않고 사용 시점에 예외로 다시 방어하는 것처럼 보여도(예: Exists 는 UX용, 실제 열기는 try/catch) — 프리체크 분기를 제거해 검사-사용 경합 자체를 없앤다.


## LLM 판단에 필요한 필수 문맥
- check 코드(`Exists`, 상태 확인, 권한 확인 등)와 실제 use 코드(`Open`, `Read`, `Delete`, 공유자원 사용 등).
- check와 use 사이에 실행되는 모든 코드와 시간 간격.
- 파일/공유자원이 다른 스레드나 프로세스에서 변경 가능한지.
- 락, 트랜잭션, 원자적 API 사용 여부.

## 문맥 부족 시 보류 기준
- check 라인 또는 use 라인 한쪽만 있으면 보류한다.
- 대상 자원이 외부 변경 가능한지 알 수 없으면 `needs_context=true`로 둔다.
- 이미 lock/원자적 open/예외 처리로 방어되는지 확인할 수 없으면 보류한다.

## 추가로 요청해야 할 코드 범위
- check부터 use까지 포함하는 전체 메서드.
- 관련 lock 객체와 동기화 범위.
- 파일 경로/공유자원 생성 및 접근 정책.
- 예외 처리 경로와 재시도/복구 정책.

## 수정 패턴 (C# 예시)
```csharp
// Before — 파일 검사 후 사용 (경합 창)
if (File.Exists(path))
{
    var text = File.ReadAllText(path);   // 사이에 삭제되면 예외
    Use(text);
}

// After (A) 검사 생략, 원자적 시도 + 예외 처리
try
{
    var text = File.ReadAllText(path);   // 열기 자체가 원자적 검사
    Use(text);
}
catch (FileNotFoundException) { /* 없음 처리 */ }
catch (IOException ex) { _log.Warn("읽기 실패", ex); }

// Before — 공유 상태 double-check 없이 지연 초기화
if (_cache == null)
    _cache = Build();                    // 다중 스레드 경합

// After (B) 락으로 검사+사용 원자화 (또는 Lazy<T>)
lock (_sync)
{
    if (_cache == null)
        _cache = Build();
}
// 권장: private readonly Lazy<Cache> _cache = new Lazy<Cache>(Build, isThreadSafe:true);
```

## 검증 확인 조건 (G2)
- 빌드 통과.
- Sparrow 재분석 시 해당 라인 TOCTOU_RACE_CONDITION 소멸.
- 신규 검출 0 — 추가한 try/catch 가 EMPTY_CATCH 가 되지 않고, 락 추가가 데드락/새 결함을 만들지 않는지.

## 기본 처리 분류
- [ ] 진성 → 수정 (원자적 시도+예외 / 락 / Lazy)
- [ ] 보류 → 문맥 확보 후 수정 (동시성 범위 판단 불가 시 needs_context; 확보 후 반드시 수정; frontier-handoff)
