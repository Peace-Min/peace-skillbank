# addsim-xml-report 반입/설치 안내 (폐쇄망)

## 요구사항

- Windows + PowerShell 5.1 이상 (Windows 10/11 기본 탑재)
- 인터넷/외부 모듈 불필요. 보고서 HTML도 외부 리소스 없이 단독으로 열림.

## 설치

1. 이 폴더(`addsim-xml-report`) 전체를 폐쇄망 PC로 반입.
2. 내부망 Claude Code(또는 에이전트)의 스킬 폴더에 복사:
   - 프로젝트 단위: `<프로젝트>\.claude\skills\addsim-xml-report\`
   - 사용자 단위: `%USERPROFILE%\.claude\skills\addsim-xml-report\`
3. 에이전트 없이 수동으로도 사용 가능(아래 빠른 시작).

## 빠른 시작 (자가 테스트)

```
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Analyze-AddsimXml.ps1" -Path ".\assets\samples" -OutDir ".\selftest-reports"
```

`selftest-reports\index.html`을 브라우저로 열어 보고서 3종이 정상 생성되는지 확인.
(assets\samples의 XML은 구조 시연용 합성 데이터이며 실제 AddSIM 데이터가 아님)

## 실사용

```
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Analyze-AddsimXml.ps1" -Path "<XML 파일 또는 폴더>" -OutDir "<출력폴더>"
```

첫 실행 후 콘솔/보고서에 나오는 **미분류 요소**들의 한글 라벨을 `config\mapping.json`의 `labels`에 추가하면
다음 보고서부터 라벨이 표시된다(캘리브레이션). 커넥션 성격의 요소는 `connectionNames`에,
연결 출발/도착 속성명은 `endpointAttrNames`에 추가.

전체 워크플로(요약문 주입 포함)는 `SKILL.md` 참조.
