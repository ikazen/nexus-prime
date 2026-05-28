# Developer Guide

이 인프라에서 서비스를 개발·배포할 때 필요한 정보.
인프라 운영 절차는 `docs/runbook.md`, 아키텍처 전체는 `docs/architecture.md` 참조.

## 내부 서비스 주소

tailnet 내에서만 접근 가능. 모두 HTTP (`.internal` 도메인은 공인 인증서 없음).

| 주소 | 서비스 |
|---|---|
| `http://registry.internal` | Docker registry API |
| `http://registry-ui.internal` | Registry 브라우저 UI |
| `http://minio.internal` | MinIO S3 API |
| `http://minio-console.internal` | MinIO 관리 콘솔 |
| `http://prometheus.internal` | Prometheus |

## 인프라 결합점

| 자원 | 접근 방법 |
|---|---|
| docker network | `nexus` (`networks: { nexus: { external: true } }`) |
| postgres | `postgres:5432` (nexus network 안, 인증 필요 → 아래 참조) |
| registry | `registry.internal` 또는 `<OPS_TAILNET_IP>:5000` |
| MinIO S3 | `http://minio.internal` 또는 `<MAC_TAILNET_IP>:9000` |

## Private Registry

인증 없음. HTTP registry라 `insecure-registries` 등록이 호스트당 1회 필요.

**Linux (ops-vm, worker-vm)**:
```bash
echo '{"insecure-registries": ["registry.internal"]}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
```

**mac-server (Colima)**: Colima VM 안에서 `registry.internal` DNS 미작동 → tailnet IP 직접 사용:
```yaml
# ~/.colima/default/colima.yaml
docker:
  insecure-registries:
    - <OPS_TAILNET_IP>:5000
```
`colima restart` 후 주소도 `<OPS_TAILNET_IP>:5000/<name>:<tag>` 로.

**push / pull**:
```bash
docker tag <image> registry.internal/<name>:<tag>
docker push registry.internal/<name>:<tag>
docker pull registry.internal/<name>:<tag>
```

## MinIO

- **S3 endpoint**: `http://minio.internal`
- **Console**: `http://minio-console.internal`
- **자격증명**: `secrets-backup.md` 참조

## Postgres DB 발급

신규 서비스용 DB / user 발급:
```bash
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
   외부 노출이면 `ops-vm.env` 에 `SVC_DOMAIN` 추가 + Caddyfile 에 HTTPS 블록.

4. Postgres DB/user 필요 시 → 위 섹션 참조.

5. 이미지가 self-host registry 라면:
   ```bash
   docker build -t registry.internal/<svc>:<tag> .
   docker push registry.internal/<svc>:<tag>
   ```
