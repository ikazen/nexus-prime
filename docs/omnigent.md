# omnigent

meta-harness 에이전트 오케스트레이터(Claude Code / OpenCode / Codex). worker-vm 배치, tailnet 전용
노출. 배치 위치·노출 범위의 배경은 `docs/decisions.md` L23("노출×위치×권한" 격리 재설계).

## 2-컨테이너 구조

vendor 아키텍처가 control-plane 과 harness 실행을 분리한다(L25):

```
사용자 (tailnet) ──HTTP──> Caddy ──> agent.internal ──> omnigent (server)
                                                              │
                                                     세션 배정 (WS 터널)
                                                              ▼
                                                      omnigent-host (runner)
                                                     실제 harness 실행
                                                (claude-native / opencode / codex)
```

- **`omnigent` (server)** — control-plane 전용, harness 를 실행하지 않는다. `WORKER_TAILNET_IP:8000`
  에 바인드(Caddy 가 여기까지 reverse_proxy). Postgres(`omnigent` DB, ops-vm 을 tailnet 직결) + `omnigent-data`
  볼륨(artifacts·admin-credentials)에 상태 저장. 이미지 = vendor `omnigent-server` 그대로
- **`omnigent-host` (runner)** — 실제 harness 실행. `omnigent host --server http://omnigent:8000` 로
  WS 터널(`/v1/runner/tunnel`) dial-in, server 가 배정하는 세션을 실행. 이미지 = vendor `omnigent-host`
  + opencode·gh CLI 레이어(`compose/omnigent/host/Dockerfile`) — vendor 이미지엔
  claude-code/codex/pi/kiro-cli 는 있지만 opencode 와 gh CLI 가 없어서 얹음. worker-vm ARM64 네이티브 빌드

두 컨테이너는 `docker compose` 서비스 `depends_on: condition: service_healthy` 로 순서 보장.

## 노출·인증

- 유일한 노출은 Caddy 경유 `http://agent.internal`(tailnet 전용, 공개 도메인 없음)
- 인증 = **single-user 모드**(`OMNIGENT_AUTH_ENABLED=0`) — self-managed host 의 WS 터널이 accounts
  모드에서 403 되기 때문(L25). single-user 는 자동으로 `OMNIGENT_LOCAL_SINGLE_USER=1` 도 세팅해
  multipart 엔드포인트(세션 생성 등)를 Origin=loopback 에만 허용 — Caddy 경유 접속은 loopback 이
  아니라서 `OMNIGENT_WS_ALLOWED_ORIGINS=http://agent.internal` 로 명시 allowlist 필요(스킴 포함
  정확히 일치, 와일드카드 미지원)
- 하니스 실행 인증은 API 키가 아니라 **웹 구독**(L26) — Claude 는 `CLAUDE_CODE_OAUTH_TOKEN`(portable),
  Codex 는 컨테이너 내 device-auth 로그인이 필요해 현재 사용자 요청으로 보류
- **GitHub 인증(인터랙티브 세션)** — 사용자가 직접 만드는 세션(웹 UI)은 git-worker 의
  `credential_proxy` 경로를 타지 않아 기본적으로 GitHub 인증이 없다. `OMNIGENT_INTERACTIVE_GH_TOKEN`
  (git-worker 전용 `OMNIGENT_GH_TOKEN` 과 별개 토큰)을 `omnigent-host` 기동 wrapper 가
  `/root/.git-credentials` + `gh auth login` 으로 물질화한 뒤 `exec` 전에 `unset` — 이후
  spawn 되는 모든 세션(git-worker 샌드박스 포함) env 에는 원문 토큰이 남지 않는다. 발급·검증
  절차는 `docs/dev-guide.md` "인터랙티브 세션 GitHub 인증"
- **인터랙티브 세션 초기 워크스페이스** — `omnigent-host` 기동 wrapper 가 credential 물질화
  직후 `init-workspace.sh` 를 실행해 `~/projects/`(reflexion-rondo/pot-of-greed/
  enemy-controller/airflow-stack clone) 와 `~/.claude`(`ikazen/claude-config` 오버레이)를
  세팅한다. 자세한 내용은 아래 "인터랙티브 세션 초기 워크스페이스" 절

## 하니스 provider

| harness | 인증 | 상태 |
|---|---|---|
| claude-native | 웹 구독 토큰 (`CLAUDE_CODE_OAUTH_TOKEN`) | 사용 중 |
| opencode | Ollama Cloud direct API (`OLLAMA_API_KEY` Bearer, `https://ollama.com/v1`), 모델 `glm-5.2:cloud` | 사용 중 |
| codex | ChatGPT 개인 플랜 device-auth (컨테이너 내 1회 로그인) | 보류 |

opencode provider 설정은 omnigent 와 무관하게 독립 관리된다 — `compose/omnigent/host/opencode.json`
이 OpenCode 의 전역 config 로 마운트됨(`provider` 블록만 세션별로 병합, top-level `model` 키는
무시됨 — 세션 모델은 `PATCH /v1/sessions/{id}` 의 `model_override` 로 지정). 사이드카 없이 direct
API 로 구성한 배경은 L27/L28.

## git-worker 에이전트

`compose/omnigent/agents/git-worker/` — "외주 직원"처럼 쓰는 코딩 에이전트. 지정된 repo 를
clone·수정·push·PR 생성까지 하고, 리뷰·머지는 사람이 한다(`config.yaml` 의 `prompt`). `harness:
claude-native`, `permission_mode: auto`(헤드리스라 ApprovalCard 를 받을 사람이 없어 격리로 방어).
실제 실행 위치는 server 가 아니라 **omnigent-host 컨테이너**(L25).

**3층 격리** (`os_env.sandbox`, `linux_bwrap`):
1. **네트워크** — `egress_rules` 로 github.com/api.github.com/codeload.github.com 만 허용
   (default-deny HTTP(S) MITM 프록시). 이 필드가 켜지는 순간 샌드박스의 유일한 아웃바운드가
   MITM 프록시가 되므로 Postgres 같은 raw TCP 는 애초에 못 나감 — 그래서 DB 조회를 아래처럼 분리
2. **자격증명** — GitHub PAT(`OMNIGENT_GH_TOKEN`)은 parent 프로세스(omnigent-host)에만 존재.
   `credential_proxy`(`gh_basic`)가 github.com 아웃바운드에만 실제 토큰을 주입 — 샌드박스 안
   `git`/`gh` 는 합성 placeholder 만 봄
3. **DB** — `os_env` 밖의 local tool(`tools/python/query_{rondo,pog}_readonly.py`)로 조회.
   local tool 은 parent 프로세스에서 실행되므로 `OMNIGENT_RONDO_RO_URL`/`OMNIGENT_POG_RO_URL`
   (`omnigent_ro` role DSN)을 직접 읽어도 안전 — 에이전트는 tool 이 반환하는 결과 행만 봄.
   role 자체가 read-only 로 발급되고, tool 코드도 방어적으로 SELECT 단일 statement 만 허용

**guardrail**: `blast_radius` 정책(`gate_pushes: false`) — push/PR 생성은 허용하되 force-push·
`rm -rf /`·원격 ref hard-reset 같은 파국적 조작만 차단.

## 인터랙티브 세션 초기 워크스페이스

사용자가 직접 만드는 세션(git-worker 가 아닌 일반 세션)은 HOME(`/root`)에서 시작하는데,
매번 빈 상태면 clone 부터 시작해야 하고 사용자 CLAUDE.md 규칙·GitHub 콘텐츠 차단 훅도
없다. `compose/omnigent/host/init-workspace.sh` 가 이를 메운다 — 이미지 rebuild 없이
`opencode.json` 과 동일 패턴으로 마운트, `omnigent-host` command wrapper 가 GitHub
credential 물질화 직후·`exec omnigent host` 전에 실행:

- **`~/projects/`** — `reflexion-rondo`/`pot-of-greed`/`enemy-controller`/`airflow-stack`
  clone(전부 public repo, 인증 불필요). `omnigent-host-projects` named volume 에 영속,
  이미 존재하면 skip(사용자 로컬 작업 보존) — 최신화는 수동 pull.
- **`~/.claude`** — `ikazen/claude-config`(private) 로 오버레이. 빈 디렉토리가 아니라
  vendor 런타임 파일(cache/sessions/plugins 등)이 이미 있어 `git clone` 직접 불가 —
  `git init`+`fetch`+`checkout -f` 로 tracked config 만 덮어쓴다(claude-config 의
  `.gitignore '*'` allowlist 가 나머지 보존, 랩탑과 동일 구조). clone 인증은 인터랙티브
  세션용 GitHub PAT 재사용(Selected repositories 에 `claude-config` 포함 필요).
- **`settings.omni.json` → `settings.json` 복사** — omnigent 은 claude-native 세션을
  `--setting-sources all` 로 띄워 사용자 `~/.claude/settings.json` 의 훅을 자체 훅(정책
  평가·권한 라우팅 등, `--settings` 인라인 JSON)과 additive 병합한다(vendor
  `claude_native_bridge.py` 확인). 전체 settings.json(model/`enabledPlugins`/`tui` 등
  랩탑 전용 설정 포함)을 그대로 쓰면 헤드리스 세션에서 플러그인 자동설치·model override
  부작용 위험이 있어, claude-config 저장소에 **훅만 담은 `settings.omni.json`** 을 따로
  관리하고 init 이 이걸 `~/.claude/settings.json` 위치로 복사한다.

repo 별 실패는 격리(로그만 남기고 계속) — 한 repo clone 실패가 세션 기동을 막지 않는다.

## 파일 맵

```
compose/omnigent/
  compose.yml                       omnigent(server) + omnigent-host(runner) 정의
  host/
    Dockerfile                      vendor omnigent-host + opencode·gh CLI 레이어
    opencode.json                   OpenCode 전역 provider 설정 (Ollama Cloud)
    init-workspace.sh               인터랙티브 세션 초기 워크스페이스 (~/projects, ~/.claude)
  agents/git-worker/
    config.yaml                     에이전트 spec (prompt, 샌드박스, guardrail)
    tools/python/
      query_rondo_readonly.py       reflexion-rondo DB RO local tool
      query_pog_readonly.py         pot-of-greed DB RO local tool
```

## 상태·볼륨

`omnigent-data`(server, artifacts·admin-credentials), `omnigent-host-workspace`(git-worker 작업
디렉토리), `omnigent-host-codex-auth`(Codex 로그인 영속, 보류 중이라 현재 미사용), `omnigent-host-secrets`
(`{file:...}` 로 참조하는 Ollama Cloud 키), `omnigent-host-projects`(인터랙티브 세션
`~/projects` clone 영속) + 공유 Postgres `omnigent` DB. 백업 없음(L7 그대로 적용,
재고 트리거는 BON-264).

## 참조

- 왜(설계 결정 전체) — `docs/decisions.md` L22~L28
- 최초 배포·재배포 절차 — `docs/runbook.md` "omnigent 최초 배포 체크리스트"
- 자원 발급 절차(PAT, RO role, 이미지 빌드, Ollama Cloud 키) — `docs/dev-guide.md`
