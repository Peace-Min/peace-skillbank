# OVERLY_BROAD_CATCH — 지나치게 넓은 예외 포착 (overly broad catch)

- **건수**: 139  |  **심각도**: 보통  |  **트랙**: C
- **Sparrow 설명**: `catch (Exception)` / `catch (SystemException)` 처럼 **너무 넓은 예외형**을 포착한다. 특정 예외만 처리해야 할 자리에서 모든 예외를 잡아, 예상치 못한 결함(프로그래밍 오류·치명적 예외)까지 함께 삼켜 은폐할 수 있다. (트랙 C로 분류: 어느 예외형으로 좁힐지는 **맥락 판단** 필요.)

## 지켜야 할 규칙 (무엇을 왜 검출)
넓은 `catch (Exception)`은 처리 의도가 없던 예외(널참조·인덱스초과·구성오류 등 **버그성 예외**)까지 잡아 정상 흐름처럼 넘어가게 만든다. 결함이 은폐되어 잘못된 상태로 실행이 계속되고, 사고 원인분석이 어려워진다. 방산 신뢰성시험의 예외처리 적정성 기준에서 "잡을 예외만 좁게 잡는다"가 원칙. [[EMPTY_CATCH_BLOCK]]과 결합되면 위험 가중.

## 표준 매핑 (교차참조)
- CWE: **CWE-396** (Declaration of Catch for Generic Exception); 삼킴과 결합 시 **CWE-390**(Detection of Error Condition Without Action)
- 무기체계 보안약점 점검 목록: 미매핑 (187 확보 시 "부적절한 예외처리" 계열)
- CERT-C/행안부/OWASP: CERT ERR08-J(Do not catch NullPointerException or any superclass); 행안부 "부적절한 예외처리"

## 진성 판별 기준
- `catch (Exception)` / `catch` / `catch (SystemException)` 등 광범위 포착.
- **실제로 발생 가능한 예외는 소수의 특정형**인데(예: `IOException`, `FormatException`) 전부 잡고 있다.
- 잡은 뒤 예외형을 구분하지 않고 동일 처리 → 버그성 예외까지 정상처럼 흡수.

## 흔한 위양성 패턴
- **최상위 경계 핸들러**(스레드 루트, 메시지 루프, 작업 큐 소비자, 전역 예외 핸들러)에서는 **의도적으로 넓게 잡아 로깅 후 안전 종료/격리**하는 것이 정석 → 위양성 사유서(단, 반드시 로깅·재던지기/격리 존재).
- 재던지기(`catch (Exception) { Cleanup(); throw; }`)로 삼키지 않고 정리만 하는 경우 — 대개 허용, `finally`로 대체 권고.
- 호출 API가 던지는 예외형이 문서화되지 않아 방어적으로 넓게 잡아야 하는 상호운용 경계.

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

// 경계 핸들러(위양성 케이스)는 유지하되 로깅+격리 명시
```
- 원칙: **예상 가능한 예외형으로 좁힌다.** 넓게 잡아야 할 정당한 경계면 "왜 넓은지" 주석 + 로깅/재던지기를 명시해 사유서 근거로.

## 검증 확인 조건 (G2)
- 빌드 통과.
- Sparrow 재분석 시 해당 catch 의 OVERLY_BROAD_CATCH 소멸.
- 신규 검출 0 — 좁힌 결과 미처리 예외 경로가 EMPTY_CATCH 나 새 UNCHECKED 결함을 만들지 않는지.

## 기본 처리 분류
- [ ] 진성 → 수정 (예외형 좁히기 / 예상 밖 재던지기)
- [ ] 위양성 → 사유서 (경계 핸들러·상호운용 근거; 로깅·격리 전제)
- [ ] 보류 → 사유 (발생 가능 예외형 판단 불가 시; frontier-handoff)
