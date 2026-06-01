# Tasks

작업 상태·백로그는 **Linear 에서 관리**한다 (project nexus-prime, team BON). URL 등 식별자는 로컬 Claude 메모리 참조.

- 가변 작업(todo → 진행 → 완료) = Linear 이슈
- 결정 기록(왜)은 `docs/decisions.md` 에 유지
- 완료 이력은 git commit 참조

**Phase 0 — 인프라 layer 분리** (2026-05-24 ~): Linear 마일스톤으로 추적. airflow-stack 단일 repo 에서 인프라 분리 → nexus-prime 신규 repo.
