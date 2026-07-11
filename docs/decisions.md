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
| L22 | omnigent(meta-harness, Claude Code + OpenCode 오케스트레이션) ops-vm 배포. **stateful** — `omnigent-data` 볼륨 + 공유 Postgres `omnigent` DB. 공개 도메인 노출, 인증은 built-in accounts 모드(개인 단독 사용이라 OIDC 대신 accounts 단일 관리자 게이트, BON-262) | 공개 RCE 표면(원격 shell·파일쓰기) → accounts 인증 필수 전제. L7 재고 트리거 발동(백업 정책 미정, BON-264) — 현재는 L7 유지. **노출·위치는 L23 으로 재고됨** |
| L23 | omnigent 격리 재설계 (issue #1) — 위험을 **노출×위치×권한** 곱으로 보고 세 축 모두 인하. 노출: 공개 도메인 → `agent.internal`(tailnet 전용). 위치: ops-vm(인프라 심장부) → worker-vm(사설, always-on). 권한: DB 는 자기 DB만 read-write, cross-DB 읽기는 `omnigent_ro` role 로 별도 발급, 원격 상태파악은 SSH 대신 Prometheus/Loki, 인프라 변경은 docker.sock 대신 airflow DAG(L21 일반화) | L22 최댓값 설계(공개+심장부+공유 DB)가 RCE blast radius 를 키움 — 세 축 중 하나만 낮춰도 완화되지만 곱을 낮추는 게 최선. accounts 인증(BON-262)은 심층방어로 격하. L7 재고 트리거는 이 변경과 무관, BON-264 유지 |
| L24 | omnigent 외주 직원화 (issue #3, #4) — git-worker 에이전트(`compose/omnigent/agents/git-worker/`) 추가. **git**: fine-grained PAT(대상 repo 만 RW), `credential_proxy`(`gh_basic`)로 주입 — 실 토큰은 parent 프로세스에만, 샌드박스는 합성 placeholder 만 봄. **네트워크**: `egress_rules` 로 github.com 계열만 허용(default-deny). **DB**: rondo·pot-of-greed 에 `omnigent_ro` 추가 발급, `os_env` 밖 local tool 로 조회. **guardrails**: `blast_radius` 정책으로 force-push·`rm -rf /`·hard-reset 차단 | PAT 는 parent 프로세스 침해 시 유출 가능 — 최소 스코프+짧은 만료+로테이션으로 완화. registry push·재배포 트리거(요구사항 4)는 범위 밖, 별도 이슈(#5, 보류) |
| L25 | omnigent host/server 분리 — vendor 아키텍처 재확인 결과 `omnigent-server` 는 **control-plane 전용, harness 미실행**. 실제 harness 는 별도 `omnigent-host` 러너가 WS 터널(`/v1/runner/tunnel`)로 dial-in. 커스텀 이미지 = vendor `omnigent-host` + opencode. **L24 정정**: `OMNIGENT_GH_TOKEN`/RO DSN/하니스 인증은 server 가 아니라 **omnigent-host 컨테이너**의 env. **auth**: `OMNIGENT_AUTH_ENABLED=0`(single-user) — self-managed host 의 dial-in 이 accounts 모드에서 403 되기 때문 | self-managed host 선택의 트레이드오프. accounts→single-user 는 L22/L23 "심층방어"와 충돌하지만 주 방어선(L23 tailnet 전용 노출)은 그대로. **gotcha**: single-user 는 entrypoint 가 `OMNIGENT_LOCAL_SINGLE_USER=1` 도 세팅 — multipart 엔드포인트(세션 생성 등)가 Origin=loopback 만 허용해 Caddy 경유 `agent.internal` 이 403 됨 → `OMNIGENT_WS_ALLOWED_ORIGINS=http://agent.internal` 명시 필요(스킴 포함 정확히 일치, 와일드카드 미지원) |
| L26 | omnigent 하니스 인증 = 웹 구독(API 키 아님). Claude: `claude setup-token` 으로 만든 토큰을 `CLAUDE_CODE_OAUTH_TOKEN` 주입, portable. Codex: 개인 Plus/Pro 는 헤드리스 토큰 없음 — 배포 후 컨테이너 안에서 `codex login --device-auth`, 결과는 `/root/.codex` 볼륨에 영속. **L25 정정**: API 키(`OMNIGENT_ANTHROPIC_API_KEY`/`OPENAI_API_KEY`) 대신 구독 토큰 사용, `OPENAI_API_KEY` 제거. **Codex 는 사용자 요청으로 현재 보류** — 구현은 유지, 배포 체크리스트에서만 스킵 | 초안이 API 키를 가정했던 게 리뷰로 드러남 — 이미 보유한 구독을 쓰려는 의도. vendor 문서상 Codex 개인 플랜은 헤드리스 인증 미지원(`~/.codex/auth.json` 이 1회용 refresh token) — omnigent-host 가 상시 컨테이너라 device-auth 로그인 영속이 가능해 채택 |
| L27 | *(L28 로 대체됨)* OpenCode + Ollama Cloud 초안 — `ollama` 사이드카 경유 프록시. 헤드리스 컨테이너라 vendor 의 인터랙티브 `/connect` 대신 커스텀 provider 정적 등록으로 설계 | 실사용 중 사이드카가 불필요하다는 게 드러나 L28 에서 제거 |
| L28 | OpenCode + Ollama Cloud **재설계 — 사이드카 제거**. custom provider 가 `https://ollama.com/v1` 에 **direct API**(`OLLAMA_API_KEY` Bearer)로 직접 붙는다(Ollama Cloud 공식 headless 경로). `apiKey` 는 OpenCode 의 `{env:VAR}` 가 custom provider 에서 동작하지 않는 vendor 버그로 `{file:/root/.secrets/ollama_api_key}` 참조 — `omnigent-host` `command:` 를 wrapper 스크립트로 바꿔 파일 물질화 후 실행. 모델 = **`glm-5.2:cloud`**(Z.ai, 976K 컨텍스트) | 사이드카 제거로 컨테이너 1개·리소스 1g 절감. **운영 gotcha**: `opencode.json` 최상위 `model`/`small_model` 키는 omnigent 의 opencode-native 통합이 `provider` 블록만 병합하므로 **무시된다**(죽은 설정, 제거함) — 세션 모델을 강제하려면 `PATCH /v1/sessions/{id}` 의 `model_override`(`"ollama-cloud/glm-5.2:cloud"`) 사용. 미지정 시 provider 의 라이브 모델 디스커버리가 단종 모델까지 후보로 주워 자동선택할 수 있어(2026-07-11 `rnj-1:8b` 410 Gone 사례) `provider.ollama-cloud.whitelist: ["glm-5.2:cloud"]` 로 방어. 커스텀 agent spec(`executor.config.model`)으로 고정 시도는 효과 없어 제거 |

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
