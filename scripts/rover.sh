#!/usr/bin/env bash
# ops-vm 에 rover 를 띄운다.
# tailnet 내 어디서든 http://oci-vm-ops:9000 으로 접근 가능.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOFU_DIR="$SCRIPT_DIR/../tofu"
REMOTE_USER=ubuntu
REMOTE_HOST=oci-vm-ops
REMOTE_PLAN=/home/ubuntu/rover-plan.json

cd "$TOFU_DIR"

echo "=== plan 생성 ==="
tofu plan -out=rover.tfplan
tofu show -json rover.tfplan > rover-plan.json
rm rover.tfplan

echo "=== ops-vm 업로드 ==="
scp rover-plan.json "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PLAN"
rm rover-plan.json

echo "=== rover 기존 컨테이너 정리 ==="
ssh "$REMOTE_USER@$REMOTE_HOST" 'docker rm -f rover 2>/dev/null || true'

echo "=== rover 시작 ==="
ssh "$REMOTE_USER@$REMOTE_HOST" \
  "docker run -d --name rover -p 9000:9000 \
    -v $REMOTE_PLAN:/src/plan.json:ro \
    im2nguyen/rover -planJSONPath /src/plan.json"

echo ""
echo "http://oci-vm-ops:9000"
