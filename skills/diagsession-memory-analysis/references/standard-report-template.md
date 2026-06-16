# DiagSession Memory Analysis Report

Use these exact headings when a machine-checkable analysis report is required.

## 1. Assumptions and Snapshot Order

- State snapshot ordering and whether it was user-provided or inferred.
- State repeated action, repeat count, entry point, and related code context.

## 2. Snapshot Mapping

| Snapshot | Source | ArchiveEntry | Report |
| --- | --- | --- | --- |
| Snapshot 1 |  |  |  |
| Snapshot 2 |  |  |  |

## 3. Leak Candidates by Confidence

| Rank | Candidate | Confidence | Why it matters |
| --- | --- | --- | --- |

## 4. Evidence Table

| Type | Size trend | Count trend | Snapshot evidence | Notes |
| --- | --- | --- | --- | --- |

## 5. Code Areas to Inspect First

- List likely files, classes, services, view models, views, caches, event subscriptions, timers, and long-lived collections.

## 6. Confirmation and Falsification Steps

- List concrete checks that would confirm or disprove each retention hypothesis.

## 7. Evidence Limitations

- Separate managed heap evidence from native memory, handle, COM, GDI, WPF image, and allocation-stack evidence.

## 8. Follow-up Fix Session Handoff

- Provide a compact handoff summary that another coding session can use without re-reading the full report.

