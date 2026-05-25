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
| R4 | 모니터링 미도입. 가시성 = 호스트 ssh + `docker ps` + `tofu plan` + `tailscale status` (audit C+) | 장애 디버깅 빈도 증가 / airflow DAG 성능 추적 필요 / 운영 routine 정착 | Grafana + Prometheus + node_exporter + statsd_exporter (+ cAdvisor 옵션). 상세 ↓ |

## R4 보충 — 모니터링 스택 도입 계획

도입 시점은 R4 트리거 발생 후. 결정만 먼저 못 박아 둠.

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

## airflow-stack 과의 cross-reference

- airflow workload 결정 (Airflow 3.2 / Edge Executor / `@task.docker` 등) = `airflow-stack:docs/decisions.md`
- airflow-stack:L20 (워커 → ops-vm Tailscale 직결) ↔ 본 repo L11 — 동일 결정의 두 측면
