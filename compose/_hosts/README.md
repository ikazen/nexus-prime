# _hosts wrapper

호스트별 docker compose 진입점. 그 호스트에서 띄울 모든 인프라 기능을 `include` 로 합침.

## 호스트별 현황

- `ops-vm.yml` — caddy + postgres + registry + monitoring
- `mac-server.yml` — minio
- worker-vm — **wrapper 없음**. 인프라 컨테이너 0 (airflow repo 의 edge worker 만). `hosts/worker-vm/` 참조

## 운영

```
cd nexus-prime
docker network create nexus   # 호스트 1 회만
docker compose -f compose/_hosts/<host>.yml --env-file compose/_hosts/<host>.env up -d
```

`<host>.env` 는 `.env.example` 복사해서 채움.
