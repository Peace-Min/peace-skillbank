# TOCTOU_RACE_CONDITION — 검사-사용 시점 경합 (time-of-check to time-of-use)

- **건수**: 4  |  **심각도**: 위험  |  **트랙**: C
- **Sparrow 설명**: 어떤 상태를 **검사(check)한 시점**과 그 결과에 근거해 **사용(use)하는 시점** 사이에 상태가 바뀔 수 있는 경합 창(window)이 존재한다. 대표적으로 `File.Exists()` 후 열기, 공유 필드 null 검사 후 사용, "존재 확인 → 생성/삭제" 패턴. 다중 스레드/외부 프로세스가 그 사이에 개입하면 결함이 발생한다.

## 지켜야 할 규칙 (무엇을 왜 검출)
검사와 사용이 **원자적이지 않으면**, 그 사이에 파일이 삭제/교체되거나 공유 상태가 변경되어 (1) 예외/크래시, (2) 잘못된 대상에 대한 작업, (3) 권한 상승·심볼릭링크 공격에 노출될 수 있다. 방산 다중스레드/파일I/O 코드에서 신뢰성·보안 양면 결함.

## 표준 매핑 (교차참조)
- CWE: **CWE-367** (Time-of-check Time-of-use Race Condition); 파일 경합은 **CWE-362**(Concurrent Execution using Shared Resource) 상위
- 무기체계 보안약점 점검 목록: 미매핑 (187 확보 시 "검사시점과 사용시점(TOCTOU) 경쟁조건" 계열)
- CERT-C/행안부/OWASP: 행안부 "검사시점과 사용시점(TOCTOU) 경쟁조건"; CERT FIO01-J, VNA02-J

## 진성 판별 기준
- **파일**: `File.Exists(p)` / `!File.Exists(p)` 로 분기 후 `File.Open`/`Create`/`Delete` — 사이에 파일 상태가 바뀔 수 있음.
- **공유 상태**: 필드·정적변수를 검사(`if (_x != null)` / `if (!_init)`)한 뒤 락 없이 사용/초기화 — 다른 스레드가 그 사이 변경.
- 검사와 사용이 **동일 락으로 보호되지 않으며** 다중 스레드/외부 프로세스 접근이 가능.

## 흔한 위양성 패턴
- 단일 스레드 전용 경로이며 외부 프로세스도 그 파일을 건드리지 않음이 보장 → 위양성 사유서(단, 보장 근거 명시).
- 이미 동일 락(`lock (_sync)`) 안에서 검사+사용이 원자적으로 수행됨(분석기가 락 범위를 못 이음).
- 검사 결과에 의존하지 않고 사용 시점에 예외로 다시 방어(예: Exists 는 UX용, 실제 열기는 try/catch).

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
- [ ] 위양성 → 사유서 (단일스레드·외부 미접근 보장 근거)
- [ ] 보류 → 사유 (동시성 범위 판단 불가 시; frontier-handoff)
