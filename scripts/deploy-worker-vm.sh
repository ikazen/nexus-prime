#!/usr/bin/env bash
# worker-vm 배포 스크립트.
# 사전 조건: git push 완료, ~/.ssh/config 에 worker-vm 항목 설정.
set -euo pipefail

WORKER_VM="${WORKER_VM_HOST:-worker-vm}"

echo "=== worker-vm 배포 시작 ==="

echo "--- git pull ---"
ssh "$WORKER_VM" "cd ~/nexus-prime && git pull"

echo "--- worker-vm.env 복호화 ---"
ssh "$WORKER_VM" "cd ~/nexus-prime && sops --input-type dotenv --output-type dotenv -d compose/_hosts/worker-vm.enc.env > compose/_hosts/worker-vm.env"

echo "--- compose up -d ---"
ssh "$WORKER_VM" "cd ~/nexus-prime && docker compose -f compose/_hosts/worker-vm.yml --env-file compose/_hosts/worker-vm.env up -d"

echo "--- 컨테이너 상태 확인 ---"
ssh "$WORKER_VM" "docker compose -f ~/nexus-prime/compose/_hosts/worker-vm.yml --env-file ~/nexus-prime/compose/_hosts/worker-vm.env ps"

echo "=== 배포 완료 ==="
