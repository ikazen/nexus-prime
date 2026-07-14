# Developer Guide

이 인프라에서 서비스를 개발·배포할 때 (또는 다른 repo 에서 인프라 자원을 참조해 설계할 때) 필요한 정보.
인프라 운영 절차는 `docs/runbook.md`, 아키텍처 전체는 `docs/architecture.md` 참조.

## 서비스 인벤토리

본 repo 가 가동하는 서비스의 단일 표. 새 워크로드는 "결합점" 열의 주소로 붙음.

| 서비스 | 호스트 | nexus network 안 | tailnet alias | 외부 HTTPS | 인증 | 비고 |
|---|---|---|---|---|---|---|
| Postgres | ops-vm | `postgres:5432` | — | — | user/pw | 공유 DB, 서비스별 DB/user 분리 발급 |
| Registry (API) | ops-vm | `registry:5000` | `registry.internal:5000` | — | 없음 | HTTP tailnet 직결, 호스트당 `insecure-registries` 1회 |
| Registry UI | ops-vm | `registry-ui:80` | `http://registry-ui.internal` | — | 없음 | 브라우저 카탈로그 |
| MinIO (S3) | mac-server | — | `http://minio.internal` | — | access/secret | fallback `<MAC_TAILNET_IP>:9000` |
| MinIO Console | mac-server | — | `http://minio-console.internal` | — | 자체 로그인 | fallback `<MAC_TAILNET_IP>:9001` |
| Prometheus | ops-vm | `prometheus:9090` | `http://prometheus.internal` | — | 없음 | tailnet 전용 |
| Grafana | ops-vm | `grafana:3000` | — | `https://grafana.<your-domain>` | 자체 로그인 | |
| Loki | ops-vm | `loki:3100` | — | — | 없음 | Promtail push 수신 |
| Alertmanager | ops-vm | `alertmanager:9093` | — | — | 없음 | Prometheus alert 라우팅 |
| statsd-exporter | ops-vm | `statsd-exporter:9125/udp` | — | — | 없음 | nexus 안에서 UDP push → Prometheus scrape |
| node-exporter | 3 노드 모두 | ops-vm: nexus 안 / worker·mac: `:9100` tailnet 직결 | — | — | 없음 | Prometheus 가 tailnet 으로 scrape |
| Neo4j | ops-vm | `neo4j:7474` (HTTP) | `http://neo4j.internal` | — | neo4j/pw | bolt: `<OPS_TAILNET_IP>:7687` 직결 |
| Caddy edge | ops-vm | — | — | 443 | — | 모든 외부 라우팅 진입점 |
| pot-of-greed API | ops-vm | `pot-of-greed-api:8000` | `http://pot-of-greed-api.internal` | — | JWT | 앱 워크로드 (본 repo `compose/pot-of-greed/`). Postgres+Neo4j+Ollama 의존 |
| pot-of-greed UI | ops-vm | `pot-of-greed-ui:8000` | `http://pot-of-greed-ui.internal` | — | Chainlit auth | 공개 노출 시 Caddyfile `POT_OF_GREED_DOMAIN` 블록 주석 해제 |
| omnigent | worker-vm | 없음 (nexus 밖) | `http://agent.internal` | — | single-user (L25) | meta-harness control-plane. harness 는 실행 안 함 — 실제 실행은 `omnigent-host` 러너(같은 compose, 인바운드 없음). 위치·노출 격리는 L23, Postgres 는 ops-vm 을 tailnet 직결 |

**dnsmasq / promtail 은 인프라 plumbing — 워크로드가 직접 호출하지 않음.**

## 자원 메뉴 (신규 워크로드용)

새 서비스가 인프라 자원을 필요로 할 때, 무엇을 고르고 어디로 가서 절차를 따를지:

| 필요한 자원 | 선택 | 절차 위치 |
|---|---|---|
| RDB (영구 데이터) | Postgres `airflow` DB 와 분리된 신규 DB + user | 본 문서 "Postgres DB 발급" |
| 객체 스토리지 (S3) | MinIO 신규 버킷 + access key | MinIO Console 에서 발급, endpoint 는 인벤토리 표 |
| 컨테이너 이미지 호스팅 | self-hosted registry | 본 문서 "Private Registry" |
| 외부 HTTPS 노출 (사람용 UI) | Caddy + 외부 DNS | 본 문서 "신규 서비스 추가 체크리스트" 3번 (외부 노출) |
| 내부 HTTP 노출 (`<svc>.internal`, tailnet) | Caddy `.internal` 블록 | 본 문서 "신규 서비스 추가 체크리스트" 3번 (내부 노출) |
| 메트릭 수집 | Prometheus scrape | `compose/monitoring/prometheus.yml` 에 scrape job 추가 (nexus 안이면 컨테이너명, 밖이면 tailnet IP) |
| 메트릭 push (UDP statsd) | statsd-exporter | nexus network 안에서 `statsd-exporter:9125/udp` push |
| 로그 수집 | Loki (Promtail 자동 수집) | nexus 안 컨테이너 stdout 은 ops-vm promtail 가 자동, worker/mac 컨테이너는 호스트의 promtail config 갱신 |
| 실행 호스트 선택 | ops-vm (always-on, 자원 12 GB 공유) / worker-vm (always-on, 사설) / mac-server (M1, intermittent) | 자원·항상성·노출 요구로 결정 — `docs/architecture.md` 토폴로지 참조 |

**규칙: 자원이 nexus network 안에 있으면 컨테이너 이름으로, tailnet 노드 간이면 `.internal` 또는 tailnet IP 로 결합한다.**

## Private Registry

인증 없음. HTTP registry라 `insecure-registries` 등록이 호스트당 1회 필요.

**Linux (ops-vm, worker-vm)**:
```bash
echo '{"insecure-registries": ["registry.internal:5000"]}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
```

**mac-server (Colima)**:
```yaml
# ~/.colima/default/colima.yaml
docker:
  insecure-registries:
    - registry.internal:5000
```
`colima restart` 후 주소도 `registry.internal:5000/<name>:<tag>` 로.
DNS 미작동 시 fallback: `<OPS_TAILNET_IP>:5000`.

**push / pull**:
```bash
docker tag <image> registry.internal:5000/<name>:<tag>
docker push registry.internal:5000/<name>:<tag>
docker pull registry.internal:5000/<name>:<tag>
```

## MinIO

- **S3 endpoint**: `http://minio.internal`
- **Console**: `http://minio-console.internal`
- **자격증명**: `secrets-backup.md` 참조

### 버킷 + Access Key 발급

1. `http://minio-console.internal` 접속
2. **Buckets** → Create Bucket → 버킷명 지정
3. **Access Keys** → Create Access Key → 저장 (재조회 불가)

### macOS 로컬 마운트 (rclone)

tailnet 연결 상태에서 진행.

**사전 요구사항**

- macFUSE 설치: `brew install --cask macfuse`
  - 설치 후 시스템 설정 → 개인 정보 보호 및 보안 → "확인된 개발자가 배포한 커널 확장 프로그램의 사용자 관리 허용" 켜기 → 재부팅
- rclone 공식 바이너리 설치 (Homebrew 버전은 mount 미지원):
  ```bash
  curl https://rclone.org/install.sh | sudo bash
  ```

**remote 설정 (MinIO 서버당 1회)**

`~/.config/rclone/rclone.conf` 에 직접 추가:

```ini
[minio]
type = s3
provider = Other
access_key_id = <access-key>
secret_access_key = <secret-key>
endpoint = http://minio.internal
```

**마운트 — 버킷마다 경로 지정, remote 설정 재사용**

```bash
mkdir -p ~/mnt/<버킷명>
rclone mount minio:<버킷명> ~/mnt/<버킷명> --vfs-cache-mode writes --dir-cache-time 10s --daemon

# 여러 버킷 동시 마운트 가능
rclone mount minio:<버킷2> ~/mnt/<버킷2> --vfs-cache-mode writes --dir-cache-time 10s --daemon

# 언마운트
umount ~/mnt/<버킷명>
```

**재부팅 후 자동 마운트 (LaunchAgent)**

```bash
cat > ~/Library/LaunchAgents/com.rclone.minio.<버킷명>.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.rclone.minio.<버킷명></string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/rclone</string>
        <string>mount</string>
        <string>minio:<버킷명></string>
        <string>/Users/<your-username>/mnt/<버킷명></string>
        <string>--vfs-cache-mode</string>
        <string>writes</string>
        <string>--dir-cache-time</string>
        <string>10s</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.rclone.minio.<버킷명>.plist
```

## Postgres DB 발급

ops-vm SSH 접속 후 실행:
```bash
ssh ops-vm
docker exec -it postgres psql -U postgres -c "CREATE DATABASE <db>;"
docker exec -it postgres psql -U postgres -c "CREATE USER <user> WITH PASSWORD '<pw>';"
docker exec -it postgres psql -U postgres -c "GRANT ALL ON DATABASE <db> TO <user>;"
docker exec -it postgres psql -U postgres -c "\c <db>"
docker exec -it postgres psql -U postgres -c "GRANT ALL ON SCHEMA public TO <user>;"
```

### Postgres read-only role 발급

다른 서비스 DB 를 읽기만 해야 하는 경우 (예: omnigent 의 cross-DB 조회 — 실사용: `omnigent_ro` 가 reflexion-rondo DB, pot-of-greed DB 에 각각 발급됨) — 전용 DB/user 대신 대상 DB 에 read-only role 을 추가로 발급:
```bash
ssh ops-vm
docker exec -it postgres psql -U postgres -c "CREATE USER <svc>_ro WITH PASSWORD '<pw>';"
docker exec -it postgres psql -U postgres -c "GRANT CONNECT ON DATABASE <target_db> TO <svc>_ro;"
docker exec -it postgres psql -U postgres -d <target_db> -c "GRANT USAGE ON SCHEMA public TO <svc>_ro;"
docker exec -it postgres psql -U postgres -d <target_db> -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO <svc>_ro;"
docker exec -it postgres psql -U postgres -d <target_db> -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO <svc>_ro;"
```

## capability 브로커 원칙 (L21 연장)

원격 자원에 직접 자격증명을 쥐어주는 대신, 필요한 결과만 내주는 좁은 통로를 둔다 (issue #1, L21 일반화):

| 요청 | 직접 (지양) | 브로커 (권장) |
|---|---|---|
| 원격 상태 파악 | SSH | Prometheus/Loki 읽기 |
| 인프라 변경(build/push/GC) | docker.sock | airflow DAG 트리거 (ops 큐 전용, L21) |
| 타 서비스 DB 읽기 | superuser / 광범위 GRANT | 위 read-only role |

## omnigent git-worker 셋업

omnigent 를 "외주 직원"처럼 쓰는 에이전트(`compose/omnigent/agents/git-worker/`) —
repo 를 clone·수정·push·PR 생성까지 하되, 로컬 파일·임의 네트워크는 격리한다.
설계 근거: `docs/decisions.md` L24, L25.

**중요**: 이 에이전트가 실제로 실행되는 곳은 `omnigent` 서버 컨테이너가 **아니라
`omnigent-host` 러너 컨테이너**다 (L25 — 서버는 control-plane 전용, harness 를
실행하지 않는다). 아래 `credential_proxy`/local tool 이 읽는 env 는 전부
`omnigent-host` 의 env 여야 한다.

### GitHub 인증 (fine-grained PAT)

1. https://github.com/settings/personal-access-tokens/new 에서 발급:
   - **Repository access**: 대상 repo 만 선택 (Resource owner 는 본인 계정)
   - **Permissions**: Contents = Read and write, Pull requests = Read and write,
     Metadata = Read-only (자동). 그 외 전부 No access
   - **Expiration**: 짧게 설정 + 주기적 로테이션
2. 값을 `OMNIGENT_GH_TOKEN` 으로 `worker-vm.enc.env` 에 저장 (SOPS 재암호화) —
   `compose/omnigent/compose.yml` 의 `omnigent-host` 서비스가 소비한다.

에이전트 안에서 이 토큰은 원문으로 노출되지 않는다 — `os_env.sandbox.credential_proxy`
(`gh_basic` preset)가 parent 프로세스에서만 실제 값을 읽고, 샌드박스 안 `git`/`gh` 에는
합성 placeholder 만 보인다(github.com 아웃바운드에만 실제 토큰 첨부). `credential_proxy`
는 `sandbox.egress_rules` 가 non-empty, `sandbox.type` 이 `linux_bwrap`/`darwin_seatbelt`
여야 동작 — macOS 의 `gh_basic` 은 미지원이지만 worker-vm 은 Linux 라 해당 없음.

### 인터랙티브 세션 GitHub 인증

사용자가 agent.internal 웹 UI 에서 직접 만드는 세션(git-worker 가 아닌 일반 세션)은 위
`credential_proxy` 경로를 타지 않아 기본적으로 `git`/`gh` 인증이 없다 — private repo clone
이 404 로 실패한다.

**PAT 발급** (git-worker 의 `OMNIGENT_GH_TOKEN` 과 별개 토큰, scope 재사용 금지):

1. https://github.com/settings/personal-access-tokens/new
   - Resource owner: 본인 계정
   - Repository access: 인터랙티브로 다룰 repo 만 선택 (Selected repositories)
   - Permissions: Contents = Read and write, Pull requests = Read and write,
     Issues = Read and write (이슈 생성·댓글·close 워크플로 사용 시 필요), Metadata = Read-only.
     그 외 No access
   - Expiration: 짧게 + 주기적 로테이션
2. 값을 `OMNIGENT_INTERACTIVE_GH_TOKEN` 으로 `worker-vm.enc.env` 에 저장(SOPS 재암호화) —
   `omnigent-host` 서비스가 소비.

**동작 방식**: `omnigent-host` 기동 command wrapper 가 이 값을 `/root/.git-credentials` +
`gh auth login` 으로 물질화한 뒤 `exec omnigent host` 전에 `unset` 한다. 이후 host 프로세스가
spawn 하는 어떤 세션의 env 에도 원문 토큰이 남지 않는다 — 인터랙티브 세션은 물질화된
credential 파일을 그대로 읽어 인증되고, git-worker 샌드박스는 애초에 이 토큰을 보지 않는다
(자기 `OMNIGENT_GH_TOKEN` 만 씀).

**주의**: 인터랙티브 세션 자체는 git-worker 와 달리 격리 샌드박스가 아니다 — 세션 안에서
`cat ~/.git-credentials` 하면 토큰 원문이 보인다. scope 를 Selected repositories + 필요
권한만으로 좁게 유지하는 게 유일한 방어선이다.

**검증**: 배포 후 인터랙티브 세션에서 `git clone`/`gh repo view` 로 대상 repo 인증 확인.
`docker exec omnigent-host sh -c 'tr "\0" "\n" < /proc/1/environ | grep INTERACTIVE'` 가
빈 결과여야 함(host 프로세스 env 에 unset 반영 확인).

### DB read-only 조회

`egress_rules` 를 켜면 샌드박스의 유일한 아웃바운드가 HTTP(S) MITM 프록시가 되어 Postgres
raw TCP 는 나갈 수 없다. 그래서 DB 조회는 `os_env` 밖의 local tool 로 둔다 — local tool 은
(별도 `container_image` 지정이 없으면) parent 프로세스에서 실행되므로
`OMNIGENT_RONDO_RO_URL`/`OMNIGENT_POG_RO_URL`(`omnigent_ro` role DSN)을 직접 읽어도
안전하다 — 에이전트는 tool 결과 행만 본다. 구현:
`compose/omnigent/agents/git-worker/tools/python/query_{rondo,pog}_readonly.py`
(`@tool` 데코레이터, 파일명 = tool 이름).

### omnigent host 이미지 빌드

`omnigent-host` 는 vendor 이미지에 opencode 만 얹은 커스텀 이미지
(`compose/omnigent/host/Dockerfile`, 근거: L25).

worker-vm 은 ARM64(OCI A1.Flex) — vendor 이미지는 linux/arm64 매니페스트 지원.
`opencode-ai` npm 패키지의 arm64 네이티브 의존성 빌드는 QEMU 에뮬레이션보다
**worker-vm 네이티브 빌드**로 검증하는 게 안전:

```bash
ssh worker-vm
cd ~/nexus-prime
docker build --build-arg OMNIGENT_HOST_TAG=<tag> \
  -t registry.internal:5000/omnigent-host:<tag> compose/omnigent/host
docker push registry.internal:5000/omnigent-host:<tag>
```

OpenCode 의 Ollama Cloud provider 설정은 이미지가 아니라 아래 "OpenCode — Ollama Cloud"
절에서 다룬다 — 재빌드 불필요.

### omnigent 하니스 구독 인증

Claude/Codex 는 API 키가 아니라 **웹 구독**을 쓴다 — 근거·트레이드오프는 `docs/decisions.md` L26.

**Codex 는 사용자 요청으로 현재 보류 중** — 아래 절차는 참고용으로 남겨두고, 재개 시
그대로 따르면 된다.

**Claude — portable, 컨테이너 로그인 불필요:**

```bash
# 로컬 머신(Claude Code CLI 로그인 되어 있는 곳)에서 1회
claude setup-token
```

출력된 토큰을 `CLAUDE_CODE_OAUTH_TOKEN` 으로 `worker-vm.enc.env` 에 저장. `ANTHROPIC_API_KEY`
/ `OMNIGENT_ANTHROPIC_API_KEY` 와 동시에 설정하지 말 것 — raw API 키가 우선 인식되어
구독 대신 종량 과금으로 갈 수 있다.

**Codex — 개인 ChatGPT Plus/Pro 는 헤드리스 토큰이 없음** (`~/.codex/auth.json` 이 1회용
refresh token 이라 시크릿 주입 불가, `CODEX_ACCESS_TOKEN` 은 Business/Enterprise 전용).
대신 **컨테이너 안에서 직접 로그인**하고 결과를 볼륨(`omnigent-host-codex-auth:/root/.codex`)
으로 영속시킨다:

1. ChatGPT → Settings → Security 에서 device-code login 활성화 (사전 1회, 웹에서 직접)
2. omnigent-host 배포 후:
   ```bash
   docker exec -it omnigent-host codex login --device-auth
   ```
   화면에 뜨는 코드/URL 로 브라우저에서 인증 완료.
3. 컨테이너 재기동 후에도 `/root/.codex` 볼륨이 살아있으니 재로그인 불필요 —
   `docker compose down`(볼륨 유지) 은 안전, `docker volume rm omnigent-host-codex-auth`
   하면 다시 로그인해야 함.

### OpenCode — Ollama Cloud

OpenCode 는 omnigent 의 provider 설정을 읽지 않고 자기 config 를 독립 관리한다. 헤드리스
컨테이너라 vendor 의 인터랙티브 `/connect` 대신 커스텀 provider 를 정적 JSON 으로 등록,
`https://ollama.com/v1` 에 direct API(Bearer) 로 직접 붙는다 — 사이드카 없음. 설계 근거:
`docs/decisions.md` L27/L28.

**설정**:
1. https://ollama.com/settings/keys 에서 API 키 발급 → `OLLAMA_API_KEY` 로
   `worker-vm.enc.env` 에 저장(`omnigent-host` 컨테이너가 소비, wrapper 가 파일로 옮김).
2. `compose/omnigent/host/opencode.json` 의 `provider.ollama-cloud.models` 맵과
   `whitelist` 를 실제 쓸 cloud 모델 ID 로 맞춘다(현재 `glm-5.2:cloud` —
   https://ollama.com/search?c=cloud 에서 카탈로그 확인).
3. 배포 후 검증: `docker exec omnigent-host cat /root/.secrets/ollama_api_key | wc -c`
   로 파일이 정상 생성됐는지(값 자체는 출력하지 말 것). cloud 모델은 로컬 다운로드가
   없으므로 별도 pull 불필요.

**세션 모델 지정은 `opencode.json` 이 아니라 `PATCH /v1/sessions/{id}` 로 한다** — 최상위
`model`/`small_model` 키는 병합되지 않는 죽은 설정이다(`docs/decisions.md` L28). 실제로
모델을 강제하려면:

```bash
curl -X PATCH http://agent.internal/v1/sessions/<session_id> \
  -H "Content-Type: application/json" \
  -d '{"model_override":"ollama-cloud/glm-5.2:cloud"}'
```

(또는 웹 UI 모델 스위처로 첫 메시지 전 선택.) 미지정 시 라이브 모델 디스커버리가 단종
모델을 자동 선택해 세션이 조용히 죽을 수 있다 — `whitelist` 로 방어되지만 확실한 건
`model_override` 명시다.

인터랙티브 로그인이 없으므로(Codex 와 대조적으로) 배포 자동화에 별도 수동 개입이
필요 없다.

## 신규 서비스 추가 체크리스트

1. `compose/<svc>/compose.yml` 작성 — 기존 서비스(`compose/postgres/` 등) 복사 후 치환.
   필수 항목:
   ```yaml
   networks:
     nexus:
       external: true
   ```

2. `compose/_hosts/ops-vm.yml` include 에 한 줄 추가:
   ```yaml
   - path: ../<svc>/compose.yml
   ```

3. 내부 노출 (`<svc>.internal`, tailnet 전용):
   ```
   # compose/caddy/Caddyfile 에 추가
   http://<svc>.internal {
       reverse_proxy <svc>:<port>
   }
   ```
   외부 노출 (`{$SVC_DOMAIN}`) 이면 추가로:
   - `ops-vm.env` 에 `SVC_DOMAIN=<your-domain>` 추가
   - `compose/caddy/compose.yml` 의 `environment:` 에 `SVC_DOMAIN: ${SVC_DOMAIN}` 추가
   - Caddyfile 에 HTTPS 블록 추가

4. Postgres DB/user 필요 시 → 위 섹션 참조.

5. 이미지가 self-host registry 라면:
   ```bash
   docker build -t registry.internal:5000/<svc>:<tag> .
   docker push registry.internal:5000/<svc>:<tag>
   ```

## 사용 예: airflow-stack

본 인프라 위에 워크로드 layer 가 어떻게 결합하는지 — 새 워크로드 설계 시 baseline.

- **Postgres**: `airflow` DB + `airflow` user (서비스별 분리, L4)
- **Docker network**: 3 노드 모두 `nexus` external join. 컨테이너는 호스트 별 compose, network 로 결합
- **Registry**: `@task.docker(image=registry.internal:5000/<name>:<tag>)` 로 태스크 이미지 참조
- **MinIO**: 데이터 lake (S3 API), DAG 가 `http://minio.internal` 로 접근
- **메트릭**: airflow 가 nexus 안 `statsd-exporter:9125/udp` 로 push → Prometheus scrape → Grafana 대시보드
- **로그**: 각 호스트 promtail 이 컨테이너 stdout 수집 → Loki
- **외부 노출**: Caddy 가 `airflow.<your-domain>` → `api-server:8080` proxy. `/edge_worker/v1/*` 는 공인 차단, 워커는 Tailscale 직결 (L11)

근거 결정: `docs/decisions.md` L4 / L11 / L13 / L15. 워크로드 자체 결정은 `airflow-stack/docs/decisions.md`.
