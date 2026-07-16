# Sparrow Static Analysis Helper

일반 사용자는 이 폴더에서 아래 파일만 실행하면 됩니다.

```text
00-Run-Sparrow-GUI.cmd
```

## 빠른 사용

1. `00-Run-Sparrow-GUI.cmd`를 실행합니다.
2. GUI에서 대상 솔루션/폴더 또는 Sparrow XLS를 선택합니다.
3. Track A/B/C 항목을 체크한 뒤 실행합니다.

## 폴더 의미

- `00-Run-Sparrow-GUI.cmd`: 사용자용 실행 파일입니다.
- `tools/`: GUI와 내부 자동화 도구가 들어 있습니다. 일반 사용자는 직접 들어갈 필요가 거의 없습니다.
- `references/`: Sparrow 체커 가이드와 Track C LLM 요청 템플릿입니다.
- `SKILL.md`: Codex/Claude 같은 에이전트가 읽는 스킬 정의입니다.
- `HANDOFF.md`: 개발 이력/인수인계 메모입니다.

GUI 사용 기준으로는 `00-Run-Sparrow-GUI.cmd`만 기억하면 됩니다.
