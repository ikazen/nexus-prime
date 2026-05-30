# worker-vm

stable airflow worker (default queue). 인프라 컨테이너 0 — airflow-stack 의 edge-worker 만.

## 셋업

```
ssh worker-vm
git clone <nexus-prime-url>
cd nexus-prime
TAILSCALE_HOSTNAME=<your-hostname> bash hosts/worker-vm/host-setup.sh
# 로그아웃 후 재로그인 (docker 그룹 적용)
```

이후 airflow workload (edge worker) 는 별도 repo — airflow-stack 의 `infra/worker-vm/` 참조.

## Promtail 설정 (host-setup.sh 실행 후)

host-setup.sh 가 바이너리 설치까지만 함. config 생성 후 활성화 필요:

```
sudo mkdir -p /etc/promtail
sudo cp ~/nexus-prime/compose/monitoring/promtail-node.yml.example /etc/promtail/promtail.yml
sudo vi /etc/promtail/promtail.yml  # ${OPS_TAILNET_IP} 실제 값으로 치환 (HOSTNAME 은 자동)
sudo systemctl enable --now promtail
```

이미 설치된 경우 config 갱신 후 재시작:
```
sudo cp ~/nexus-prime/compose/monitoring/promtail-node.yml.example /etc/promtail/promtail.yml
sudo vi /etc/promtail/promtail.yml
sudo systemctl restart promtail
```

## SSH

`ssh/config.example` 참조.

## 디스크

부트만 (`tofu/instances.tf` 참조). 별도 block volume 없음.
