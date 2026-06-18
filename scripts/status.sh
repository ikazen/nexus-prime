#!/usr/bin/env bash
# 인프라 현재 상태 한 방 확인 — ops-vm 에서 실행.
# tofu plan (drift) + docker compose ps + tailscale status
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$REPO_ROOT/compose/_hosts/ops-vm.env"
COMPOSE_FILE="$REPO_ROOT/compose/_hosts/ops-vm.yml"

echo "=== tofu plan (drift check) ==="
if command -v tofu >/dev/null 2>&1 && [[ -f "$REPO_ROOT/tofu/terraform.tfvars" ]]; then
  (cd "$REPO_ROOT/tofu" && tofu plan -detailed-exitcode -compact-warnings 2>&1) || true
else
  echo "tofu 미설치 또는 terraform.tfvars 없음 — 건너뜀"
fi

echo ""
echo "=== docker compose ps ==="
if [[ -f "$ENV_FILE" ]]; then
  docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps
else
  echo "ops-vm.env 없음 ($ENV_FILE) — 건너뜀"
fi

echo ""
echo "=== docker ps (전체 — ops-vm.yml 밖 워크로드 포함: airflow / rondo / pot-of-greed) ==="
docker ps --format "table {{.Names}}\t{{.Status}}" 2>&1 || echo "docker 미실행"

echo ""
echo "=== tailscale status ==="
tailscale status 2>&1 || echo "tailscale 미설치 또는 미연결"
