# LEAK.SYSTEM_INFORMATION — 시스템 정보 노출 (system information leak)

- **건수**: 4  |  **심각도**: 높음  |  **트랙**: C
- **Sparrow 설명**: 내부 시스템 정보(예외 스택트레이스, 파일 경로, 환경변수, 서버/DB 구성, 내부 IP·호스트명 등)를 **외부로 관측 가능한 출력**(사용자 메시지, 로그 파일이 아닌 UI/응답, 콘솔, 네트워크)으로 내보낸다. 공격자에게 내부 구조 정보를 제공한다.

## 지켜야 할 규칙 (무엇을 왜 검출)
스택트레이스·경로·구성 값 등은 공격자에게 **정찰(reconnaissance) 정보**를 준다. 방산 소프트웨어에서는 내부 구조·배치 정보 노출 자체가 보안약점이다. 상세 오류는 **내부 로그**에만 남기고, 외부에는 **일반화된 메시지 + 상관관계 ID**만 노출해야 한다.

## 표준 매핑 (교차참조)
- CWE: **CWE-200** (Exposure of Sensitive Information); 세부 **CWE-209**(Generation of Error Message Containing Sensitive Information), **CWE-497**(Exposure of System Data)
- 무기체계 보안약점 점검 목록: 미매핑 (187 확보 시 "정보 노출/오류 메시지를 통한 정보 노출" 계열)
- CERT-C/행안부/OWASP: 행안부 "오류 메시지 통한 정보 노출"; OWASP A04/A05 계열

## 진성 판별 기준
- 노출 대상이 **민감**: `ex.ToString()`/`ex.StackTrace`, `Exception.Message`(내부 세부), 절대경로, 커넥션 문자열, 환경변수, 내부 호스트/IP.
- 싱크가 **외부 관측 가능**: 사용자에게 보이는 `MessageBox`/UI 라벨, HTTP 응답 본문, 파일이 아닌 표준출력, 외부 전송.
- (내부 전용 로그 파일로만 가는 경우는 대개 허용 — 아래 위양성 참고.)

## 흔한 위양성 패턴
- 대상이 **폐쇄망 내부 운영 로그**로만 흘러가고 외부에 노출되지 않음(방산 폐쇄망 특성상 상당수가 여기 해당) → 위양성 사유서(단, 로그 접근통제 전제).
- `#if DEBUG` 로 디버그 빌드에서만 상세 출력.
- 노출값이 실제로는 비민감(고정 문구). → 사유서.

## 수정 패턴 (C# 예시)
```csharp
// Before — 스택트레이스를 사용자 UI에 노출
catch (Exception ex)
{
    MessageBox.Show(ex.ToString());        // 내부 정보 노출
}

// After — 내부엔 상세 로그, 외부엔 일반 메시지 + ID
catch (Exception ex)
{
    var errorId = Guid.NewGuid();
    _log.Error($"[{errorId}] 처리 실패", ex);   // 상세는 내부 로그에만
    MessageBox.Show($"처리 중 오류가 발생했습니다. (오류 ID: {errorId})");
}
```

## 검증 확인 조건 (G2)
- 빌드 통과.
- Sparrow 재분석 시 해당 라인 LEAK.SYSTEM_INFORMATION 소멸.
- 신규 검출 0 — 로깅 추가가 새 결함(로거 null 역참조 등)을 만들지 않는지.

## 기본 처리 분류
- [ ] 진성 → 수정 (내부 로그 분리 + 일반화 메시지)
- [ ] 위양성 → 사유서 (내부 전용 로그 싱크·접근통제 근거)
- [ ] 보류 → 사유 (싱크가 외부인지 판단 불가 시; frontier-handoff)
