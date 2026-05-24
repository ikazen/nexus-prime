#!/usr/bin/env bash
# OCI A1.Flex Always Free 의 "Out of host capacity" 대비 tofu apply retry loop.
# ops-vm 먼저 retry, 성공 후 worker-vm, 마지막 나머지.
#
# 사용:
#   cd nexus-prime/tofu
#   ./retry-apply.sh
#
# 환경변수:
#   SLEEP_SECONDS=60    각 시도 간격 (기본 60 초)
#   MAX_ATTEMPTS=200    최대 시도 횟수 (기본 200 ≈ 3 시간)
#
# Ctrl-C 로 중단 가능. 부분 성공 시 tofu state 에 반영됨 → 재실행 안전.

set -uo pipefail

SLEEP_SECONDS="${SLEEP_SECONDS:-60}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-200}"

retry() {
  local target="$1"
  local n=0
  while (( n < MAX_ATTEMPTS )); do
    n=$((n + 1))
    echo "[$(date +%H:%M:%S)] 시도 $n / $MAX_ATTEMPTS — $target"
    if tofu apply -auto-approve -target="$target"; then
      echo "[$(date +%H:%M:%S)] 성공 — $target"
      return 0
    fi
    echo "[$(date +%H:%M:%S)] fail — ${SLEEP_SECONDS}s 후 재시도"
    sleep "$SLEEP_SECONDS"
  done
  echo "최대 시도 ($MAX_ATTEMPTS) 초과 — 중단"
  return 1
}

retry oci_core_instance.ops_vm    || exit 1
retry oci_core_instance.worker_vm || exit 1

echo "=== 나머지 리소스 적용 ==="
tofu apply -auto-approve
