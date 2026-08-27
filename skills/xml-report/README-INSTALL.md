# xml-report 설치 안내

임의의 XML을 뎁쓰(계층)별로 전수 분석해 항상 동일한 포맷의 자립형 HTML 보고서를 만드는 범용 스킬.
(AddSIM 특화 버전은 `addsim-xml-report` — 동일 엔진에 도메인 매핑·배경지식이 추가된 스킬)

## 요구사항

- Windows + PowerShell 5.1 이상 (Windows 10/11 기본 탑재)
- 인터넷/외부 모듈 불필요. 보고서 HTML도 외부 리소스 없이 단독으로 열림. 폐쇄망 사용 가능.

## 설치

이 폴더(`xml-report`) 전체를 스킬 폴더에 복사:

- 프로젝트 단위: `<프로젝트>\.claude\skills\xml-report\`
- 사용자 단위: `%USERPROFILE%\.claude\skills\xml-report\`

## 빠른 시작 (자가 테스트)

```
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Analyze-Xml.ps1" -Path ".\assets\samples" -OutDir ".\selftest-reports"
```

## 실사용

```
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Analyze-Xml.ps1" -Path "<XML 파일 또는 폴더>" -OutDir "<출력폴더>"
```

같은 종류의 XML을 반복 분석한다면 `config\mapping.json`을 복사해 도메인별 매핑(요소 한글 라벨,
문서유형, 커넥션 요소, 브랜드 문구)을 만들고 `-MappingPath`로 지정하면 보고서 가독성이 올라간다.
전체 워크플로(요약문 주입 포함)는 `SKILL.md` 참조.
