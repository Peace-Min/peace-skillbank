# xml-report 사용 가이드

임의의 XML을 **항상 동일한 포맷**의 자립형 HTML 보고서로 분석하는 범용 스킬. 특정 스키마에
의존하지 않는다. AddSIM 특화판은 [`addsim-xml-report`](addsim-xml-report-usage.md) — 두 스킬은
동일한 분석 엔진을 공유한다.

## 왜 이 스킬인가

LLM에게 XML 분석을 자유롭게 시키면 계층(뎁쓰) 정보가 누락되고 매번 다른 포맷이 나와 결과를
신뢰하기 어렵다. 이 스킬은 구조 추출·계층·속성·통계·HTML 생성을 전부 결정적 PowerShell
스크립트가 수행하고, LLM은 보고서 **마지막 섹션**의 "문서 해석"(모델 생성 배지)만 작성한다.

신뢰성 장치: 파싱/렌더링 요소 수 자동 대조, SHA-256 해시, 미분류 요소 명시(조용한 누락 금지),
"원본 추출" vs "모델 생성" 배지 구분. 표가 행 수 제한으로 잘리면 생략 건수를 명시하며, 계층
트리에는 어떤 경우에도 전체 요소가 표시된다.

## 요구사항

- Windows PowerShell 5.1+ (Windows 10/11 기본). 외부 모듈/인터넷 불필요 — 폐쇄망 사용 가능.

## 호출

repo 루트에서 Claude Code를 시작한 경우(클론 후 바로):

```text
/xml-report C:\configs\deploy.xml
```

plugin으로 설치한 경우:

```text
/peace-skillbank:xml-report C:\configs\deploy.xml
```

에이전트 없이 수동 실행:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "skills\xml-report\scripts\Analyze-Xml.ps1" -Path "C:\configs" -OutDir "C:\reports"
```

## 산출물

| 파일 | 내용 |
|---|---|
| `<이름>.report.html` | 고정 8섹션 보고서: 파일정보 → 검증 요약 → 계층 트리(뎁쓰 배지) → 뎁쓰별 요약 → 속성 상세 → 커넥션 → 인벤토리/매핑 상태 → 문서 해석(모델 생성, 항상 마지막) |
| `<이름>.data.json` | 분석 다이제스트 — LLM이 해석을 쓸 때 읽는 근거 파일 |
| `index.html` | 폴더 처리 시 전체 목록(파싱 실패 파일도 오류와 함께 기록) |

## 도메인 매핑 (반복 사용 시 권장)

같은 종류의 XML을 반복 분석한다면 `skills/xml-report/config/mapping.json`을 복사해 도메인별
매핑을 만들고 `-MappingPath`로 지정한다. 매핑으로 지정 가능한 것: 요소 한글 라벨(`labels`),
루트 요소명 키워드 → 문서유형(`docTypes`), 커넥션으로 취급할 요소명(`connectionNames`),
연결 출발/도착 속성명(`endpointAttrNames`), 보고서 브랜드 문구(`brand`).

## 프라이버시 주의

보고서와 `data.json`에는 원본 XML의 요소명·속성값이 그대로 들어간다. 민감한 XML의 분석
산출물을 외부로 공유하지 않는다. 이 저장소에는 분석 산출물을 커밋하지 않는다.
