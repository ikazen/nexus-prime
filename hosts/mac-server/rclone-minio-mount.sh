#!/bin/bash
set -euo pipefail

MOUNT_POINT="$HOME/minio/models"
MINIO_URL="http://localhost:9000"
BUCKET="models"

mkdir -p "$MOUNT_POINT"

until curl -sf "$MINIO_URL/minio/health/live" >/dev/null 2>&1; do
    echo "waiting for MinIO..."
    sleep 5
done

exec rclone mount "minio:$BUCKET" "$MOUNT_POINT" \
    --vfs-cache-mode full \
    --vfs-cache-max-size 200G \
    --dir-cache-time 72h \
    --log-level INFO
