# Architecture

3 노드 분산 인프라. Tailscale 메쉬 + Caddy edge + Postgres 공유 DB + self-hosted registry.

## 토폴로지

```
                          인터넷
                            │ HTTPS  airflow.<your-domain>  grafana.<your-domain>
                            ▼  443/80 (TCP+UDP)
┌──────────────────────────────────────────────────────────────────┐
│  ops-vm  (OCI public, always-on, A1.Flex 2/12 GB, 150 GB)        │
│   Caddy ──► (nexus network) ──► api-server / postgres            │
│   Postgres 16 (공유 DB)                                           │
│   Registry :2 (tailnet IP bind, named volume on boot disk)       │
│   Prometheus + Grafana + statsd_exporter + cAdvisor              │
│   node_exporter (ops-vm 호스트 메트릭)                            │
│   Tailscale                                                      │
└──────────────────────────────────────────────────────────────────┘
        │ Tailscale (MagicDNS / ACL)
        │ Prometheus ──► node_exporter:9100 (tailnet 직결)
┌──────────────────────────────────────────────────────────────────┐
│  worker-vm  (OCI private, always-on, A1.Flex 2/12 GB)            │
│   node_exporter (systemd, :9100). airflow edge worker (별도 repo)│
└──────────────────────────────────────────────────────────────────┘
        │ Tailscale
        │ Prometheus ──► node_exporter:9100 (tailnet 직결, intermittent)
┌──────────────────────────────────────────────────────────────────┐
│  mac-server  (M1, 가정 NAT, intermittent, 10-core / 32 GB)       │
│   node_exporter (launchd, :9100). Docker (Colima) + airflow edge │
└──────────────────────────────────────────────────────────────────┘
```

## 네트워크

- **외부 ingress**: ops-vm 443 → Caddy → api-server:8080 (사람용 UI). 80 → ACME redirect
- **노드 간**: Tailscale (MagicDNS, ACL 단일 사용자 기본값). 별도 NSG ingress 룰 X
- **워커 ↔ control plane**: Tailscale 직결 `http://<ops-vm-tailnet>:8080/edge_worker/v1` (cert 불필요, edge API 공인 노출 X)
- **SSH**: Tailscale 만 + 본인 IP /32 fallback (audit Critical 해소)
- **nexus docker network** (L15): ops-vm 내부, caddy / postgres / registry / monitoring / airflow 서비스 모두 join. 호스트 단위 객체 (worker-vm·mac-server 에는 없음)
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
