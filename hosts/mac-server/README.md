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

## claude HTTP 브리지

Airflow edge worker 는 컨테이너 안에서 돈다 — claude 는 macOS 호스트 사용자 세션에
인증돼 있어 컨테이너에서 직접 실행 불가. 이 브리지가 tailnet IP + Bearer 토큰으로
호스트 경계를 넘겨준다 (`airflow-stack` 의 `daily_claude_ping` DAG 가 호출).

claude 바이너리 경로는 설치 방식마다 다르다 (`which claude` 로 확인 — 네이티브 설치는
보통 `~/.local/bin/claude`, `/opt/homebrew/bin/claude` 아님). launchd 는 비대화형이라
PATH 가 로그인 셸과 다를 수 있어 `CLAUDE_BIN` 에 절대경로를 직접 박아준다.

```bash
which claude   # 실제 경로 확인

cp hosts/mac-server/launchd/local.claude-bridge.plist ~/Library/LaunchAgents/
# ${HOME} 보간 문제 → ProgramArguments 경로를 절대경로로 수정 (위 "plist 의 ${HOME} 보간" 참조)
# CLAUDE_BRIDGE_BIND 를 실제 <MAC_TAILNET_IP>:8765 로, CLAUDE_BRIDGE_TOKEN 을 openssl rand -hex 24 값으로 교체
# CLAUDE_BIN 을 `which claude` 결과 절대경로로 교체
# 로컬 plist 만 편집 — git 에 안 박힘

launchctl load ~/Library/LaunchAgents/local.claude-bridge.plist
```

확인:
```bash
curl -s -H "Authorization: Bearer <token>" -d '{"msg":"ㅎㅇ"}' http://<MAC_TAILNET_IP>:8765/ping
```

토큰은 airflow-stack 쪽 `infra/ops-vm/.env` 의 `CLAUDE_BRIDGE_TOKEN` 과 동일해야 함.

## SSH

`ssh/config.example` 참조.
