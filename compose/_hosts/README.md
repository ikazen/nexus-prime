# _hosts wrapper

호스트별 docker compose 진입점. 그 호스트에서 띄울 모든 인프라 기능을 `include` 로 합침.

## 호스트별 현황

- `ops-vm.yml` — caddy + postgres + registry(+ui) + dnsmasq + monitoring
- `mac-server.yml` — minio
- `worker-vm.yml` — omnigent (L23 — 위치 격리, ops-vm 심장부에서 이동). airflow edge worker 는 별도 repo

## 운영

```
cd nexus-prime
docker network create nexus   # 호스트 1 회 (host-setup.sh 가 처리)
docker compose -f compose/_hosts/<host>.yml --env-file compose/_hosts/<host>.env up -d
```

`<host>.env` 는 `.env.example` 복사해서 채움.
