# nexus-prime

OCI 2 노드 + M1 1 노드 인프라 layer. Tailscale 메쉬, Caddy edge, Postgres 공유 DB, self-hosted Docker registry.

워크로드 layer 는 별도 repo. Airflow workload = `airflow-stack`.

## 디렉토리

- `tofu/` — OCI 리소스 (OpenTofu)
- `compose/` — 기능별 docker compose
  - `caddy/` · `postgres/` · `registry/` — 인프라 컨테이너
  - `_hosts/` — 호스트별 wrapper (include + external network)
- `hosts/` — 호스트별 셋업 (host-setup.sh, README, .env.example)
- `ssh/` — tailnet 호스트 alias
- `docs/` — architecture / setup / runbook / decisions / tasks

## 진입점

- 신규 셋업: `docs/setup.md`
- 일상 운영 (인프라): `docs/runbook.md`
- **다른 repo 에서 인프라 자원 사용 / 신규 서비스 개발·배포**: `docs/dev-guide.md` (서비스 인벤토리 + 자원 메뉴)
- 토폴로지: `docs/architecture.md`
- 결정 이력: `docs/decisions.md`

## 정책

- 공개 repo — 도메인·공인 IP·tailnet 실제 이름·home 경로는 placeholder 강제
- secrets (Fernet / JWT / Supabase token / Tailscale auth key 등) 는 외부 (password manager). repo 안엔 `.env.example` 만
- 백업 없음 (인프라 disposable). stateful 신규 서비스 추가 시 재고
