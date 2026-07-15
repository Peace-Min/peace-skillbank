# OVERLY_BROAD_CATCH — 지나치게 일반적인 예외 처리

- **건수**: 139  |  **심각도**: 보통  |  **트랙**: C
- **Sparrow 설명**: 지나치게 일반적인 예외 처리 체커는 너무 다양한 예외를 포괄적으로 처리하는 코드를 검출합니다.

## 지켜야 할 규칙 (무엇을 왜 검출)
넓은 `catch (Exception)`은 처리 의도가 없던 예외(널참조·인덱스초과·구성오류 등 **버그성 예외**)까지 잡아 정상 흐름처럼 넘어가게 만든다. 결함이 은폐되어 잘못된 상태로 실행이 계속되고, 사고 원인분석이 어려워진다. 방산 신뢰성시험의 예외처리 적정성 기준에서 "잡을 예외만 좁게 잡는다"가 원칙. [[EMPTY_CATCH_BLOCK]]과 결합되면 위험 가중.

## 표준 매핑 (교차참조)
- CWE: **CWE-396** (Declaration of Catch for Generic Exception); 삼킴과 결합 시 **CWE-390**(Detection of Error Condition Without Action)
- 무기체계 보안약점 점검 목록: **187 항목 100% 적용(설정 확정)**; 개별 항목번호는 Sparrow 체커↔표준 매핑 추출 후 기입(대기)
- 행안부 SW보안약점(2021): "부적절한 예외처리"
- .NET Framework Design Guideline: 포괄적 `catch (Exception)` 대신 구체적 예외형만 포착

## 진성 판별 기준
- `catch (Exception)` / `catch` / `catch (SystemException)` 등 광범위 포착.
- **실제로 발생 가능한 예외는 소수의 특정형**인데(예: `IOException`, `FormatException`) 전부 잡고 있다.
- 잡은 뒤 예외형을 구분하지 않고 동일 처리 → 버그성 예외까지 정상처럼 흡수.

## 이렇게 보여도 넘기지 말 것
아래처럼 "넓게 잡는 게 정당"해 보여도 **스킵하지 말고**, 조건을 확인해 좁히거나 명시 처리한다(전건 수정).
- **최상위 경계 핸들러처럼 보이는 경우**(스레드 루트, 메시지 루프, 작업 큐 소비자, 전역 예외 핸들러) — 넓게 잡는 게 정석처럼 보여도, 이 프로젝트는 경계 핸들러도 예외 없이 예외형을 열거해 명시 catch 로 수정한다. 로깅·재던지기/격리가 있는지 확인하고, 없으면 추가한다.
- 재던지기(`catch (Exception) { Cleanup(); throw; }`)로 삼키지 않고 정리만 하는 경우처럼 보여도 — `finally`로 대체하거나 예외형을 좁혀 수정한다.
- 호출 API가 던지는 예외형이 문서화되지 않아 방어적으로 넓게 잡은 상호운용 경계처럼 보이면 — 예외형 목록(문맥)이 필요하므로 `verdict=보류` + `needs_context=true`로 두고, 확보 후 예외형별 명시 catch 로 수정한다. 근거 없이 스킵하지 않는다.


## LLM 판단에 필요한 필수 문맥
- 검출 라인의 `try` 본문 전체와 모든 `catch`/`finally` 블록.
- `try` 본문에서 호출하는 주요 API/메서드와 문서화된 예외 계약.
- 사용 가능하면 로컬 .NET reference XML documentation의 `<exception>` 태그에서 추출한 try 내부 호출 API별 발생 가능 예외 후보 목록.
- 해당 catch가 최상위 경계 핸들러인지 여부(스레드 루트, 메시지 루프, 작업 큐, 전역 예외 처리 등).
- catch 본문이 로깅, 격리, 사용자 통지, 안전 종료, `throw;` 재전파 중 무엇을 수행하는지.
- 같은 try에 더 구체적인 catch가 앞에 있는지, 마지막 catch가 예상 밖 예외만 처리하는 구조인지.

## 문맥 부족 시 보류 기준
- `catch (Exception)` 한 줄만 있고 `try` 본문 또는 catch 본문 전체가 없으면 진성 여부를 단정하지 않는다.
- 경계 핸들러 여부를 알 수 없거나 호출 API의 발생 가능 예외를 알 수 없으면 `보류`로 둔다(문맥 확보 후 수정).
- 단순 로깅처럼 보여도 이후 재던지기/격리/상태복구 여부가 누락되면 `needs_context=true`로 둔다.

## 추가로 요청해야 할 코드 범위
- 검출 라인을 포함하는 전체 메서드.
- 같은 파일의 로거/오류 처리 헬퍼 선언부.
- try 본문에서 호출하는 프로젝트 내부 메서드의 본문 또는 예외 계약 주석.
- 로컬 .NET reference XML documentation 기반 추출 결과가 있으면 해당 try 본문과 관련된 호출 API/예상 예외 목록.
- 해당 메서드가 이벤트 루프/스레드 루트/작업 큐 경계인지 보여주는 호출자 1단계.

## 수정 패턴 (C# 예시)
```csharp
// Before — 모든 예외 흡수
try { var cfg = Load(path); Apply(cfg); }
catch (Exception ex) { _log.Warn("설정 로드 실패", ex); }   // 버그성 예외까지 흡수

// After (A) 실제 가능한 예외형만 좁게
try { var cfg = Load(path); Apply(cfg); }
catch (IOException ex) { _log.Warn("설정 파일 접근 실패", ex); }
catch (FormatException ex) { _log.Warn("설정 형식 오류", ex); }
// 그 외 예외는 잡지 않음 → 상위로 전파(버그는 드러나야 함)

// After (B) 넓게 잡되 예상 밖은 재던지기 (경계 핸들러가 아닐 때)
catch (Exception ex)
{
    if (!(ex is IOException || ex is FormatException)) throw;
    _log.Warn("설정 처리 실패", ex);
}

// 경계 핸들러라도 예외형을 열거해 명시 catch 로 좁히고 로깅+격리 명시
```
- 원칙: **예상 가능한 예외형으로 좁힌다.** 넓게 잡아야 할 정당한 경계라도 예외형을 열거해 명시 catch 로 수정하고, 로깅/재던지기를 명시한다.

## 검증 확인 조건 (G2)
- 빌드 통과.
- Sparrow 재분석 시 해당 catch 의 OVERLY_BROAD_CATCH 소멸.
- 신규 검출 0 — 좁힌 결과 미처리 예외 경로가 EMPTY_CATCH 나 새 UNCHECKED 결함을 만들지 않는지.

## 기본 처리 분류
- [ ] 진성 → 수정 (예외형 좁히기 / 예상 밖 재던지기)
- [ ] 보류 → 문맥 확보 후 수정 (발생 가능 예외형 판단 불가 시 needs_context; 확보 후 반드시 수정; frontier-handoff)
