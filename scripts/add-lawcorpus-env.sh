#!/usr/bin/env bash
# lawcorpus PG 자격증명을 ops-vm.enc.env에 추가한다. pot-of-greed API가 세법/판례
# 코퍼스를 lawcorpus DB(potofgreed DB와 별개)에서 읽도록 전환하며 신설(#50).
# 기존 POG_PG_*(Chainlit UI CHAINLIT_DB_DSN 전용, potofgreed DB)는 건드리지 않는다.
# 실행: bash scripts/add-lawcorpus-env.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENC_ENV="$SCRIPT_DIR/../compose/_hosts/ops-vm.enc.env"
LAWCORPUS_ENV="$SCRIPT_DIR/../../law-corpus/.env"

if [ ! -f "$LAWCORPUS_ENV" ]; then
  echo "ERROR: $LAWCORPUS_ENV not found"
  exit 1
fi

PG_DSN=$(grep "^LAWCORPUS_PG_DSN=" "$LAWCORPUS_ENV" | cut -d= -f2-)
LAWCORPUS_PG_USER=$(echo "$PG_DSN" | sed 's|postgresql://||' | cut -d: -f1)
LAWCORPUS_PG_PASSWORD=$(echo "$PG_DSN" | sed 's|postgresql://[^:]*:||' | cut -d@ -f1)
LAWCORPUS_PG_DB=$(echo "$PG_DSN" | sed 's|.*/||' | cut -d? -f1)

echo "=== ops-vm.enc.env 복호화 ==="
PLAIN="$(dirname "$ENC_ENV")/ops-vm.tmp.env"
trap 'rm -f "$PLAIN"' EXIT

sops --input-type dotenv --output-type dotenv -d "$ENC_ENV" > "$PLAIN"

echo "=== 기존 lawcorpus 블록 제거 후 추가 (재실행 안전) ==="
sed -i '/^# lawcorpus$/,/^LAWCORPUS_PG_DB=/d' "$PLAIN"

cat >> "$PLAIN" <<EOF

# lawcorpus
LAWCORPUS_PG_USER=$LAWCORPUS_PG_USER
LAWCORPUS_PG_PASSWORD=$LAWCORPUS_PG_PASSWORD
LAWCORPUS_PG_DB=$LAWCORPUS_PG_DB
EOF

echo "=== 재암호화 ==="
sops --input-type dotenv --output-type dotenv -e "$PLAIN" > "$ENC_ENV"

echo "=== 완료: ops-vm.enc.env 업데이트됨 ==="
