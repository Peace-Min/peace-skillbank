# dmp-triage — 폐쇄망용 .DMP 분석 마스터 CLI

작업관리자/procdump 등이 만든 Windows 프로세스 덤프(.dmp)를 **폐쇄망에서, 의존성 없이** 분석해
LLM이 바로 읽을 수 있는 압축 리포트(`report.md`)를 만든다.

핵심 원칙: **LLM에게 덤프 원본을 주지 않는다.** 결정적 도구(cdb + 이 CLI)가 수십 KB 리포트를
만들고, LLM은 그 리포트만 읽고 추론한다. (21.9GB 덤프를 LLM이 바이트 스캔 → 5시간 실패.
같은 덤프를 이 파이프라인으로 → 수 분.)

## 빠른 시작

```powershell
# 1) 환경 점검 + 덤프 즉석 판정 (cdb 없어도 동작)
powershell -NoProfile -ExecutionPolicy Bypass -File .\dmp-triage.ps1 check -Dump C:\dumps\app.dmp

# 2) 전체 분석 → report.md
powershell -NoProfile -ExecutionPolicy Bypass -File .\dmp-triage.ps1 analyze -Dump C:\dumps\app.dmp
```

출력 폴더(`dmp-triage-out\<이름>-<시각>\`):

| 파일 | 내용 |
|---|---|
| `report.md` | **LLM에게 줄 파일.** 사전판정 + !analyze 요약 + 스레드별 CPU + 고유 네이티브 스택 + !locks + .NET !threads/!syncblk + 중복 제거된 관리 스택 그룹 |
| `modules.csv` | 전체 모듈 인벤토리 (베이스주소/크기/타임스탬프/경로) |
| `raw\native.log`, `raw\managed.log` | cdb 원시 출력 (LLM이 추가로 요구할 때만 발췌 제공) |

## 3단계 파이프라인

1. **사전 판정 (순수 PowerShell, 의존성 0)** — 덤프 헤더/스트림 디렉터리/스레드/모듈/메모리
   테이블을 직접 파싱. 표준 minidump 여부(버전 하위워드 0xA793), 행 vs 크래시(ExceptionStream
   유무), 원본 OS 빌드, 스레드 수와 **레지스터 컨텍스트 저장 여부**, 메인 모듈, 캡처된 메모리
   총량을 즉시 출력. cdb가 아직 없어도 이 단계만으로 "무슨 덤프인지"는 확정된다.
2. **네이티브 트랙 (cdb)** — `!analyze -v -hang`(크래시 덤프면 자동으로 `-v` + `.ecxr`),
   `!runaway`, `!uniqstack`(97개 스레드 → 고유 스택 몇 개로 압축), `!locks`, `lm`.
3. **관리 코드 트랙 (cdb + SOS)** — WPF/WinForms 등 .NET 앱이면 `!threads`, `!syncblk`
   (관리 락 데드락 증거), `~*e !clrstack`. **관리 스택은 PDB가 없어도 덤프 안의 어셈블리
   메타데이터로 메서드 이름까지 전부 나온다.** CLI가 동일 스택을 그룹으로 묶어 출력.

## 폐쇄망 반입 절차

1. 인터넷 PC에서: `tools\get-debuggers.ps1` 실행 (winget으로 WinDbg 설치 후 cdb 일체를
   `bin\debuggers\`에 복사. ~100MB)
2. `dmp-triage.ps1 package` → USB 반입용 zip 생성
3. 폐쇄망 PC에서: 압축 해제 후 바로 `analyze`. 설치·레지스트리·관리자 권한 불필요
   (Debugging Tools는 xcopy-포터블). 네트워크 심볼 접근은 `-netsyms:no`로 원천 차단됨.

폐쇄망 내 다른 PC에 Windows SDK나 WinDbg가 이미 있다면 그 `Debuggers\x64` 폴더를
`bin\debuggers\`로 복사하는 것만으로도 된다 (반출입 절차 불필요).

## 자주 겪는 문제

- **SOS/DAC 버전 불일치** (`Failed to load data access DLL` 경고가 리포트에 표시됨):
  덤프를 뜬 원본 머신의 `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\` 에서
  `mscordacwks.dll`, `sos.dll`, `clr.dll` 을 폴더에 복사해 와서 `-SupportFiles <폴더>` 로 재실행.
- **앱 자체(비관리) 코드의 함수명이 안 나옴**: 네이티브 코드 심볼화는 빌드가 일치하는 PDB가
  필요. 원본 머신의 exe+PDB를 `-SupportFiles` 폴더에 넣으면 된다. OS DLL은 PDB 없어도
  export 테이블로 `ntdll!NtWaitForSingleObject` 수준까지 나오므로 행 분석에는 대부분 충분.
- **.NET Core/5+ 앱**: `.loadby sos coreclr`용 SOS는 별도(`dotnet-sos`)가 필요. 현재 버전은
  .NET Framework(WPF/WinForms 4.x) 우선.

## LLM 활용 가이드 (폐쇄망 LLM에게 이렇게 지시)

> 첨부한 report.md는 Windows 프로세스 덤프의 자동 분석 결과다.
> 1) 행이면 어떤 스레드 그룹이 무엇을 기다리는지, !syncblk/!locks에서 락 보유-대기 관계를 찾아
> 데드락/블로킹 체인을 설명하라. 2) 크래시면 예외 코드와 스택으로 원인을 설명하라.
> 3) 부족한 정보가 있으면 raw 로그의 어느 섹션이 필요한지 특정해서 요청하라.
