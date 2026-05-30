# Tasks

인프라 작업 진행 상태. 큰 단위 (Phase) 기록. 사소한 갱신은 미기록.

## 현재 상태

**Phase 0 — 인프라 layer 분리 (2026-05-24 ~ 진행 중)**

airflow-stack 단일 repo 에서 인프라 분리 → nexus-prime 신규 repo. 운용/실행 환경 분리 (`airflow-stack:tasks.md` Phase 9 와 연동).

배포 시점은 후순위 — 일단 구성만, 현 환경 무변경.

### 작업 단계

- [x] repo init + 디렉토리 골격 (`README.md`, `.gitignore`)
- [x] `compose/{caddy,postgres,registry}/` 분리 작성 (postgres = 공유 DB 정체성)
- [x] `compose/_hosts/ops-vm.yml` wrapper (include + 통합 env)
- [x] `hosts/{ops,worker,mac}-vm/` 셋업 분리 (host-setup.sh + README + LaunchAgent plist)
- [x] `ssh/config.example`
- [x] `docs/` 초기 문서 (architecture / setup / runbook / decisions / tasks)
- [x] `tofu/` OCI 리소스 코드 (provider + VCN + NSG + instances + volumes + outputs)
- [x] `tofu import` 실행 — 현 환경 OCID 매핑, `plan` drift 0 확인
- [x] airflow-stack 측 정리 (compose 가벼워짐, scripts/Caddyfile 삭제, docs 갱신)
- [x] 검증 — 현 환경 동작 확인, tofu plan drift 0

## 미래

- registry retention 자동화 (cron + `registry garbage-collect`)
- oauth2-proxy 로 `*.internal` SSO (R6)
- dbt-core (airflow worker image + Cosmos) — R5 잔여
- tofu state remote backend — R3 트리거 시
- block volume 분리 — registry 디스크 점유가 부트 위협하면
