# ops-vm

control plane. 인프라 컨테이너 = caddy + postgres + registry. airflow workload = airflow-stack 의 api-server / scheduler / dag-processor / edge-worker-ops 가 같은 호스트에서 nexus network 공유.

## 셋업

```
ssh ops-vm
git clone <nexus-prime-url>
cd nexus-prime
TAILSCALE_HOSTNAME=<your-hostname> bash hosts/ops-vm/host-setup.sh
# 로그아웃 후 재로그인 (docker 그룹 적용)

# 인프라 컨테이너
cp compose/_hosts/ops-vm.env.example compose/_hosts/ops-vm.env
$EDITOR compose/_hosts/ops-vm.env
docker compose -f compose/_hosts/ops-vm.yml --env-file compose/_hosts/ops-vm.env up -d
```

## Registry GC 자동화 (1 회 설치)

repo 별 태그 retention + GC 를 주 1 회 실행 (`runbook.md` 의 Registry GC).

```
sudo cp hosts/ops-vm/registry-gc.service hosts/ops-vm/registry-gc.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now registry-gc.timer
```

unit 은 repo 경로를 `/home/ubuntu/nexus-prime` 로 가정 (다르면 unit 의 경로 수정).

## SSH

`ssh/config.example` 참조 — tailnet IP 또는 MagicDNS alias.

## 디스크

- 부트 150 GB. registry storage 도 부트 안 (docker named volume `registry-data`)
- 모니터링: `df -h /` + `docker system df` 주기 확인 (`runbook.md`)
