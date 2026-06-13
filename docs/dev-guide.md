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
