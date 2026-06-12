#!/usr/bin/env bash
# ops-vm 배포 스크립트.
# 사전 조건: git push 완료, ~/.ssh/config 에 ops-vm 항목 설정.
set -euo pipefail

OPS_VM="${OPS_VM_HOST:-ops-vm}"

echo "=== ops-vm 배포 시작 ==="

echo "--- git pull ---"
ssh "$OPS_VM" "cd ~/nexus-prime && git pull"

echo "--- alertmanager.yml 전송 ---"
scp "$(dirname "$0")/../compose/monitoring/alertmanager.yml" \
    "$OPS_VM:~/nexus-prime/compose/monitoring/alertmanager.yml"

echo "--- ops-vm.env 복호화 ---"
ssh "$OPS_VM" "cd ~/nexus-prime && sops --input-type dotenv --output-type dotenv -d compose/_hosts/ops-vm.enc.env > compose/_hosts/ops-vm.env"

echo "--- dnsmasq 재빌드 ---"
ssh "$OPS_VM" "cd ~/nexus-prime && docker compose -f compose/_hosts/ops-vm.yml --env-file compose/_hosts/ops-vm.env build dnsmasq"

echo "--- compose up -d ---"
ssh "$OPS_VM" "cd ~/nexus-prime && docker compose -f compose/_hosts/ops-vm.yml --env-file compose/_hosts/ops-vm.env up -d"

echo "--- 컨테이너 상태 확인 ---"
ssh "$OPS_VM" "docker compose -f ~/nexus-prime/compose/_hosts/ops-vm.yml --env-file ~/nexus-prime/compose/_hosts/ops-vm.env ps"

echo "=== 배포 완료 ==="
