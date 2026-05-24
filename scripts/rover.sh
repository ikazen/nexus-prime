#!/usr/bin/env bash
# plan.json 생성 후 ops-vm 의 rover 컨테이너가 참조하는 경로에 업로드.
# rover 는 compose/_hosts/ops-vm.yml 에 포함된 상시 서비스.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOFU_DIR="$SCRIPT_DIR/../tofu"
REMOTE=ubuntu@oci-vm-ops
REMOTE_PLAN=/home/ubuntu/nexus-prime/compose/rover/plan.json

cd "$TOFU_DIR"

echo "=== plan 생성 ==="
tofu plan -out=rover.tfplan
tofu show -json rover.tfplan > rover-plan.json
rm rover.tfplan

echo "=== ops-vm 업로드 ==="
scp rover-plan.json "$REMOTE:$REMOTE_PLAN"
rm rover-plan.json

echo "=== rover 재시작 (새 plan 반영) ==="
ssh "$REMOTE" 'docker restart rover'

echo ""
echo "http://oci-vm-ops:9000"
