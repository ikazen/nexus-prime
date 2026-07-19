#!/usr/bin/env bash
# WSL에서 실행: bash scripts/release-pog.sh <version>
#
# pot-of-greed cutover 스크립트. api+ui 이미지 빌드+push는 airflow-stack의
# `pot_of_greed_deploy` DAG(ops-vm 큐 docker.sock 재사용)가 담당한다 —
# Airflow UI에서 {"tag": "vX.Y.Z"}로 트리거하면 두 이미지를 빌드+push한다.
#
# 이 스크립트는 그 DAG가 이미 registry에 올려둔 태그를 받아 실제로 컷오버한다:
# 가드 → registry에 두 이미지 태그 존재 확인 → nexus-prime compose 태그 bump+push →
# ops-vm에서 pot-of-greed 두 서비스만 재시작 → /healthz 확인.
#
# reflexion-rondo deploy/release.sh 미러. 차이: (1) 배포 compose가 이 repo(nexus-prime)에
# 있음, (2) 이미지가 두 개(api+ui), (3) 태그가 sops가 아니라 compose.yml 평문에 박힘.
#
# 전제:
#   - WSL에 ~/projects/pot-of-greed, ~/projects/nexus-prime checkout
#   - Airflow UI에서 pot_of_greed_deploy DAG를 이 버전으로 먼저 트리거해 완료했을 것
#   - ~/.ssh/config에 ops-vm 항목, ops-vm에 ~/nexus-prime checkout
set -euo pipefail

VERSION=${1:?"Usage: bash scripts/release-pog.sh <version>  (e.g. v0.1.0) — pot_of_greed_deploy DAG로 먼저 빌드했을 것"}

REGISTRY=registry.internal:5000
OPS_VM="${OPS_VM_HOST:-ops-vm}"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NEXUS_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
COMPOSE_FILE="$NEXUS_DIR/compose/pot-of-greed/compose.yml"
POG_REPO_DIR="${POG_REPO_DIR:-$HOME/projects/pot-of-greed}"

echo "[release-pog] $VERSION"

# ---- 1. 가드 (pot-of-greed main clean/sync) ---------------------------------
# 배포 대상은 pot-of-greed main HEAD — DAG가 ref="main"으로 빌드하므로 로컬 main이
# origin/main과 일치하는 릴리스 상태여야 registry 이미지와 소스가 어긋나지 않는다.

BRANCH=$(git -C "$POG_REPO_DIR" rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" ]]; then
    echo "ERROR: pot-of-greed current branch is '$BRANCH' — release from main only"
    exit 1
fi
if ! git -C "$POG_REPO_DIR" diff --quiet || ! git -C "$POG_REPO_DIR" diff --cached --quiet; then
    echo "ERROR: pot-of-greed working tree is dirty — commit or stash first"
    exit 1
fi
git -C "$POG_REPO_DIR" fetch --quiet
LOCAL=$(git -C "$POG_REPO_DIR" rev-parse HEAD)
REMOTE=$(git -C "$POG_REPO_DIR" rev-parse origin/main)
if [[ "$LOCAL" != "$REMOTE" ]]; then
    echo "ERROR: pot-of-greed local main is not in sync with origin/main — pull first"
    exit 1
fi

# ---- 2. registry에 두 이미지 태그 존재 확인 ----------------------------------
# 빌드는 이 스크립트의 일이 아니다 — pot_of_greed_deploy DAG가 이미 만들어뒀어야 한다.
#
# Accept 헤더에 OCI 매니페스트 타입 포함 — build_and_push가 최신 buildx/BuildKit으로
# OCI 포맷(application/vnd.oci.image.manifest.v1+json)을 기본 출력하면서, 구 Docker
# media type만 요청하면 실재 이미지도 404로 오판한다(reflexion-rondo release.sh 실측 교훈).

check_image() {
    local repo=$1
    local status
    status=$(curl -o /dev/null -sw "%{http_code}" \
        "http://${REGISTRY}/v2/${repo}/manifests/${VERSION}" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json" 2>/dev/null || true)
    if [[ "$status" != "200" ]]; then
        echo "ERROR: ${REGISTRY}/${repo}:${VERSION} not found in registry (http $status)"
        echo "       Airflow UI에서 pot_of_greed_deploy DAG를 {\"tag\": \"$VERSION\"}로 먼저 트리거하세요"
        exit 1
    fi
    echo "[release-pog] ok: ${repo}:${VERSION}"
}

echo "[release-pog] checking images exist in registry ..."
check_image "pot-of-greed"
check_image "pot-of-greed-ui"

# ---- 3. 태그 bump + push (nexus-prime) --------------------------------------
# api(pot-of-greed:)와 ui(pot-of-greed-ui:)는 접두어가 겹치지만 콜론 위치가 달라
# 두 sed가 서로를 오염시키지 않는다.

echo "[release-pog] updating $COMPOSE_FILE ..."
sed -i "s|/pot-of-greed:[^[:space:]'\"]*|/pot-of-greed:$VERSION|g" "$COMPOSE_FILE"
sed -i "s|/pot-of-greed-ui:[^[:space:]'\"]*|/pot-of-greed-ui:$VERSION|g" "$COMPOSE_FILE"
if ! git -C "$NEXUS_DIR" diff --quiet "$COMPOSE_FILE"; then
    git -C "$NEXUS_DIR" commit -q -m "chore: pot-of-greed image -> $VERSION" "$COMPOSE_FILE"
    git -C "$NEXUS_DIR" push --quiet
else
    echo "[release-pog] compose already at $VERSION — no bump"
fi

# ---- 4. 재시작 (ops-vm, pot-of-greed 두 서비스만) ----------------------------
# deploy-ops-vm.sh는 전체 호스트 스택을 재배포하지만, 릴리스는 pot-of-greed 두
# 서비스만 건드린다. compose는 다른 시크릿(POG_PG_* 등)을 여전히 sops enc.env에서
# 읽으므로 --env-file은 복호화한 ops-vm.env로 유지한다.

echo "[release-pog] restarting pot-of-greed on $OPS_VM ..."
ssh "$OPS_VM" "
    set -e
    cd ~/nexus-prime
    git pull --quiet
    sops --input-type dotenv --output-type dotenv -d compose/_hosts/ops-vm.enc.env > compose/_hosts/ops-vm.env
    docker compose -f compose/_hosts/ops-vm.yml --env-file compose/_hosts/ops-vm.env pull pot-of-greed-api pot-of-greed-ui
    docker compose -f compose/_hosts/ops-vm.yml --env-file compose/_hosts/ops-vm.env up -d pot-of-greed-api pot-of-greed-ui
"

# ---- 5. 재시작 후 확인 -------------------------------------------------------
# 이미지 자체는 registry에 있고(2), 여기서는 컴포즈 배선(env/network) 문제만 잡는
# 가벼운 health 확인. pot-of-greed-api.internal은 Caddy 내부 라우트(공인 노출 없음).

echo "[release-pog] post-restart healthz check ..."
sleep 5
ssh "$OPS_VM" "curl -sf http://pot-of-greed-api.internal/healthz > /dev/null"

echo "[release-pog] $VERSION deployed successfully"
