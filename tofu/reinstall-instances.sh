#!/usr/bin/env bash
# 인스턴스 destroy + 새로 띄움. VCN / NSG / Reserved IP 는 유지.
# 정책 (L18): 인스턴스 = immutable. 변경·복구 = destroy + create.
#
# 사용:
#   cd nexus-prime/tofu
#   ./reinstall-instances.sh
#
# 환경변수: retry-apply.sh 와 동일 (SLEEP_SECONDS / MAX_ATTEMPTS)

set -uo pipefail
cd "$(dirname "$0")"

echo "=== 인스턴스 destroy (VCN/NSG/Reserved IP 는 유지) ==="
tofu destroy -auto-approve \
  -target=oci_core_instance.ops_vm \
  -target=oci_core_instance.worker_vm

echo "=== 인스턴스 새로 띄움 (capacity retry) ==="
exec ./retry-apply.sh
