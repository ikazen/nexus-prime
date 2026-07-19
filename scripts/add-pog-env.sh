#!/usr/bin/env bash
# pot-of-greed POG_* 변수를 ops-vm.enc.env에 추가한다.
# 실행: bash scripts/add-pog-env.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENC_ENV="$SCRIPT_DIR/../compose/_hosts/ops-vm.enc.env"
POG_ENV="$SCRIPT_DIR/../../pot-of-greed/.env"

if [ ! -f "$POG_ENV" ]; then
  echo "ERROR: $POG_ENV not found"
  exit 1
fi

# .env에서 값 추출
PG_DSN=$(grep "^PG_DSN=" "$POG_ENV" | cut -d= -f2-)
# postgresql://user:pass@host:5432/db
POG_PG_USER=$(echo "$PG_DSN" | sed 's|postgresql://||' | cut -d: -f1)
POG_PG_PASSWORD=$(echo "$PG_DSN" | sed 's|postgresql://[^:]*:||' | cut -d@ -f1)
POG_PG_DB=$(echo "$PG_DSN" | sed 's|.*/||' | cut -d? -f1)

NEO4J_PASSWORD=$(grep "^NEO4J_PASSWORD=" "$POG_ENV" | cut -d= -f2-)
OLLAMA_CLOUD_BASE_URL=$(grep "^OLLAMA_CLOUD_BASE_URL=" "$POG_ENV" | cut -d= -f2-)
OLLAMA_API_KEY=$(grep "^OLLAMA_API_KEY=" "$POG_ENV" | cut -d= -f2-)
POG_LLM_PROVIDER=$(grep "^LLM_PROVIDER=" "$POG_ENV" | cut -d= -f2-)
POG_GEMINI_API_KEY=$(grep "^GEMINI_API_KEY=" "$POG_ENV" | cut -d= -f2-)
POG_GEMINI_MODEL=$(grep "^GEMINI_MODEL=" "$POG_ENV" | cut -d= -f2-)
POG_JWT_SECRET=$(grep "^JWT_SECRET=" "$POG_ENV" | cut -d= -f2-)
POG_AUTH_USERS_RAW=$(grep "^AUTH_USERS=" "$POG_ENV" | cut -d= -f2-)
# Docker Compose env file에서 $를 변수로 해석하므로 $$로 이스케이프
POG_AUTH_USERS=$(echo "$POG_AUTH_USERS_RAW" | sed 's/\$/\$\$/g')
POG_CHAINLIT_AUTH_SECRET="2771a27b2fc9a37e2b9e98e14e322e863cd1f1a3634aad0dd8790b982bf99f49"

echo "=== ops-vm.enc.env 복호화 ==="
# repo 내부에 temp 파일 생성 — SOPS가 .sops.yaml을 찾을 수 있어야 재암호화 성공
PLAIN="$(dirname "$ENC_ENV")/ops-vm.tmp.env"
trap 'rm -f "$PLAIN"' EXIT

sops --input-type dotenv --output-type dotenv -d "$ENC_ENV" > "$PLAIN"

echo "=== 기존 POG_* 제거 후 추가 ==="
# 중복 방지: 기존 POG_* 블록 제거
sed -i '/^# pot-of-greed$/,/^POG_CHAINLIT_AUTH_SECRET=/d' "$PLAIN"

cat >> "$PLAIN" <<EOF

# pot-of-greed
# 이미지 태그는 compose/pot-of-greed/compose.yml에 평문으로 박혀 있고 release-pog.sh가
# bump한다 — POG_TAG env는 더 이상 쓰지 않는다(#20).
POG_PG_USER=$POG_PG_USER
POG_PG_PASSWORD=$POG_PG_PASSWORD
POG_PG_DB=$POG_PG_DB
NEO4J_PASSWORD=$NEO4J_PASSWORD
OLLAMA_CLOUD_BASE_URL=$OLLAMA_CLOUD_BASE_URL
OLLAMA_API_KEY=$OLLAMA_API_KEY
POG_LLM_PROVIDER=$POG_LLM_PROVIDER
POG_GEMINI_API_KEY=$POG_GEMINI_API_KEY
POG_GEMINI_MODEL=$POG_GEMINI_MODEL
POG_JWT_SECRET=$POG_JWT_SECRET
POG_AUTH_USERS=$POG_AUTH_USERS
POG_CHAINLIT_AUTH_SECRET=$POG_CHAINLIT_AUTH_SECRET
EOF

echo "=== 재암호화 ==="
sops --input-type dotenv --output-type dotenv -e "$PLAIN" > "$ENC_ENV"

echo "=== 완료: ops-vm.enc.env 업데이트됨 ==="
echo "다음 단계: git add/commit/push → build.sh → deploy-ops-vm.sh"
