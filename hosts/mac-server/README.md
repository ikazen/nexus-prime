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

macOS launchd 가 `${HOME}` 자동 보간 안 함. 동작 안 하면 절대경로로 수정 (`/Users/<your-user>/Library/Logs/...`). 사용자 home 경로는 git 에 안 박힘 — 로컬 mac 의 plist 만 편집.

## Promtail (monitoring 스택 R4 후속, 선택)

Colima VM 안에 docker가 있어서 `/var/lib/docker/containers` 경로가 달라 설정이 복잡함. 우선순위 낮음 — ops-vm / worker-vm 로그만으로도 대부분 커버됨.

필요 시: Colima VM 안에서 직접 promtail 실행하거나 `docker_sd_configs` 로 Colima socket 마운트.

## Docker (DOCKER_HOST)

SSH 비대화형 세션에서 `docker` 명령이 Colima socket 을 못 찾는 문제 방지. `~/.zshrc` 에 추가:

```bash
export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"
```

## node_exporter (monitoring 스택 R4)

```
brew install node_exporter

cp hosts/mac-server/launchd/local.node_exporter.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/local.node_exporter.plist
```

plist 의 `${HOME}` 보간 문제 발생 시 절대경로로 수정 (`/Users/<your-user>/Library/Logs/...`).

## SSH

`ssh/config.example` 참조.
