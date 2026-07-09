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
| L22 | omnigent(meta-harness, Claude Code + OpenCode 오케스트레이션) ops-vm 배포. **stateful** — `omnigent-data` 볼륨(artifacts·admin-credentials) + 공유 Postgres `omnigent` DB. `mem_limit: 4g`. 공개 도메인(`agent.<your-domain>`) 노출, 인증은 built-in accounts 모드(OIDC 아님 — 개인 계정 단독 사용 기준 도메인 게이트가 무의미해 accounts 단일 관리자 게이트로 결정, BON-262) | 공개 RCE 표면(원격 shell·파일쓰기) → accounts 인증 필수 전제. **L7 재고 트리거 발동**: omnigent DB/artifacts 백업 정책 미정. 현재는 L7(백업 없음) 그대로 유지 — 재고 시 BON-264 cross-ref. **노출·위치는 L23 으로 재고됨** |
| L23 | omnigent 격리 재설계 (issue #1) — 위험을 **노출×위치×권한** 곱으로 보고 세 축 모두 인하. 노출: 공개 도메인 → `agent.internal`(tailnet 전용). 위치: ops-vm(인프라 심장부) → worker-vm(사설, always-on). 권한: DB 는 자기 DB(`omnigent`)만 read-write, cross-DB 읽기는 `omnigent_ro` role 로 별도 발급, 원격 상태파악은 SSH 대신 Prometheus/Loki 읽기, 인프라 변경은 docker.sock 대신 airflow DAG 트리거(L21 일반화) | L22 최댓값 설계(공개+심장부+공유 DB)가 RCE 표면의 blast radius 를 키움. 세 축 중 하나만 낮춰도 완화되지만 곱을 낮추는 게 최선. accounts 인증(BON-262)은 심층방어로 유지 — 유일한 방어선에서 격리에 더해진 계층으로 강등. L7 재고 트리거(백업 미정)는 이 변경과 무관 — BON-264 cross-ref 유지 |
| L24 | omnigent 외주 직원화 (issue #3, #4) — git-worker 에이전트(`compose/omnigent/agents/git-worker/`) 추가. **git**: fine-grained PAT(대상 repo 만 RW), `os_env.sandbox.credential_proxy`(`gh_basic`)로 주입 — 실제 토큰은 parent 프로세스에만 있고 샌드박스는 합성 placeholder 만 봄(egress MITM 프록시가 github.com/api.github.com 요청에만 실제 토큰 첨부). **네트워크**: `egress_rules` 로 github.com/api.github.com/codeload.github.com 만 허용(default-deny HTTP(S) MITM). **DB**: rondo·pot-of-greed 두 DB 에 `omnigent_ro`(read-only) 추가 발급, `os_env` 밖 local tool(parent 프로세스 실행)로 조회 — `egress_rules` 활성 시 샌드박스의 유일한 아웃바운드가 HTTP(S) 프록시라 Postgres TCP 는 애초에 못 나가기 때문. **격리**: host bind mount·docker.sock 없음(기존과 동일), `write_paths` 를 워크스페이스로 한정. **guardrails**: `blast_radius` 정책으로 force-push·rm -rf /·원격 ref hard-reset 차단(push/PR 생성 자체는 허용) | PAT 는 credential_proxy 로 샌드박스에 상주하지 않게 했지만 parent 프로세스 침해 시에는 여전히 유출 가능 — 최소 스코프(대상 repo 한정)+짧은 만료+로테이션으로 완화. **"parent 프로세스"가 정확히 어느 컨테이너인지는 L25 에서 정정됨** (초안은 omnigent 서버 컨테이너로 잘못 가정 — 실제로는 omnigent-host 러너). registry push·재배포를 omnigent 가 airflow 로 트리거하는 것(요구사항 4)은 범위 밖 — 별도 이슈(#5, 보류)로 분리, 신규 build/push DAG 필요(airflow-stack 걸침) |
| L25 | omnigent host/server 분리 — vendor 아키텍처 재확인 결과 `ghcr.io/omnigent-ai/omnigent-server` 는 **control-plane 전용, harness 를 절대 실행하지 않음**. 실제 harness(claude-native/codex/opencode) 실행은 별도 `omnigent-host` 러너가 담당, `omnigent host --server http://omnigent:8000` 로 WS 터널(`/v1/runner/tunnel`) dial-in. 커스텀 이미지 = vendor `omnigent-host` + opencode(`npm install -g opencode-ai`, vendor 이미지엔 claude-code/codex/pi/kiro 만 baked-in) — `compose/omnigent/host/Dockerfile`, registry.internal 빌드+push. **L24 정정**: `OMNIGENT_GH_TOKEN`/RO DSN/`OMNIGENT_ANTHROPIC_API_KEY`/`OPENAI_API_KEY`(credential_proxy·하니스 인증 대상)는 harness 가 실제로 실행되는 **omnigent-host 컨테이너**의 env — server 컨테이너가 아니다. **auth 모드**: `OMNIGENT_AUTH_ENABLED` `1`(accounts)→`0`(single-user) — self-managed host 의 터널 dial-in 이 accounts 모드에서 403 거부되기 때문. **Ollama Cloud**: `~/.omnigent/config.yaml`(host 컨테이너에 볼륨 마운트, `providers:` 블록)로 OpenAI 호환 gateway provider 연결 — harness 가 아니라 provider 설정이라 이미지 문제 아님 | self-managed host 선택(boxlite 등 대안 대비)에 따라오는 트레이드오프. **accounts→single-user 는 L22/L23 의 "심층방어" 결정과 정면 충돌** — accounts 를 잃는 대신 주 방어선은 그대로인 tailnet 전용 노출(L23, `WORKER_TAILNET_IP` 바인드)에 의존. 원래도 accounts 는 격리에 더해진 부차 계층이었다는 L23 자체 논리로 감수. **미검증(배포 시 확인 필요)**: ~~(1) worker-vm 이 OCI A1.Flex ARM64(L10)라 vendor `omnigent-host` 이미지의 arm64 매니페스트 존재 여부~~ — **확인됨**: `docker manifest inspect ghcr.io/omnigent-ai/omnigent-host:latest` 에 `linux/arm64` 매니페스트 존재, 최대 리스크 해소. (2) `OMNIGENT_AUTH_ENABLED=0` 에서 self-managed host 터널이 별도 토큰 없이 붙는지. (3) `/root/.omnigent/config.yaml` 마운트가 실제 러너 로더와 스키마가 맞는지, ollama-cloud provider 가 하니스에서 모델 소스로 노출되는지. (4) git-worker local tool 파일(`tools/python/query_*_readonly.py`)이 spec 업로드 시 omnigent-host 러너까지 어떻게 전달되는지 — server 가 함께 전송하는지 별도 배치가 필요한지 미확인. (5) `mem_limit` server 4g + host 4g 합 8g 가 하니스 동시 실행 부하에 적정한지 |
| L26 | omnigent 하니스 인증 = 웹 구독(API 키 아님) — Claude: `claude setup-token`(로컬 1회 브라우저 인증)으로 만든 장기 토큰을 `CLAUDE_CODE_OAUTH_TOKEN` 으로 주입, portable(컨테이너 내 로그인 불필요). Codex: 사용자가 ChatGPT **개인 Plus/Pro** 플랜이라 헤드리스 토큰(`CODEX_ACCESS_TOKEN`, Business/Enterprise 전용) 사용 불가 — 배포 후 `docker exec -it omnigent-host codex login --device-auth` 로 컨테이너 안에서 직접 로그인하고 `omnigent-host-codex-auth` 볼륨(`/root/.codex`)으로 결과 영속. **L25 정정**: `OMNIGENT_ANTHROPIC_API_KEY`/`OPENAI_API_KEY`(API 키)를 `CLAUDE_CODE_OAUTH_TOKEN`으로 교체, `OPENAI_API_KEY` 는 제거(개인 Codex 플랜은 API 키 경로를 쓰지 않기로 함) | 초안(L24/L25)이 API 키 사용을 가정했던 게 사용자 코드 리뷰로 드러남 — 실제로는 이미 보유한 구독을 쓰려는 의도. vendor 문서가 Codex 개인 플랜의 헤드리스 인증 자체를 지원하지 않는다고 명시(`~/.codex/auth.json` 이 1회용 refresh token이라 시크릿 주입 불가) — omnigent-host 가 disposable Modal 샌드박스가 아니라 상시 컨테이너라 device-auth 로그인이 영속 가능한 구조라 채택. ChatGPT → Settings → Security 에서 device-code login 사전 활성화가 사용자 쪽 선행 조건 |

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
