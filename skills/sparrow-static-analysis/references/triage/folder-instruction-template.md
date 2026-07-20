# {{CHECKER_KEY}} — {{CHECKER_NAME}} 작업지침

- 대상 건수: {{COUNT}}  |  심각도: {{SEVERITY}}
- 이 폴더(`requests/{{CHECKER_KEY}}/`)의 각 `{ID}_{{CHECKER_KEY}}.md` 요청을 순서대로 처리한다.
{{FALLBACK_NOTE}}
## (공통) 처리 정책

{{COMMON_POLICY}}

## 체커별 의무 — {{CHECKER_KEY}}

{{CHECKER_MANDATE}}

## 참고

- 각 요청 md에 체커 가이드 전문이 포함되어 있다. **룰은 요청 md에서, 소스는 실제 파일에서** 확인한다.
- 파일 접근이 가능하면 실제 파일을 열어 흐름을 확인한 뒤 고친다. 접근 불가는 건너뛸 사유가 아니며, 스니펫 범위에서 안전한 최소 patch를 낸다(`패치 제안`).
