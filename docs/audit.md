# Infrastructure Audit — 2026-05-28 (갱신)

평가 대상: `nexus-prime` (인프라 layer). airflow-stack (워크로드) 는 cross-reference 만.

방법:
- 정적 분석: 전 트래킹 파일 + `.gitignore` + git history (31 commits)
- 라이브 검증: `tofu plan` (drift 0 확인), `oci` CLI 로 실제 OCI 상태 cross-check

## 요약 점수

| # | 항목 | 점수 | 한 줄 평 |
|---|---|---|---|
| 1 | 신규 재구축 (repo + 외부 .env) | B+ | 절차는 갖춤. secrets-backup.md 가 manual sync 라 drift 위험 |
| 2 | 부분 복구 | A- | compose 단위 독립적, 1 회 chicken-and-egg (dnsmasq) 만 주의 |
| 3 | 보안 | B  | 공인 표면 최소. 내부 (registry/registry-ui/postgres) 무인증 = tailnet 신뢰 |
| 4 | 공개 repo 안전성 | A | L14 위반 전부 해소. git history filter-repo 로 정리 완료 |
| 5 | 확장성 | A- | `compose/<svc>/ + include + Caddyfile + *.internal` 패턴 깔끔. 단 single-host bottleneck |
| 6 | 현재 상태 가시성 | B+ | 모니터링 스택(Prometheus+Grafana+Loki+Alertmanager) 가동, 대시보드 provisioning 자동. scripts/status.sh 추가 |
| 7 | 신규 서비스 추가 | B+ | 결합점 (nexus / postgres / registry / *.internal) 명확. 단 example template 부재 |
| 8 | IaC 준수 | A- | drift 0, lock 파일 commit, import 절차 완비. state remote backend 미도입 (R3 이미 인지) |

---

## 1. 신규 셋업 재현성 (repo + 외부 .env 만)

**Verdict: B+** — 절차가 글로 다 적혀 있고 실제로 따라할 수 있음. 단 secrets-backup.md 가 사람 손에 의존.

### Strong
- `docs/setup.md` 0→6 단계 흐름이 명료. OpenTofu 설치 명령까지 (`docs/setup.md:13`)
- `tofu/terraform.tfvars.example` 가 모든 OCI 인증·접근 변수 placeholder 화 (`tofu/terraform.tfvars.example:1-17`)
- `tofu/IMPORT.md` — 신규가 아닌 import 흐름까지 별도 문서화. OCID 수집표·17 개 import 명령·예상 drift 까지 (`tofu/IMPORT.md:14-99`)
- `compose/_hosts/ops-vm.env.example` 이 신규 셋업 시 필요한 4 변수 다 노출 (`compose/_hosts/ops-vm.env.example:5-13`)
- host-setup.sh 멱등 + Tailscale 설치까지 포함 (`hosts/ops-vm/host-setup.sh:1-62`, `hosts/worker-vm/host-setup.sh:1-53`)
- `secrets-backup.md` 가 모든 .env 의 실제 값을 한 파일에 집약 — Bitwarden 1 entry 로 백업 가능
- `.terraform.lock.hcl` commit 되어 provider 버전 재현성 보장 (`.gitignore:14` 주석)

### Gaps
- **`secrets-backup.md` 와 실제 `.env` 가 manual sync.** 자동 검증 스크립트 없음. 패스워드 1 개 회전하면 양쪽 다 손으로 갱신해야 함. 한쪽만 갱신되면 재구축 시 발견.
- ~~**외부 의존 셋업이 문서화 안 됨**~~ — 해소 (2026-05-31): `secrets-backup.md` 에 DNS provider / Tailscale 계정 / OCI 테넌시 이메일·MFA 추가 완료.
- ~~**첫 dnsmasq 부트스트랩 chicken-and-egg**~~ — 해소 (2026-05-31): `compose/dnsmasq/compose.yml` 에 `build: .` 추가. 첫 셋업 시 로컬 빌드 가능, registry 의존 제거.

### Recovery 시간 추정 (account 살아있고 secrets-backup.md 만 있을 때)
- tofu apply (capacity retry 포함): 10 분 ~ N 시간 (A1.Flex capacity 운빨)
- host-setup × 3: 5 분 / 호스트
- compose up + dnsmasq build/push: 10 분
- airflow-stack 재기동: 별도 repo 절차
- **현실적으로 1~3 시간** (운빨 제외 시).

---

## 2. 부분 복구 (일부 down → 다시 띄움)

**Verdict: A-** — compose 단위 독립적이고 named volume 분리되어 있음.

### Strong
- 각 기능별 `compose/<svc>/compose.yml` 이 독립. `docker compose -f compose/<svc>/compose.yml --env-file ... up -d` 단일로 재기동 가능
- `restart: unless-stopped` 모든 서비스에 (caddy/postgres/registry/registry-ui/dnsmasq)
- `nexus` external network 가 호스트 1 회 생성 (`hosts/ops-vm/host-setup.sh:42-47`) → compose 재기동이 network 를 망가뜨리지 않음
- Caddy 가 정의한 host-level 결합점 (`AIRFLOW_DOMAIN`, `registry.internal`, `registry-ui.internal`) 만 챙기면 됨
- 인스턴스 단위 복구는 `tofu/reinstall-instances.sh` 가 destroy + retry-apply 자동화. L18 정책으로 in-place 변경 제거 → 변경/복구 절차 통일

### Gaps
- **dnsmasq image 가 self-host registry 안에 있음 → registry-data volume 손실 시 dnsmasq 도 못 띄움**. runbook 에 재빌드 절차 있지만 (`docs/runbook.md:46-51`), 절차 의존도 높음.
- **Caddy `caddy-data` / `caddy-config` volume 손실 시** ACME 다시. Let's Encrypt rate limit (5 cert / 7 일 / 도메인) 안전권이지만 의식적으로 자주 끄지 말 것.
- **registry-data 손실** = task image 전부 재빌드 (각 워크로드 repo 책임). 정책상 OK (L7).
- **postgres-data 손실** = airflow 메타 전부. airflow-init 이 복구하지만, 사용자 수동 등록값 (Variables / Connections) 은 `airflow-variables.json` 기반 import 가 있어야 살아남음 (`secrets-backup.md:74-88` 에 템플릿).

### Reinstall 절차의 미세한 빈틈
- `tofu/reinstall-instances.sh` 가 `tofu destroy -target=oci_core_instance.ops_vm` 만 함. **그 결과 `oci_core_public_ip.ops_reserved` 의 `private_ip_id` 가 stale 참조** 가 됨. tofu plan 이 자동 in-place update 로 새 VNIC private IP 에 re-attach (`tofu/IMPORT.md:87`) — 검증됨. OK.
- 단, `data "oci_core_vnic_attachments"` 와 `data "oci_core_private_ips"` 는 destroy 후 새 인스턴스 create 가 끝난 다음에야 정확한 값 반환. retry-apply 가 sequence 잘 처리하는지 확인 필요 (실측에서 잘 됨).

---

## 3. 보안

**Verdict: B** — 공인 표면 최소. 내부 표면은 tailnet 신뢰 모델.

### 공인 표면 (인터넷 → ops-vm)
| 포트 | 정책 | 평가 |
|---|---|---|
| 443/tcp | 0.0.0.0/0 | OK — Caddy 가 termination |
| 80/tcp | 0.0.0.0/0 | OK — ACME redirect |
| 22/tcp | `<home-ip>/32` (var `my_home_ip_cidr`) | 의문점 ↓ |
| 443/udp | (NSG 에 없음 — 확인됨) | OK — IaC 의 의도된 drift 항목으로 명시 (`tofu/IMPORT.md:97`) |

- **L8 (audit Critical 해소) 의 본인 IP /32 fallback** 이 현재도 살아있음 (NSG `ops_ssh` rule, `tofu/nsg.tf:36-48` + 라이브 OCI 확인). 본래 의도는 "tailscale ssh 망가졌을 때 fallback". 단점:
  - 가정 IP 가 ISP 에 의해 바뀌면 fallback 못 씀 (`docs/decisions.md:L8` 의도와 어긋남)
  - tailscale --ssh 가 정상이면 fallback 불필요 → 표면 줄이려면 제거 가능
  - 권장: 유지하되 "현재 home IP 가 맞는지 분기 점검" 를 routine 에 추가, 또는 아예 삭제하고 console serial 콘솔로 emergency access
- **Caddy headers** (`compose/caddy/Caddyfile:11-13`): HSTS + X-Frame-Options + X-Content-Type-Options. 누락: CSP, Referrer-Policy, Permissions-Policy. airflow UI 만 노출하니 우선순위 낮음.
- **edge worker v1 API 명시 차단** (`compose/caddy/Caddyfile:17-19`) — 좋음. defense in depth.

### 내부 표면 (tailnet)
| 서비스 | 인증 | 위험 |
|---|---|---|
| registry:5000 | 없음 | tailnet member 전원 push/pull 가능 |
| registry-ui (Caddy 경유) | 없음 | tailnet member 전원 image list/delete 가능 (DELETE_IMAGES=true!) |
| postgres:5432 | superuser + pw | nexus docker network 내부만. 호스트 bind 없음. OK |
| dnsmasq:53 | 없음 | tailnet IP bind, --bind-interfaces. OK (DNS amplification 위험 없음 — `--domain-needed --bogus-priv`) |

- **현재 tailnet ACL = 단일 사용자** 라서 위 무인증 위험은 안 터짐. 그러나 ACL 깨지거나 모바일에서 잘못 추가하면 즉시 표면 확대.
- `joxit/docker-registry-ui` 의 `DELETE_IMAGES: "true"` 는 한 명만 쓸 때 편하지만 가족·동료 추가 즉시 위험. 새 사용자 추가 트리거 = ACL 분리 + basic auth 추가.

### Secrets handling
- `.env` / `terraform.tfvars` / `secrets-backup.md` 모두 gitignored — git history 검증 완료 (`git log -S <domain>` no result).
- `secrets-backup.md` 자체가 clearext markdown 으로 dev 머신 평문 저장. dev 머신 침해 = 전부 노출.
  - 권장: 이 파일 자체를 GPG 또는 age 로 암호화하고 (`*.md.age` gitignore 추가) 평문은 짧은 시간만.
- **OCI API key 만료/회전 정책 없음**. 장기 살아있는 key. dev 머신 침해 시 OCI 전 권한.
  - 권장: `oci session authenticate` (token, 1 시간) 기반으로 옮기거나, 최소한 `oci iam api-key list` 주기 검토.
- **postgres password 길이 OK** (24 자 base64). Fernet/JWT 32 byte. ssh key ed25519. 모두 적절.
- **Tailscale auth key 재사용성 / 만료** 정책 없음. 한 번 쓰면 폐기 권장.

### Patching
- `unattended-upgrades` 활성화 (`hosts/*/host-setup.sh:36-39`) — 보안 패치 자동. 좋음.
- 컨테이너 이미지 (`caddy:2-alpine`, `postgres:16`, `registry:2`, `joxit/docker-registry-ui:latest`) **자동 갱신 없음**. `:latest` 사용 시 무경고 변경 위험, `:2` 같은 메이저 핀은 보안 패치는 받지만 마이너 깨짐 가능성. 운영 routine 에 `docker compose pull && up -d` 월 1 회 등 추가 권장.

---

## 4. 공개 repo 안전성

**Verdict: A** — L14 위반 전부 해소. git history 까지 정리됨.

### 라이브 검증 결과 (`git ls-files | xargs grep ...`)

| 항목 | tracked files 에서 발견? |
|---|---|
| 개인 도메인 | NO |
| home IP (NSG SSH allow CIDR) | NO |
| ops-vm public IP (reserved) | NO |
| tailnet IP (ops / worker) | NO |
| home 경로 (`/home/<user>` / `/Users/<user>`) | NO |
| 사용자 이메일 | NO |
| OCID / API key fingerprint | NO |
| tailnet hostname literal | NO (해소) |

### L14 조치 완료 (2026-05-28)
- `hosts/ops-vm/host-setup.sh`, `hosts/worker-vm/host-setup.sh` — `TAILSCALE_HOSTNAME` env 변수화
- `docs/runbook.md` — tailnet 별명 literal → placeholder
- `scripts/deploy-ops-vm.sh` — 초기 버전에 도메인·IP·패스워드 하드코딩 → 전부 제거

### Git history 검증
- `git log --all -p -- secrets-backup.md tofu/terraform.tfvars compose/_hosts/ops-vm.env` — 0 results
- `git log -S <domain>` — 0 results
- `git filter-repo --replace-text` 로 deploy-ops-vm.sh 관련 커밋 2개에서 민감 문자열 제거 후 force push 완료

---

## 5. 확장성

**Verdict: A-** — 패턴이 깔끔하고 결합점이 적음.

### 패턴 (신규 서비스 추가)
1. `compose/<svc>/compose.yml` 추가 (`networks: { nexus: { external: true } }`)
2. `compose/_hosts/ops-vm.yml` 의 `include:` 에 한 줄 추가
3. (외부 노출이면) `compose/caddy/Caddyfile` 에 `{$SVC_DOMAIN} { reverse_proxy <container>:<port> }` 추가
4. (내부 노출이면) `compose/caddy/Caddyfile` 에 `http://<name>.internal { reverse_proxy <container>:<port> }` — dnsmasq 가 자동 해석
5. (DB 필요면) `docs/runbook.md:26-34` 의 `CREATE DATABASE / USER / GRANT` 패턴

### Strong
- 호스트 ≠ 서비스 분리: 새 서비스가 ops-vm 컨테이너인지 worker-vm 컨테이너인지 자유로움 (현재는 ops-vm 만 인프라 컨테이너 보유)
- 도메인 모델 명확: 공인 = `<svc>.<your-domain>`, 내부 = `<name>.internal`. dnsmasq 가 후자 무한 확장 가능
- postgres 가 공유 DB (L4) — 신규 서비스가 stateful 이어도 instance 1 개로 처리

### Gaps / 한계
- **Single-host 의 스케일링 천장**: ops-vm A1.Flex 2/12GB 가 한계. caddy + postgres + registry + airflow control plane 다 한 노드. 워크로드 증가 시 분리 필요.
- **HA 없음**: ops-vm 단일 장애점 = airflow / postgres / registry 전체 다운. 정책상 (L7) 수용.
- **Caddyfile 이 한 파일** — 서비스 수 늘어나면 `import` 디렉토리 분할 필요. 지금 5 routing 정도라 OK.
- **postgres 한 인스턴스에 모든 DB** — 한 서비스가 disk/CPU 점유하면 전부 영향. tenant 격리 없음.
- **internal-only 서비스에 인증 layer 0** — 신규 internal 서비스 추가 = 무인증 노출. 5~10 개 쌓이면 oauth2-proxy 같은 SSO 도입 필요.
- **worker-vm 활용도 낮음** — 인프라 컨테이너 0. 인프라 layer 의 일부를 worker-vm 으로 이전하면 (e.g., dnsmasq HA) blast radius 줄일 수 있음. 현재는 미도입.

---

## 6. 현재 상태 가시성

**Verdict: B+** — 모니터링 스택 가동으로 라이브 가시성 대폭 개선. 정적 문서도 우수.

### Strong
- `docs/architecture.md` — 토폴로지 ASCII + OCI 자원 표 + 책임 분리 표. 1 분 이해 가능.
- `docs/decisions.md` — L1~L18 잠긴 결정 + R1~R3 재고 가능 결정. 신규 PR 시 의사결정 기준.
- `docs/runbook.md` — 일상 운영 절차. 인스턴스 재설치 / DB 추가 / registry / Caddy / Tailscale / colima 자원 등.
- **모니터링 스택 (R4) 가동** — Prometheus + Grafana + Loki + Alertmanager + statsd_exporter + node_exporter (3 노드). cAdvisor 는 제거 (DockerVersion 빈값으로 컨테이너 메트릭 미수집 — node_exporter/Loki 로 갈음)
  - ops-vm: Prometheus scrape all up, Loki 7d retention, Promtail 컨테이너 로그 수집
  - worker-vm: node_exporter + promtail systemd 가동
  - mac-server: node_exporter LaunchAgent 가동
  - Grafana: nexus-overview + airflow 대시보드 provisioning 자동 배포
  - Alertmanager: Discord webhook, NodeDown / ServiceDown / DiskLow / MemLow 룰
- `scripts/status.sh` — tofu plan + docker compose ps + tailscale status 한 방
- caddy / registry / dnsmasq healthcheck 추가 → `compose ps` 에서 상태 즉시 확인

### Gaps
- **OCI 비용/quota dashboard 외부**: Always Free 한도 침해 알림 없음. 현재 한도 내.
- **로그: mac-server 미수집** — Colima VM 경로 복잡성으로 보류. ops-vm / worker-vm 으로 대부분 커버.
- ~~**Airflow statsd 메트릭 미연동**~~ — 해소 (2026-05-31): airflow-stack 측 statsd 설정 완료. airflow 대시보드 provisioning 으로 연동 확인.
- **Grafana alert 미설정**: Alertmanager 룰은 있으나 Grafana UI alert 미구성.

---

## 7. 신규 서비스 추가 (이 repo만 보여주면)

**Verdict: B+** — 결합점은 명확. 단 예시 (template) 부재.

### 신규 서비스 입장에서 본 결합점
| 결합점 | 어디서 알 수 있나 |
|---|---|
| docker network = `nexus` (external) | `docs/architecture.md:67`, `docs/decisions.md:L15` |
| postgres = `postgres:5432` (같은 network 안) | `docs/architecture.md:69`, `docs/runbook.md:26-34` |
| registry = `registry.internal` (Caddy 경유, tailnet 전용) | `docs/runbook.md:58-83` |
| Caddy 외부 라우팅 추가 = Caddyfile 편집 + 호스트 wrapper rebuild | `compose/caddy/Caddyfile`, `compose/_hosts/ops-vm.yml` |
| Caddy 내부 라우팅 + DNS = Caddyfile 추가 (dnsmasq 변경 X) | `docs/runbook.md:53-55` |
| 호스트 wrapper 진입점 = `compose/_hosts/ops-vm.yml` include | `compose/_hosts/README.md` |

명확. 신규 서비스 개발자가 이 repo + airflow-stack 사례 보면 패턴 복제 가능.

### Gaps
- **`compose/example/` template 부재**: 신규 서비스가 따라할 minimal compose 예제 (postgres user 발급 + Caddy 내부 라우팅 + nexus network join) 없음. airflow-stack 을 참조하면 되지만 그건 별 repo 라서 reader 가 두 repo 를 동시에 봐야 함.
- **postgres user 발급이 manual psql**: `docs/runbook.md:30-34` 의 3 줄 명령. 자주 일어나면 `scripts/postgres-create-user.sh <db> <user>` 한 줄 wrapper 가 편함.
- **registry insecure-registries 등록이 각 호스트마다 한 번**: `docs/runbook.md:66-75`. 이건 host-setup.sh 가 자동화하지 않음. 현재 3 노드라 OK. 노드 늘면 host-setup.sh 에 추가 권장.

---

## 8. IaC 준수

**Verdict: A-** — 라이브 drift 0, import 절차 완비. state remote backend 만 미도입.

### 라이브 검증
- `tofu plan` → "No changes. Your infrastructure matches the configuration."
- OCI CLI cross-check (요약):
  - 인스턴스: ops-vm + worker-vm RUNNING (A1.Flex 2/12GB) — 코드와 일치
  - VCN: 10.0.0.0/16 (`main-vcn`) — 코드와 일치
  - Reserved IP: `ops-vm-ip` (1 개) — 코드와 일치
  - NSG ops: 443+80 (0.0.0.0/0) + 22 (`<home-ip>/32`) — 코드와 일치
  - NSG worker: 22 (10.0.0.0/16) — 코드와 일치
  - Boot volumes: 150 GB ops + 50 GB worker — 코드 default 와 일치
  - AD: 리전 내 단일 AD — code 의 `availability_domains[0]` 와 일치
  - Default Security List 가 그대로 있음 — VCN 생성 시 자동, 별도 룰 없음 (NSG 가 메인)

### Strong
- `.terraform.lock.hcl` commit 됨 → provider 버전 재현 (`.gitignore:14`)
- `tofu/variables.tf` 가 모든 secret/personal 값을 변수로 추출 (tenancy/user/fingerprint/key path/region/compartment/ssh_pubkey/home_ip)
- `tofu/IMPORT.md` 가 신규 != 기존-import 흐름 분기 + 17 개 import 명령 + 예상 plan output (`tofu/IMPORT.md:80-89`) 까지 명시
- `tofu/retry-apply.sh` 가 A1.Flex capacity 회피 routine 자동화 (`tofu/retry-apply.sh:1-42`)
- `tofu/reinstall-instances.sh` 가 L18 (immutable) 정책 코드화 — 인스턴스 destroy + retry-apply 한 방
- output 이 의미 있는 것만 (`tofu/outputs.tf` — public IP / OCID 들). credential 출력 안 함.
- 인증 정보 분리: `terraform.tfvars` gitignored, `*.example` 만 commit

### Gaps
- **state 가 로컬 (`tofu/terraform.tfstate`)** — R3 에서 인지 (`docs/decisions.md:R3`). 분실 시 IMPORT.md 따라 17 회 import 재실행 (수 시간). password manager 백업 routine 이 사람 의존.
- **`data "oci_core_images" "ubuntu_2204_arm"`** — `sort_by = "TIMECREATED" DESC` 로 항상 최신 image. 재구축 시 image 가 바뀌어 미세한 의존성 깨질 수 있음 (Ubuntu 22.04 ARM 안에서는 보통 OK). pin 하려면 OCID 변수화.
- **OCI 리소스 tagging 부재**: cost/owner/env tag 없음. 단일 사용자 단일 환경이라 OK 지만, 향후 dev/prod 분리 시 필요.
- **AD fallback 이 코드 편집** (`tofu/IMPORT.md:117-121`) — `local.availability_domain = ...availability_domains[0]` 의 인덱스를 손으로 바꿈. 변수화하면 더 깔끔하지만, chuncheon 은 단일 AD 라 현재 무의미.
- **`tofu/terraform.tfstate.backup` 이 gitignored 됨** (`.gitignore:11` `*.tfstate.*`) — 의도된 동작이지만, state.backup 도 같이 password manager 에 백업해야 함을 명시적으로 적어두면 좋음.

---

## 우선순위 Action Items

완료 항목은 취소선.

| 우선 | 항목 | 근거 | 소요 |
|---|---|---|---|
| ~~P0~~ | ~~`docs/runbook.md` 의 tailnet 별명 literal → placeholder. host-setup.sh hostname env 변수화~~ | ~~L14 위반~~ | 완료 |
| ~~P0~~ | ~~`docs/tasks.md` Phase 0 완료 처리~~ | ~~stale~~ | 완료 |
| ~~P1~~ | ~~`compose/dnsmasq/compose.yml` 에 `build: .` 추가~~ | ~~chicken-and-egg 제거~~ | 완료 |
| ~~P1~~ | ~~`scripts/status.sh`~~ | ~~라이브 가시성~~ | 완료 |
| ~~P2~~ | ~~TERMINATED boot volume 2 개 삭제~~ | ~~정리~~ | 완료 |
| ~~P2~~ | ~~caddy/registry/dnsmasq healthcheck 추가~~ | ~~compose ps 상태~~ | 완료 |
| ~~P2~~ | ~~`tofu/terraform.tfstate.backup` 백업 대상 runbook 명시~~ | ~~state 관리~~ | 완료 |
| ~~R4~~ | ~~monitoring 스택 (Prometheus+Grafana+Loki+Alertmanager+node_exporter×3+statsd_exporter)~~ | ~~가시성~~ | 완료 |
| ~~P1~~ | ~~`secrets-backup.md` 의 외부 계정 정보 (DNS provider / Tailscale account / OCI 테넌시 이메일+MFA) 추가~~ | ~~신규 재구축 시 외부 의존 셋업 단계 부재~~ | 완료 |
| P3 | OCI API key rotation routine (분기 1 회 fingerprint 갱신) | 장기 살아있는 key 위험 | routine 추가 |
| ~~P3~~ | ~~신규 서비스 추가 체크리스트~~ | ~~신규 서비스 추가자 onboarding~~ | 완료 (`docs/runbook.md`) |
| P3 | registry / registry-ui 에 basic auth 추가 — tailnet 다중 사용자 트리거 시만 | R2 의 사전 준비 | 1 시간 |
| P4 | `secrets-backup.md` 자체를 age 암호화 | dev 머신 침해 위험 감소 | 1 시간 |
| P4 | tofu state OCI Object Storage backend 로 이전 | R3 트리거 (다중 운영자) 시 | 1 시간 |
