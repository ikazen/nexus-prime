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

## SSH

`ssh/config.example` 참조.

## 디스크

부트만 (`tofu/instances.tf` 참조). 별도 block volume 없음.
