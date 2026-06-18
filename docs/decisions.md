# Decisions

인프라 layer 의 결정. airflow workload 결정은 `airflow-stack:docs/decisions.md`.

## 잠긴 결정

| # | 결정 | 근거 |
|---|---|---|
| L1 | ops-vm (공인) + worker-vm (사설) + mac-server (intermittent M1) | 항상성·노출·자원 매핑 |
| L2 | Tailscale (MagicDNS + ACL) | NAT 뒤 outbound-only fit, 노드 간 암호화 채널 |
| L3 | Caddy + Let's Encrypt | 자동 ACME, 검증된 패턴 |
| L4 | Postgres 16 on ops-vm — **공유 DB 서버**. 서비스별 DB/user 분리 | airflow 외 미래 서비스도 같은 인스턴스 공유. 신규 = 신규 DB + 신규 user (runbook 절차) |
| L5 | docker compose (호스트별 1) | k8s 도입 안 함, 단순함 우선 |
| L6 | M1 = launchd LaunchAgent | macOS 표준, colima 자동 시동 |
| L7 | 백업 안 함 (boot volume·앱 전부) | 인프라 disposable. **재고 트리거: stateful 신규 서비스 추가** |
| L8 | SSH 공개 폐지, 본인 IP /32 fallback | audit Critical 해소 |
| L9 | 호스트네임 ops-vm / worker-vm / mac-server | 역할 명시 |
| L10 | OCI 자원 균등 — A1.Flex 2 OCPU / 12 GB × 2 | Always Free 한도 (4 OCPU + 24 GB) 안 |
| L11 | 워커 → ops-vm = Tailscale 직결 HTTP | Tailscale 가 암호화 채널. cert 불필요, edge API 공인 노출 회피 |
| L12 | 공인 도메인 라벨 = `airflow` (`airflow.<your-domain>`) | 명확·직관 |
| L13 | self-hosted `registry:2` on ops-vm, docker named volume (부트 디스크 안) | 무료 hosted (GHCR/Docker Hub) 한도 초과 예상, OCI 안 자가호스트가 비용·네트워크·통제 모두 우위. mac 호스팅은 intermittent + 가정 uplink 보틀넥으로 부적합. block volume 분리는 미도입 — 디스크 모니터링 + GC 로 갈음, Always Free 한도 (부트 합 200 GB) 안에서 운영 (Linear BON-8) |
| L14 | 공개 repo 정책 — placeholder 강제 (도메인·공인 IP·tailnet 이름·home 경로) | git history 영구, 한 번 들어가면 회수 불가 |
| L15 | docker network 이름 = `nexus` (external) | 두 repo 결합점. nexus-prime 의 caddy/postgres/registry + airflow-stack 의 airflow 서비스 모두 join |
| L16 | OpenTofu IaC + 기존 리소스 전부 import | 코드 = 실제 환경 일치. drift 0 보장. 리소스 매트릭스 작음 (~15) |
| L17 | 기능 중심 디렉토리 layout (`compose/{기능}/` + `_hosts/` wrapper) | 호스트 disposable·기능 영속. scale·라이프사이클 분리 자연스러움 |
| L18 | 인스턴스 = immutable. 변경·복구 = destroy + create (in-place 변경 안 함) | minimal·disposable (L7) 와 같은 사상. drift 0, 변경 vs 복구 절차 통일, MTTR ≈ MTTC (capacity 잡는 시간). 데이터 손실 OK — airflow 메타 / registry storage 모두 disposable, lol-list 데이터는 Supabase 외부 |
| L19 | Neo4j Community on ops-vm. bolt :7687 tailnet IP bind, HTTP browser Caddy 경유 (`http://neo4j.internal`). heap 512m→1500m, pagecache 2g (~4GB RSS) | 그래프 데이터 모델 필요. Community 무료, 단일 노드 적합. ops-vm 12GB 공유 환경이므로 메모리 상한 명시. L7 (백업 없음) 동일 적용 — neo4j-data volume disposable |
| L20 | registry push/pull 주소 = `registry.internal:5000` (tailnet 직결, Caddy 우회) | Docker 는 포트 없는 호스트명에 443 시도 → ops-vm 443 은 공인 Caddy edge → broken TLS. `:80` 명시는 Caddy HTTP 우회였으나 hop 불필요 — tailnet IP:5000 직결로 통일. Caddy `http://registry.internal` 라우트 제거 (BON-128) |
| L21 | ops-vm docker 유지보수(registry retention+GC, build cache prune)는 **airflow DAG** 로 실행. systemd `registry-gc.{service,timer}` 폐지. ops edge worker 에 `docker.sock` 마운트, 유지보수 태스크는 **ops 큐 전용** | 운영성: airflow UI 에서 실행/로그/재시도 가시. registry·docker 데몬이 ops-vm 동일 호스트라 같은 worker 에서 `docker exec registry ...`+`builder prune` 가능. **docker.sock = 호스트 docker root 노출**이므로 ops 큐를 privileged 인프라 유지보수 전용으로 고정 — 일반 워크로드 라우팅 금지로 blast radius 한정. systemd 제거는 DAG 정상 동작 검증 후 (GC 공백 방지). DAG·sock 마운트 = airflow-stack |

## 재고 가능 결정

| # | 결정 / 현재 | 재고 트리거 | 마이그레이션 |
|---|---|---|---|
| R1 | Auth manager (Caddy 뒤 airflow `SimpleAuthManager`) | 다중 사용자 / RBAC, UI 노출 표면 확대 | `FabAuthManager` (airflow-stack 측 결정) |
| R2 | registry 외부 노출 X (tailnet IP bind only) | 외부 CI / 다른 노드에서 push 필요 | Caddy 뒤 `registry.<your-domain>` + basic auth |
| R3 | tofu state = 로컬 (`.tfstate` gitignore + password manager 백업) | 다중 운영자 / 협업 | OCI Object Storage backend (Linear BON-7) |
| R4 | **도입됨 (2026-05-27)**. Grafana + Prometheus + Loki + Promtail + Alertmanager + node_exporter×3 + statsd_exporter. `compose/monitoring/`. Grafana 자체 로그인. 대시보드는 provisioning (`grafana/dashboards/*.json`). cAdvisor 는 도입했다 제거 (2026-05-31): 이 호스트 docker API 조회 불가(`DockerVersion` 빈값)로 컨테이너 메트릭 미수집 — node_exporter/Loki 로 갈음 | — | — |
| R5 | **부분 도입됨**. MinIO on mac-server 가동 (`compose/minio/`). dbt-core / Metabase / Redpanda 미도입 — 트리거 시 도입 | data팀 표준 도구 학습 필요 | airflow worker image 에 `dbt-core+dbt-postgres` + Cosmos, 신규 schema 분리 (Linear BON-6) |
| R6 | oauth2-proxy 로 `*.internal` SSO — 미도입 | tailnet 다중 사용자 또는 internal 서비스 5+ | Caddy `forward_auth oauth2-proxy:4180`, GitHub OAuth (Linear BON-5) |

## airflow-stack 과의 cross-reference

- airflow workload 결정 (Airflow 3.2 / Edge Executor / `@task.docker` 등) = `airflow-stack:docs/decisions.md`
- airflow-stack:L20 (워커 → ops-vm Tailscale 직결) ↔ 본 repo L11 — 동일 결정의 두 측면
