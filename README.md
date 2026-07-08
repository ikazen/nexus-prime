# nexus-prime

인프라 layer repo. OCI 2 노드(ops-vm, worker-vm) + M1 mac-server. Tailscale 메쉬 + Caddy edge + Postgres 공유 DB + self-hosted registry.
워크로드(Airflow)는 `airflow-stack` repo 에서 관리.

## 진입점

- 신규 셋업: `docs/setup.md`
- 일상 운영 (인프라): `docs/runbook.md`
- **다른 repo 에서 인프라 자원 사용 / 신규 서비스 개발·배포**: `docs/dev-guide.md` (서비스 인벤토리 + 자원 메뉴)
- 토폴로지: `docs/architecture.md`
- 결정 이력: `docs/decisions.md`

## 리포지토리 구조

```
tofu/          OCI 리소스 (OpenTofu). terraform.tfvars / *.tfstate 는 gitignored — 로컬에만 보관
compose/       기능별 docker compose
  _hosts/      호스트별 wrapper (ops-vm.yml, mac-server.yml, worker-vm.yml). 호스트별 env 는 <host>.env
  caddy/       Caddyfile — 외부/내부 라우팅 진입점
  postgres/    pgvector/pgvector:pg16. nexus network 바인드
  registry/    registry:2. tailnet IP 바인드. retention.py + registry-gc.sh
  registry-ui/ joxit/docker-registry-ui. registry-ui.internal
  adminer/     adminer. adminer.internal (DB 브라우저)
  dnsmasq/     *.internal → tailnet IP 해석. host network mode
  neo4j/       neo4j:5. bolt :7687 tailnet 바인드. neo4j.internal
  minio/       MinIO. mac-server 전용 (ops-vm.yml 미포함)
  omnigent/    meta-harness 에이전트 서버. worker-vm 배치, tailnet 전용 노출 (L23)
  monitoring/  Prometheus / Grafana / Loki / Promtail / Alertmanager / statsd-exporter / node-exporter
hosts/         호스트별 부트스트랩
  ops-vm/      host-setup.sh (swap·Docker·nexus network) + registry-gc systemd unit
  worker-vm/   host-setup.sh (swap·Docker·node_exporter·promtail)
  mac-server/  README (brew·colima·launchd 절차). launchd/ 에 plist
scripts/       deploy-ops-vm.sh / deploy-worker-vm.sh / status.sh
ssh/           config.example (tailnet alias)
docs/          architecture / decisions / dev-guide / runbook / setup (작업 추적은 GitHub Issues, repo 내 tasks.md 없음)
```

## 인프라 개요

- ops-vm: 공인 IP 보유. Caddy / Postgres / Registry / Registry UI / Neo4j / Adminer / dnsmasq / Monitoring 컨테이너 실행. `nexus` docker network 허브
- worker-vm: 사설, Tailscale 전용. Airflow edge worker + node_exporter + promtail + omnigent(meta-harness, L23 — 위치·노출 격리로 ops-vm 에서 이동)
- mac-server: M1, intermittent. MinIO + Colima + Airflow edge worker. launchd LaunchAgent 로 자동시동
- 네트워크: 노드 간 = Tailscale (MagicDNS `*.internal` → ops-vm tailnet IP). 외부 ingress = ops-vm :443 → Caddy

## 결합점 (다른 repo 에서 참조)

| 자원 | 주소 | 비고 |
|---|---|---|
| docker network | `nexus` (external) | `networks: { nexus: { external: true } }` |
| Postgres | `postgres:5432` | nexus 안. pgvector 포함. 서비스별 DB/user 분리 |
| Registry | `registry.internal:5000` | HTTP tailnet 직결. insecure-registries 등록 필요 |
| MinIO S3 | `http://minio.internal` | tailnet. Caddy → mac-server:9000 |
| statsd-exporter | `statsd-exporter:9125/udp` | nexus 안. Airflow 메트릭 push |
| Neo4j | `neo4j:7474` (HTTP) / `<OPS_TAILNET_IP>:7687` (bolt) | browser: `http://neo4j.internal`. bolt tailnet 직결 |
| Loki | `<OPS_TAILNET_IP>:3100` | Promtail push 수신 |
| omnigent | `http://agent.internal` | tailnet 전용, worker-vm 배치 (L23) |

## 주요 작업 흐름

### 배포 (ops-vm 변경)

```bash
git push
bash scripts/deploy-ops-vm.sh    # git pull + alertmanager.yml scp + dnsmasq 재빌드 + compose up -d
```

alertmanager.yml 은 Discord webhook URL 포함 → gitignored. 배포 스크립트가 로컬 파일 scp.

### 배포 (worker-vm 변경)

```bash
git push
bash scripts/deploy-worker-vm.sh    # git pull + worker-vm.enc.env 복호화 + compose up -d
```

### 인스턴스 재설치 (L18 — 변경/복구 모두 동일)

전체 절차 (Airflow 중단 → destroy/apply → 전체 노드 재가입 → 서비스 재시작): `docs/runbook.md`

### 신규 서비스 추가

1. `compose/<svc>/compose.yml` 작성 — `networks: { nexus: { external: true } }` 필수 (ops-vm 배치 시. worker-vm 은 nexus network 없음, `docs/dev-guide.md` 참조)
2. 배치 호스트의 `compose/_hosts/<host>.yml` include 한 줄 추가
3. Caddyfile 에 내부(`http://<svc>.internal`) 또는 외부(`{$SVC_DOMAIN}`) 블록 추가
4. Postgres DB/user 필요 시: `docs/dev-guide.md` "Postgres DB 발급" 절차

### Postgres DB 발급

```bash
ssh ops-vm
docker exec -it postgres psql -U postgres -c "CREATE DATABASE <db>;"
docker exec -it postgres psql -U postgres -c "CREATE USER <user> WITH PASSWORD '<pw>';"
docker exec -it postgres psql -U postgres -c "GRANT ALL ON DATABASE <db> TO <user>;"
docker exec -it postgres psql -U postgres -d <db> -c "GRANT ALL ON SCHEMA public TO <user>;"
```

cross-DB read-only 접근이 필요하면 `docs/dev-guide.md` "Postgres read-only role 발급" 참조.

## 운영 명령 패턴

```bash
# ops-vm 컨테이너 명령 (항상 이 형식 사용)
docker compose -f compose/_hosts/ops-vm.yml --env-file compose/_hosts/ops-vm.env <subcommand>

# worker-vm 컨테이너 명령
docker compose -f compose/_hosts/worker-vm.yml --env-file compose/_hosts/worker-vm.env <subcommand>

# 현황 한 방 확인
bash scripts/status.sh

# Registry GC 수동 실행
sudo systemctl start registry-gc.service

# Registry retention 미리보기
python3 compose/registry/retention.py --registry-url http://<ops-tailnet-ip>:5000 --keep 5 --dry-run

# Prometheus 타겟 확인
docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/targets' | \
  python3 -c "import json,sys; [print(t['labels'].get('job'), t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"
```

## env / secrets 위치

| 파일 | 내용 | 관리 |
|---|---|---|
| `compose/_hosts/ops-vm.env` | POSTGRES_*, OPS_TAILNET_IP, AIRFLOW_DOMAIN, GRAFANA_*, WORKER_TAILNET_IP, MAC_TAILNET_IP | gitignored, ops-vm 로컬 |
| `compose/_hosts/worker-vm.env` | OMNIGENT_*, OPS_TAILNET_IP, WORKER_TAILNET_IP | gitignored, worker-vm 로컬. SOPS `worker-vm.enc.env` 로 관리 |
| `compose/monitoring/alertmanager.yml` | Discord webhook URL | gitignored, 배포 시 scp |
| `tofu/terraform.tfvars` | OCI OCID / API key 경로 / SSH 공개키 | gitignored, 로컬 |
| `tofu/terraform.tfstate` | OCI 리소스 상태 | gitignored, password manager 백업 |

`.env.example` / `.tfvars.example` 만 commit. 실제 값은 git 에 절대 노출하지 않는다.

## placeholder 정책 (공개 repo)

다음 값은 코드·문서 어디에도 평문 금지. placeholder 로 대체:

- 도메인: `<your-domain>`
- 공인 IP: `<ops-vm-public-ip>`
- tailnet IP: `<OPS_TAILNET_IP>`, `<WORKER_TAILNET_IP>`, `<MAC_TAILNET_IP>`
- tailnet 이름: `<tailnet>.ts.net`
- home 경로/사용자명: `<your-username>`, `~/<path>`

커밋 전 pre-commit hook 이 검사한다 (`.claude/settings.local.json` 의 훅 목록 확인).

## 결정 요약 (핵심만)

- **L5**: k8s 없음 — docker compose, 단순함 우선
- **L7**: 백업 없음 — 인프라 disposable. stateful 신규 서비스 추가 시 재고
- **L13**: registry = ops-vm 부트 디스크 안 docker named volume. GC + 모니터링으로 관리
- **L14**: 공개 repo — placeholder 강제, git history 영구
- **L15**: docker network = `nexus` (external) — 두 repo 결합점
- **L16**: OpenTofu IaC, 기존 리소스 전부 import, drift 0
- **L18**: 인스턴스 immutable — 변경/복구 = destroy + create
- **L23**: omnigent 위험을 노출×위치×권한 곱으로 보고 세 축 인하 (공개→tailnet, ops-vm→worker-vm, 최소권한)

전체 결정: `docs/decisions.md`

## 인프라 자원 조회

다른 repo 개발 중 인프라 자원·결합점·절차 질문 시 → `infra-lookup` 에이전트 먼저 사용. 직접 파일 탐색보다 빠름.

## GitHub Issues

이슈 상태 기준 / 댓글 규칙은 `~/.claude/CLAUDE.md` 참조.
