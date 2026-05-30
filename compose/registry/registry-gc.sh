#!/usr/bin/env bash
# 태그 retention → GC 2 단계. systemd timer (registry-gc.timer) 가 주 1 회 호출.
# OPS_TAILNET_IP 는 systemd unit 의 EnvironmentFile (compose/_hosts/ops-vm.env) 에서 주입.
set -euo pipefail

KEEP="${REGISTRY_KEEP:-5}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[registry-gc] retention 시작 (keep=$KEEP)"
python3 "$HERE/retention.py" --registry-url "http://${OPS_TAILNET_IP}:5000" --keep "$KEEP"

echo "[registry-gc] garbage-collect (untagged 포함)"
docker exec registry registry garbage-collect -m /etc/docker/registry/config.yml

echo "[registry-gc] 완료"
