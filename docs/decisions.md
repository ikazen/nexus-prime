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
| L13 | self-hosted `registry:2` on ops-vm, docker named volume (부트 디스크 안) | 무료 hosted (GHCR/Docker Hub) 한도 초과 예상, OCI 안 자가호스트가 비용·네트워크·통제 모두 우위. mac 호스팅은 intermittent + 가정 uplink 보틀넥으로 부적합. block volume 분리는 미도입 — 디스크 모니터링 + GC 로 갈음, Always Free 한도 (부트 합 200 GB) 안에서 운영 |
| L14 | 공개 repo 정책 — placeholder 강제 (도메인·공인 IP·tailnet 이름·home 경로) | git history 영구, 한 번 들어가면 회수 불가 |
| L15 | docker network 이름 = `nexus` (external) | 두 repo 결합점. nexus-prime 의 caddy/postgres/registry + airflow-stack 의 airflow 서비스 모두 join |
| L16 | OpenTofu IaC + 기존 리소스 전부 import | 코드 = 실제 환경 일치. drift 0 보장. 리소스 매트릭스 작음 (~15) |
| L17 | 기능 중심 디렉토리 layout (`compose/{기능}/` + `_hosts/` wrapper) | 호스트 disposable·기능 영속. scale·라이프사이클 분리 자연스러움 |
| L18 | 인스턴스 = immutable. 변경·복구 = destroy + create (in-place 변경 안 함) | minimal·disposable (L7) 와 같은 사상. drift 0, 변경 vs 복구 절차 통일, MTTR ≈ MTTC (capacity 잡는 시간). 데이터 손실 OK — airflow 메타 / registry storage 모두 disposable, lol-list 데이터는 Supabase 외부 |

## 재고 가능 결정

| # | 결정 / 현재 | 재고 트리거 | 마이그레이션 |
|---|---|---|---|
| R1 | Auth manager (Caddy 뒤 airflow `SimpleAuthManager`) | 다중 사용자 / RBAC, UI 노출 표면 확대 | `FabAuthManager` (airflow-stack 측 결정) |
| R2 | registry 외부 노출 X (tailnet IP bind only) | 외부 CI / 다른 노드에서 push 필요 | Caddy 뒤 `registry.<your-domain>` + basic auth |
| R3 | tofu state = 로컬 (`.tfstate` gitignore + password manager 백업) | 다중 운영자 / 협업 | OCI Object Storage backend |
| R4 | **도입됨 (2026-05-27)**. Grafana + Prometheus + node_exporter + statsd_exporter + cAdvisor. `compose/monitoring/`. Grafana 자체 로그인. 상세 ↓ | — | — |

## R4 보충 — 모니터링 스택 도입 계획 (도입됨 2026-05-27)

### 스택 선택 — Grafana + Prometheus + node_exporter
- 실무 표준 (k8s 환경 포함) — PromQL / alert rule / Grafana dashboard / statsd_exporter mapping 학습 ROI 최대
- 대안 (Beszel / Netdata) 은 가볍지만 단발성. 실무 연결성 우선

### 자원 부담 추정 (ops-vm 12GB / 150GB 안)
- RAM: prometheus ~400-600MB + grafana ~200MB + statsd_exporter ~30MB + cAdvisor ~100MB + node_exporter ~20MB = **~700MB-1GB**
- Disk: 30s scrape × 2주 × active series ~7-10K (3 노드 node_exporter + airflow statsd + cAdvisor) ≈ **2-3GB**
- 현재 ops-vm 사용 추정 ~3-4GB → 추가 1GB 여유 충분

### 운영 파라미터
- scrape interval **30s** (15s 면 series/storage 2배, 학습용엔 해상도 의미 적음)
- retention **14d** (`--storage.tsdb.retention.time=14d`)
- WAL 압축 ON (`--storage.tsdb.wal-compression`) — ARM A1.Flex disk IO 튐 완화

### 디렉토리 패턴 — `compose/monitoring/` 통합 (L17 예외)
L17 의 "기능별 1 디렉토리" 패턴에서 monitoring 은 stack 단위. 이유:
- `prometheus.yml` 의 scrape target (statsd_exporter, cadvisor, node_exporter) 이 같은 stack 안에 있어야 한 파일에서 관리
- 함께 떴다 함께 죽는 의미 단위 (grafana 만 살아있고 prometheus 죽으면 dashboard = 회색)
- 실무 표준 (kube-prometheus-stack) 도 단일 unit
- 부분 재기동은 `docker compose ... restart grafana` 로 컨테이너 단위 제어 가능

### 토폴로지
```
ops-vm (nexus network)
  ├── prometheus      ← node_exporter × 3, statsd_exporter, cadvisor 스크랩
  ├── grafana         ← prometheus datasource
  ├── statsd_exporter ← airflow scheduler/api-server emit
  ├── cadvisor (옵션)  ← docker container 메트릭
  └── node_exporter

worker-vm: node_exporter (host network, Tailscale IP bind)
mac-server: node_exporter (host network, Tailscale IP bind) — intermittent, up==0 alert 제외
```

### 노출
- `grafana.<your-domain>` 공인 (Caddy reverse_proxy, Grafana 자체 로그인 / 또는 basic auth)
- `prometheus.internal` tailnet 전용 (dnsmasq + Caddy `*.internal` 패턴)
- node_exporter scrape = tailnet IP 직결, NSG 룰 추가 X

### airflow 연동
- airflow-stack `.env` 에 `AIRFLOW__METRICS__STATSD_ON=True`, `STATSD_HOST=statsd-exporter`, `STATSD_PORT=9125`
- DAG run 시간, task 성공/실패율, scheduler heartbeat latency, executor queue depth 수집
- Grafana 공식 dashboard (id: 16365 등) 활용

### 영향받는 다른 문서 (도입 시점에 갱신)
- `docs/architecture.md` — monitoring stack 추가, 토폴로지 도식 업데이트
- `docs/runbook.md` — Grafana 로그인 / Prometheus retention 조정 / dashboard 추가 절차
- `docs/setup.md` — 신규 셋업 흐름에 `compose/monitoring/` up 단계 추가
- `compose/caddy/Caddyfile` — `grafana.<your-domain>` + `prometheus.internal` 라우팅
- `hosts/{worker-vm,mac-server}/host-setup.sh` — node_exporter systemd / launchd 유닛

---

## R4 후속 — 관측성 stack 완성 (Tier 1)

R4 monitoring 정착 후 자연 확장. `compose/monitoring/` 안에 통합 (같은 stack 단위, audit gap 직접 해소).

### Loki + Promtail — 로그 집계
- **역할**: 모든 docker container stdout → Loki → Grafana 에서 metrics 와 같은 UI 로 query
- **자원**: Loki ~200MB, Promtail ~50MB
- **해소 audit gap**: "로그 집계 없음 — incident 시 호스트 ssh 후 docker logs"
- **구성**: Loki 는 ops-vm, Promtail 은 각 호스트 (3 노드 모두). docker log driver = `json-file` 유지하고 Promtail 이 `/var/lib/docker/containers/*/*-json.log` tail
- **storage**: 로컬 filesystem (단일 노드) → 추후 MinIO backend 로 이전 가능 (학습 가치)
- **retention**: 7d (audit gap 디버깅 목적, metrics 보다 짧게)

### Alertmanager — alert 라우팅
- **역할**: Prometheus alert rule fire → Slack/Discord/email 으로 라우팅
- **자원**: ~30MB
- **해소**: metrics 만 있고 알림 없으면 의미 절반
- **구성**: ops-vm, `compose/monitoring/` 안. Prometheus 가 `--alertmanager.url` 로 연결
- **rule 예시**: postgres down, registry disk > 80%, airflow scheduler heartbeat lag > 1m, tailscale node up==0 (mac 제외)
- **수신 채널**: Discord webhook 추천 (가정 환경 학습용, 무료)

### oauth2-proxy — `*.internal` SSO
- **역할**: 현재 무인증인 `registry-ui.internal`, `prometheus.internal`, (추가) `dbt-docs.internal`, `minio.internal` 등에 인증 layer
- **자원**: ~50MB (oauth2-proxy 권장. Authentik 은 ~500MB+ self-hosted IdP 라 오버스펙)
- **해소 audit gap**: "internal-only 서비스 인증 layer 0"
- **provider**: GitHub OAuth (학습용 무료, 본인 계정만 allow)
- **Caddy 통합**: `forward_auth oauth2-proxy:4180` 패턴. internal 라우팅 전부 한 줄로 보호

### 도입 순서 (R4 직후)
1. Alertmanager (Prometheus 동시 구성, 가장 작음)
2. Loki + Promtail (로그도 함께 봐야 의미)
3. oauth2-proxy (사용자 1 명이라도 기본 위생, internal 표면 보호)

---

## R5 — data 인프라 확장 (Tier 2 일부)

회사 data팀 표준 도구 학습 목적. 관측성 stack 완성 후 단계적 도입.

### dbt-core — Airflow worker 안 통합
- **역할**: ELT 의 T. Postgres 안 raw → staging → marts 모델링. `SELECT` = 모델, `{{ ref(...) }}` 가 자동 dependency
- **자원**: Python 패키지 ~50MB. **별도 컨테이너 X** — airflow worker image 에 `pip install dbt-core dbt-postgres`
- **Airflow 통합**: **Cosmos** (Astronomer OSS) 권장 — dbt model 1 개 = Airflow task 1 개로 자동 펼침. lineage 가 Airflow UI 에 그대로
- **storage**: Postgres 16 (공유 DB, L4). 신규 schema `raw`, `staging`, `marts` 분리
- **dbt-docs**: `dbt docs generate` 후 정적 HTML → Caddy `dbt-docs.internal` 서빙 (oauth2-proxy 보호)
- **CI**: airflow-stack repo 에 `dbt-project/` 추가, PR 시 `dbt compile && dbt test` 실행
- **학습 가치**: SQL + git + jinja + DAG 사고법 + lineage — data팀 면접 필수
- **책임**: airflow-stack repo (인프라 측은 dbt-docs hosting 만)

### MinIO — mac-server 호스팅
- **역할**: S3 호환 object storage. data lake (parquet), dbt artifact, Loki/Tempo backend, airflow log archive, 일반 파일 저장 등 다용도
- **자원**: ~300MB RAM. disk = mac SSD 본인 결정
- **호스팅 = mac-server** (스토리지 여유, OCI boot disk 200GB 절약). 단 mac intermittent → 영구 데이터 보관 X, 학습용/cache 용
- **mac-server 의 첫 인프라 컨테이너** — `compose/_hosts/mac-server.yml` 신설 필요 (현재 비어있음)
- **접근**:
  - airflow worker (ops-vm) → `http://<mac-tailnet>:9000` 직결
  - 콘솔 UI → `minio.internal` Caddy reverse_proxy (mac-server tailnet IP), oauth2-proxy 보호
- **bucket 초기**: `raw-data`, `dbt-artifacts`, `loki-chunks` (이전 시), `airflow-logs`
- **신뢰성**: mac down 시 MinIO 도 down → airflow task 가 MinIO 의존하면 같이 실패. 학습용 OK
- **백업 정책**: 없음 (L7). 영구 데이터는 Supabase / 외부

### Tier 2 나머지 (Metabase / Redpanda 등) 는 트리거 발생 시 R5 확장
- Metabase — BI dashboard 가 필요해질 때 (dbt marts 위에)
- Redpanda — streaming 학습 / event ingestion 필요할 때
- 둘 다 ops-vm 추가 ~500MB-1GB → R4 후속 capacity 재분배 (R6) 와 함께 트리거

### 영향받는 다른 문서 (도입 시점에 갱신)
- `docs/architecture.md` — mac-server 가 인프라 컨테이너 보유, MinIO 토폴로지 추가
- `docs/runbook.md` — MinIO bucket 생성, dbt-docs 빌드/배포, dbt model 추가 워크플로
- `compose/_hosts/mac-server.yml` (신설), `compose/minio/` (신설)
- `compose/caddy/Caddyfile` — `minio.internal`, `dbt-docs.internal` 라우팅 (oauth2-proxy `forward_auth`)
- airflow-stack repo — dbt-project, Cosmos 통합, MinIO connection

## airflow-stack 과의 cross-reference

- airflow workload 결정 (Airflow 3.2 / Edge Executor / `@task.docker` 등) = `airflow-stack:docs/decisions.md`
- airflow-stack:L20 (워커 → ops-vm Tailscale 직결) ↔ 본 repo L11 — 동일 결정의 두 측면
