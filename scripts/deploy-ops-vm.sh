#!/usr/bin/env bash
# ops-vm 배포 스크립트 — 맥 터미널에서 실행.
# 사전 조건: git push 완료.
set -euo pipefail

OPS_VM="ubuntu@OPS_TAILNET_IP"
ENV_FILE="$HOME/nexus-prime/compose/_hosts/ops-vm.env"

echo "=== ops-vm 배포 시작 ==="

echo "--- mac-server tailnet IP 조회 ---"
MAC_TAILNET_IP=$(tailscale ip -4)
echo "MAC_TAILNET_IP=$MAC_TAILNET_IP"

echo "--- git pull ---"
ssh "$OPS_VM" "cd ~/nexus-prime && git pull"

echo "--- ops-vm.env R4 변수 추가 (없으면) ---"
ssh "$OPS_VM" "
  add_if_missing() {
    local key=\$1 val=\$2
    grep -q \"^\$key=\" '$ENV_FILE' || echo \"\$key=\$val\" >> '$ENV_FILE'
  }
  add_if_missing GRAFANA_DOMAIN      <grafana-domain>
  add_if_missing GRAFANA_ADMIN_PASSWORD 'GRAFANA_ADMIN_PASSWORD'
  add_if_missing WORKER_TAILNET_IP   WORKER_TAILNET_IP
  add_if_missing MAC_TAILNET_IP      '$MAC_TAILNET_IP'
"

echo "--- alertmanager.yml 전송 ---"
scp "$(dirname "$0")/../compose/monitoring/alertmanager.yml" \
    "$OPS_VM:~/nexus-prime/compose/monitoring/alertmanager.yml"

echo "--- dnsmasq 재빌드 ---"
ssh "$OPS_VM" "cd ~/nexus-prime && docker compose -f compose/_hosts/ops-vm.yml --env-file compose/_hosts/ops-vm.env build dnsmasq"

echo "--- compose up -d ---"
ssh "$OPS_VM" "cd ~/nexus-prime && docker compose -f compose/_hosts/ops-vm.yml --env-file compose/_hosts/ops-vm.env up -d"

echo "--- 컨테이너 상태 확인 ---"
ssh "$OPS_VM" "docker compose -f ~/nexus-prime/compose/_hosts/ops-vm.yml --env-file ~/nexus-prime/compose/_hosts/ops-vm.env ps"

echo "=== 배포 완료 ==="
