# Architecture

3 노드 분산 인프라. Tailscale 메쉬 + Caddy edge + Postgres 공유 DB + self-hosted registry.

## 토폴로지

```
                        인터넷
                           │  HTTPS 443/80 — airflow.<your-domain>, grafana.<your-domain>
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│  ops-vm  (OCI A1.Flex 2/12 GB, 150 GB boot, public IP)          │
├──────────────────────────────────────────────────────────────────┤
│  Caddy        ──► api-server:8080, grafana:3000                  │
│               ──► minio.internal → mac-server:9000 (tailnet)     │
│  Postgres 16    shared DB                                        │
│  Registry       tailnet IP bind, named volume                    │
│  Prometheus / Grafana / Alertmanager / Loki / Promtail           │
│  statsd_exporter / cAdvisor / node_exporter                      │
└────────────────────┬─────────────────────────────────────────────┘
                     │ Tailscale (MagicDNS / ACL)
                     │ Prometheus ──► node_exporter:9100 (tailnet)
┌────────────────────┴─────────────────────────────────────────────┐
│  worker-vm  (OCI A1.Flex 2/12 GB, 50 GB boot, private)          │
├──────────────────────────────────────────────────────────────────┤
│  node_exporter :9100 (systemd)    Promtail (systemd)             │
│  airflow edge worker  (airflow-stack repo)                       │
└────────────────────┬─────────────────────────────────────────────┘
                     │ Tailscale
                     │ Prometheus ──► node_exporter:9100 (intermittent)
┌────────────────────┴─────────────────────────────────────────────┐
│  mac-server  (M1, home NAT, intermittent, 10-core / 32 GB)       │
├──────────────────────────────────────────────────────────────────┤
│  node_exporter :9100 (launchd)                                   │
│  Docker (Colima)    MinIO :9000/:9001  (data lake)               │
│                     airflow edge worker  (airflow-stack repo)    │
└──────────────────────────────────────────────────────────────────┘
```

## 네트워크

- **외부 ingress**: ops-vm 443 → Caddy → api-server:8080 (사람용 UI). 80 → ACME redirect
- **노드 간**: Tailscale (MagicDNS, ACL 단일 사용자 기본값). 별도 NSG ingress 룰 X
- **워커 ↔ control plane**: Tailscale 직결 `http://<ops-vm-tailnet>:8080/edge_worker/v1` (cert 불필요, edge API 공인 노출 X)
- **SSH**: Tailscale 만 + 본인 IP /32 fallback (audit Critical 해소)
- **nexus docker network** (L15): ops-vm 내부, caddy / postgres / registry / monitoring / airflow 서비스 모두 join. 호스트 단위 객체 (worker-vm·mac-server 에는 없음). MinIO 는 mac-server 독립 실행 — Caddy 가 tailnet 경유 reverse proxy
- **minio 접근**: tailnet 내 `http://minio.internal` (Caddy → mac-server:9000) 또는 직접 `MAC_TAILNET_IP:9000`
- **monitoring scrape**: Prometheus (ops-vm 컨테이너) → node_exporter:9100 tailnet 직결 (worker-vm / mac-server). mac-server 는 intermittent — scrape fail 은 정상

## OCI 자원

| | ops-vm | worker-vm |
|---|---|---|
| Shape / OCPU / RAM | A1.Flex 2 / 12 GB | A1.Flex 2 / 12 GB |
| Boot Volume | 150 GB | 50 GB |
| Public IP | reserved | 없음 |
| Subnet | public | private |

총 storage = 150 + 50 = **200 GB** (Always Free 한도 딱). 합산 4 OCPU + 24 GB → A1.Flex Always Free 안.

registry storage 도 ops-vm 부트 디스크 안 (docker named volume). 디스크 모니터링 + 주기 GC 로 관리 (`runbook.md`).

## 책임 분리

| 책임 | repo / 위치 |
|---|---|
| OCI 리소스 (VCN·NSG·instance·volume·IP) | nexus-prime `tofu/` |
| Tailscale 노드 가입 / ACL | nexus-prime (수동, `docs/runbook.md`) |
| 호스트 부트스트랩 (swap·Docker·unattended-upgrades) | nexus-prime `hosts/{host}/host-setup.sh` |
| Caddy / Postgres / Registry 컨테이너 | nexus-prime `compose/{기능}/` |
| MinIO (data lake, mac-server) | nexus-prime `compose/minio/` |
| Prometheus / Grafana / statsd_exporter / cAdvisor / node_exporter | nexus-prime `compose/monitoring/` |
| airflow control plane (api-server·scheduler·dag-processor) | airflow-stack |
| airflow edge worker | airflow-stack |
| DAG / 워크로드 코드 | airflow-stack + 도메인 repo (예: lol-list) |
| task 실행 image (registry 에 push) | 도메인 repo (예: lol-list 의 task image build) |

## 결합점

- **docker network 이름** = `nexus`. airflow-stack 의 compose 가 `networks: { nexus: { external: true } }` 선언
- **postgres 접근** = 같은 nexus network 안 `postgres:5432`
- **registry 주소** = `<ops-vm-tailnet>:5000` — airflow-stack 의 `@task.docker(image=...)` 가 참조

## 외부 의존

- DNS: 사용자 도메인 (외부 provider). `airflow.<your-domain>` A → ops-vm reserved IP
- Tailscale: SaaS, MagicDNS ON
- Let's Encrypt: Caddy 가 자동 ACME
- (워크로드 측면) Supabase: airflow-stack 측 외부 의존
