# addsim-xml-report 사용 가이드

AddSIM(국방과학연구소 체계모의환경)의 BSM/플레이어/컴포넌트 XML 정의 파일을 **항상 동일한 포맷**의
자립형 HTML 보고서로 분석하는 스킬. 범용 버전은 [`xml-report`](xml-report-usage.md)이며 두 스킬은
동일한 분석 엔진을 공유한다(AddSIM 버전은 도메인 매핑·배경지식이 추가된 특화판).

## 왜 이 스킬인가

LLM에게 XML 분석을 자유롭게 시키면 계층(뎁쓰) 정보가 누락되고 매번 다른 포맷이 나와 결과를
신뢰하기 어렵다. 이 스킬은 역할을 분리한다:

- 구조 추출·계층·속성·통계·HTML 생성 → **결정적 PowerShell 스크립트** (같은 입력이면 항상 같은 보고서)
- LLM의 역할 → 스크립트 실행 + 보고서 **마지막 섹션**의 "문서 해석"(모델 생성 배지 표시) 작성뿐

신뢰성 장치: 파싱/렌더링 요소 수 자동 대조, SHA-256 해시, 미분류 요소 명시(조용한 누락 금지),
"원본 추출" vs "모델 생성" 배지 구분.

## 요구사항

- Windows PowerShell 5.1+ (Windows 10/11 기본). 외부 모듈/인터넷 불필요 — 폐쇄망 사용 가능.

## 호출

repo 루트에서 Claude Code를 시작한 경우(클론 후 바로):

```text
/addsim-xml-report C:\data\bsm\FighterBSM.xml
```

plugin으로 설치한 경우:

```text
/peace-skillbank:addsim-xml-report C:\data\bsm\FighterBSM.xml
```

에이전트 없이 수동 실행:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "skills\addsim-xml-report\scripts\Analyze-AddsimXml.ps1" -Path "C:\data\bsm" -OutDir "C:\reports"
```

## 산출물

| 파일 | 내용 |
|---|---|
| `<이름>.report.html` | 고정 8섹션 보고서: 파일정보 → 검증 요약 → 계층 트리(뎁쓰 배지) → 뎁쓰별 요약 → 속성 상세 → 커넥션 → 인벤토리/매핑 상태 → 문서 해석(모델 생성, 항상 마지막) |
| `<이름>.data.json` | 분석 다이제스트 — LLM이 해석을 쓸 때 읽는 근거 파일 |
| `index.html` | 폴더 처리 시 전체 목록(파싱 실패 파일도 오류와 함께 기록) |

## 매핑 캘리브레이션

첫 실행에서 콘솔/보고서에 **미분류 요소** 목록이 나온다. 이는 오류가 아니라 캘리브레이션 신호다.
각 요소의 한글 라벨을 확정해 `skills/addsim-xml-report/config/mapping.json`의 `labels`에 추가하면
다음 보고서부터 라벨이 표시된다. 커넥션 성격 요소는 `connectionNames`, 연결 출발/도착 속성명은
`endpointAttrNames`에 추가. 몇 번 반복하면 매핑이 현장의 실제 AddSIM 스키마에 수렴한다.

## 폐쇄망 반입

`skills/addsim-xml-report` 폴더 전체를 USB로 반입해 대상 프로젝트의 `.claude\skills\` 아래에
복사하면 끝. 세부 절차는 폴더 안 `README-INSTALL.md` 참고. 반입 직후 `assets\samples`(합성
데이터)로 자가 테스트 1회를 권장.

## 프라이버시 주의

보고서와 `data.json`에는 원본 XML의 요소명·속성값이 그대로 들어간다. **분석 산출물을 망 밖으로
공유하지 않는다.** 이 저장소에는 실데이터/실스키마를 커밋하지 않는다(`assets/samples`는 합성 데이터).
동봉된 `references/addsim-structure.md`는 공개 학술논문 기반 배경지식만 담고 있다.
