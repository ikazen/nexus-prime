# mac-server (M1)

intermittent gpu/default airflow worker + MinIO (data lake). 인프라 책임 = Colima 시동 + LaunchAgent.

## 셋업

```
# Homebrew + Colima
brew install colima docker docker-compose

# Colima 시동 (자원은 워크로드에 맞춰)
colima start --cpu 4 --memory 8 --vm-type vz

# 자동 시동 LaunchAgent
cp hosts/mac-server/launchd/local.airflow.colima.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/local.airflow.colima.plist
```

## MinIO (인프라 컨테이너)

```bash
cd nexus-prime
cp compose/_hosts/mac-server.env.example compose/_hosts/mac-server.env
$EDITOR compose/_hosts/mac-server.env   # MINIO_ROOT_PASSWORD 설정

docker compose -f compose/_hosts/mac-server.yml --env-file compose/_hosts/mac-server.env up -d
```

- S3 API: `http://localhost:9000` (tailnet 내: `http://minio.internal`)
- Console: `http://localhost:9001` (tailnet 내: `http://minio-console.internal`)
- `restart: unless-stopped` → Colima 재시동 시 자동 복구

이후 airflow workload (edge worker) 는 별도 repo — airflow-stack 의 `infra/mac-server/` 참조.

재부팅·OS 업데이트·sleep/wake 후 복구는 `scripts/recover-mac-server.sh` — 절차는 `docs/runbook.md`
"mac-server 재부팅 / OS 업데이트 후 복구".

## Colima 자원 변경

```
colima stop && colima start --cpu 6 --memory 8
# 설정은 ~/.colima/default/colima.yaml 저장 → LaunchAgent 가 다음 부팅부터 같은 값으로 자동 시동
```

## LaunchAgent 중지

```
launchctl unload ~/Library/LaunchAgents/local.airflow.colima.plist
# foreground 모드라 colima 도 같이 죽음
```

## plist 의 `${HOME}` 보간

macOS launchd 가 `${HOME}` 자동 보간 안 함. 동작 안 하면 plist 안 절대경로로 수정 (`/Users/<your-user>/Library/Logs/...`). 로컬 plist 만 편집 — git 에 안 박힘.

## Docker (DOCKER_HOST)

SSH 비대화형에서 `docker` 가 Colima socket 미인식 방지. `~/.zshrc`:

```bash
export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"
```

## node_exporter

```
brew install node_exporter
cp hosts/mac-server/launchd/local.node_exporter.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/local.node_exporter.plist
```

## Promtail

`compose/_hosts/mac-server.yml` 에 포함됨 — MinIO 와 함께 기동.

`mac-server.env` 에 `OPS_TAILNET_IP` 설정 후 compose up 하면 자동 기동. Colima VM 내부에서 `/var/run/docker.sock` 과 `/var/lib/docker/containers` 에 직접 접근하므로 경로 문제 없음.

## rclone MinIO 마운트

MinIO 버킷을 로컬 디렉터리로 마운트. 마운트 경로와 버킷명은 `rclone-minio-mount.sh` 상단 변수에서 변경.

**사전 설치**

```bash
brew install --cask macfuse   # FUSE 드라이버, 설치 후 재부팅 필요
brew install rclone
```

**rclone 설정**

```bash
rclone config
# New remote → name: minio
# Storage: s3 → provider: Minio
# Access key / Secret key: mac-server.env 의 MINIO_ROOT_USER / PASSWORD
# Endpoint: http://localhost:9000
# 나머지 기본값
```

**버킷 생성**

MinIO Console (`http://localhost:9001`) 에서 버킷 생성 (기본값: `models`).

**LaunchAgent 등록**

```bash
cp hosts/mac-server/launchd/local.rclone-minio.plist ~/Library/LaunchAgents/
# ${HOME} 보간 문제 → plist 안 경로를 절대경로로 수정 후 로드 (위 plist 의 ${HOME} 보간 참조)
launchctl load ~/Library/LaunchAgents/local.rclone-minio.plist
```

확인: `ls ~/minio/models`

## claude 자동 ping 용 SSH 키 (daily_claude_ping DAG)

`airflow-stack` 의 `daily_claude_ping` DAG 가 이 호스트의 claude CLI 를 원격 실행한다.
claude 인증은 macOS 로그인 키체인에 저장돼 있고, **키체인은 SSH 로그인(PAM 인증)을
거친 세션에서만 언락된다** — launchd 등 데몬 프로세스에서 기동한 프로세스는 동일 유저라도
키체인 접근이 막힌다(실측 확인됨). 그래서 상주 브리지 대신 매 실행마다 실제 SSH 인증을
거치는 구조를 쓴다.

전용 키를 발급하고 forced command 로 이 키가 claude ping 외 아무 것도 못 하게 제한.
재시도 루프(10회, 30초 간격)는 `airflow-claude-ping.sh` 로 분리 — mac sleep/wake 직후
claude 가 일시 실패하는 경우의 셀프 복구용이며, `authorized_keys` 한 줄 인라인으로는
조건 분기(인증 만료 감지)를 넣기 어려워 스크립트로 뺐다. **claude 인증 만료
(`Not logged in`) 는 재시도로 복구되지 않으므로 루프를 즉시 중단하고 실패 반환** —
airflow-stack DAG 가 이 메시지를 감지해 fast-fail 처리한다(retries 미소진).
DAG 쪽 스케줄은 단발 4회.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/airflow_claude_ping -N "" -C "airflow-daily-claude-ping"

# claude 실제 경로 확인
which claude

# 스크립트 배포 (nexus-prime hosts/mac-server/airflow-claude-ping.sh)
# <CLAUDE> 를 위 경로로 치환 후 배치, 실행 권한 부여
cp hosts/mac-server/airflow-claude-ping.sh ~/.local/bin/airflow-claude-ping.sh
chmod 755 ~/.local/bin/airflow-claude-ping.sh
$EDITOR ~/.local/bin/airflow-claude-ping.sh   # <CLAUDE> 치환

# authorized_keys 에 forced command + restrict 로 추가
# command= 는 셸 확장 안 됨 — $HOME 대신 절대경로 사용
PUBKEY=$(cat ~/.ssh/airflow_claude_ping.pub)
cat >> ~/.ssh/authorized_keys <<EOF
command="/Users/<your-user>/.local/bin/airflow-claude-ping.sh",restrict $PUBKEY
EOF
```

개인키(`~/.ssh/airflow_claude_ping`)는 base64 로 인코딩해 `airflow-stack` 의
`infra/ops-vm/.env` 의 `CLAUDE_SSH_KEY_B64` 에 저장 (`.env.example` 참조). repo 에는
공개키·개인키 어느 쪽도 커밋하지 않는다.

확인 (호스트에서 loopback):
```bash
ssh -i ~/.ssh/airflow_claude_ping -o BatchMode=yes <your-user>@<MAC_TAILNET_IP> ignored
```

## SSH

`ssh/config.example` 참조.
