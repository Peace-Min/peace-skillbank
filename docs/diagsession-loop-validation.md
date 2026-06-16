# DiagSession loop validation

이 문서는 실제 `.diagsession` 또는 `.gcdump` 파일로 `diagsession-memory-analysis` 스킬이 end-to-end로 동작하는지 검증하는 사람용 절차다.

실제 dump/session 파일은 민감할 수 있으므로 저장소에 커밋하지 않는다. 이 저장소는 `*.diagsession`, `*.gcdump`, `out/`을 gitignore 처리한다.

## 검증 범위

`tests/run-diagsession-analysis-loop.ps1`는 다음을 확인한다.

1. 입력 `.diagsession` 또는 `.gcdump` 파일을 찾는다.
2. `.diagsession` 내부 `.gcdump` entry를 추출한다.
3. `dotnet-gcdump report`를 실행한다.
4. `MANIFEST.txt`, `LLM_MEMORY_INPUT.txt`, `reports/`를 생성한다.
5. `MANIFEST.txt` 기준 snapshot 수, report 수, gcdump 경로 존재 여부를 검증한다.
6. LLM에 넘길 `LLM_REQUEST.md`를 만든다.
7. 모델 응답이 있으면 표준 리포트 heading contract를 검증한다.

## 준비물

- Windows PowerShell 5.1 이상 또는 PowerShell 7 이상
- `.diagsession` 또는 `.gcdump` 파일
- `dotnet-gcdump`

`dotnet-gcdump`가 PATH에 없으면 `-ToolPath`로 위치를 지정한다.

## 1. 추출/파싱/LLM 입력 생성 검증

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-diagsession-analysis-loop.ps1 `
  -InputPath C:\dumps\leak-test.diagsession `
  -RepeatedAction "장비 목록 새로고침" `
  -RepeatCount "30회" `
  -StartPoint "DeviceRefreshService.RefreshAsync" `
  -RelatedCode "DeviceListViewModel, DeviceCache"
```

성공하면 `out/diagsession-analysis-loop/<run-id>/` 아래에 다음 파일이 생긴다.

```text
extract/MANIFEST.txt
extract/LLM_MEMORY_INPUT.txt
extract/reports/
LLM_REQUEST.md
RUN_SUMMARY.md
```

`RUN_SUMMARY.md`에서 snapshot 수, report 수, archive entry를 확인한다.

## 2. 수동 LLM 응답 검증

1. 생성된 `LLM_REQUEST.md`를 Claude, Codex, 또는 로컬 LLM에 그대로 입력한다.
2. 응답을 `MODEL_RESPONSE.md`로 저장한다.
3. 다음 명령으로 리포트 규격을 검증한다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\validate-diagsession-response.ps1 `
  -ResponsePath .\out\diagsession-analysis-loop\<run-id>\MODEL_RESPONSE.md
```

검증은 다음 heading이 모두 있는지 확인한다.

```text
# DiagSession Memory Analysis Report
## 1. Assumptions and Snapshot Order
## 2. Snapshot Mapping
## 3. Leak Candidates by Confidence
## 4. Evidence Table
## 5. Code Areas to Inspect First
## 6. Confirmation and Falsification Steps
## 7. Evidence Limitations
## 8. Follow-up Fix Session Handoff
```

## 3. 로컬 LLM 자동 호출

로컬 LLM CLI가 stdin 입력을 받을 수 있으면 `-LlmExecutable`과 `-LlmArgumentLine`을 사용한다.

Ollama 예:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-diagsession-analysis-loop.ps1 `
  -InputPath C:\dumps\leak-test.diagsession `
  -RepeatedAction "장비 목록 새로고침" `
  -RepeatCount "30회" `
  -StartPoint "DeviceRefreshService.RefreshAsync" `
  -LlmExecutable ollama `
  -LlmArgumentLine "run llama3.1:8b"
```

Claude CLI가 print mode를 지원하는 환경에서는 같은 방식으로 연결할 수 있다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-diagsession-analysis-loop.ps1 `
  -InputPath C:\dumps\leak-test.diagsession `
  -LlmExecutable claude `
  -LlmArgumentLine "-p"
```

모델 호출까지 성공하면 `MODEL_RESPONSE.md`와 `RESPONSE_VALIDATION.md`가 생성된다.

## 4. 반복 검증 루프

스킬이나 프롬프트를 수정한 뒤 같은 실제 `.diagsession` 파일로 아래 루프를 반복한다.

1. `run-diagsession-analysis-loop.ps1` 실행
2. `RUN_SUMMARY.md`에서 snapshot/report/gcdump 검증 결과 확인
3. `LLM_REQUEST.md`를 모델에 전달
4. `MODEL_RESPONSE.md` 저장
5. `validate-diagsession-response.ps1` 실행
6. 누락 heading, 잘못된 snapshot ordering, 불명확한 handoff summary가 있으면 스킬 지침이나 prompt/template를 보완

## 실패 해석

- `dotnet-gcdump` missing: `dotnet tool install --global dotnet-gcdump` 또는 `-ToolPath`를 사용한다.
- `No .gcdump files were found`: 해당 `.diagsession`에 managed memory snapshot이 없다.
- `Expected at least 2 snapshot(s)`: leak before/after 비교에 필요한 snapshot 수가 부족하다. 단일 snapshot 테스트는 `-MinSnapshotCount 1`로 실행한다.
- Response contract 실패: 모델 응답이 표준 heading을 지키지 않았다. `LLM_REQUEST.md`의 Required Output Contract를 그대로 전달했는지 확인한다.
