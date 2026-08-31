#!/usr/bin/env bash
# WSL에서 실행: bash scripts/recover-mac-server.sh [--pre-reboot]
#
# mac-server(M1 edge worker + MinIO) 재부팅/OS 업데이트 전후 처리를 한 곳에 모은 스크립트.
# SSH 로 mac-server 와 ops-vm 양쪽을 몰아 실행한다. 멱등 — 몇 번 돌려도 안전.
#
#   (인자 없음)     재부팅·sleep/wake 후 복구. pmset 재적용 → Colima → 인프라 컨테이너 →
#                   LaunchAgent → sleepwatcher → edge worker 재등록 → 검증.
#   --pre-reboot    계획된 재부팅 전 안전 정지. edge worker 를 drain 시켜 OFFLINE 로 내린다
#                   (그냥 재부팅하면 Airflow 메타DB 에 starting/running 이 잔류해 crash loop).
#
# 배경: OS 업데이트는 pmset 슬립 방지 설정을 되돌린다. 그러면 맥이 자면서 edge worker heartbeat 가
# 150s 를 못 채워 중앙이 워커를 UNKNOWN 으로 떨군다. 원격에서는 못 고친다 — 자는 동안 SSH·tailnet
# 도달 불가. 사람이 물리적으로 깨운 뒤 이 스크립트를 돌린다. 자세한 내용은 docs/runbook.md.
#
# 전제:
#   - ~/.ssh/config 에 mac-server, ops-vm 항목
#   - mac-server 에 ~/projects/airflow-stack, ~/projects/nexus-prime checkout
#   - ops-vm 에 airflow 컨트롤 플레인 컨테이너(postgres / airflow-dag-processor-1) 기동
set -euo pipefail

MAC_HOST="${MAC_HOST:-mac-server}"
OPS_HOST="${OPS_HOST:-ops-vm}"
MAC_AIRFLOW_DIR="${MAC_AIRFLOW_DIR:-\$HOME/projects/airflow-stack}"
MAC_NEXUS_DIR="${MAC_NEXUS_DIR:-\$HOME/projects/nexus-prime}"

MAC_ENV_FILE="$MAC_AIRFLOW_DIR/infra/mac-server/.env"
WORKERS=(mac-server mac-server-big)
SERVICES=(edge-worker-default edge-worker-big)

MODE=recover
case "${1:-}" in
    "")            MODE=recover ;;
    --pre-reboot)  MODE=pre-reboot ;;
    -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
    *)             echo "unknown arg: $1  (use --pre-reboot or no arg)"; exit 2 ;;
esac

log()  { printf '[recover-mac] %s\n' "$*"; }
warn() { printf '[recover-mac] WARN: %s\n' "$*" >&2; }
die()  { printf '[recover-mac] ERROR: %s\n' "$*" >&2; exit 1; }

ops_ssh() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$OPS_HOST" bash -s; }

# 비대화형 SSH 는 ~/.zshrc 를 안 읽어 Homebrew PATH·DOCKER_HOST(Colima socket)가 없다.
# 매 호출 앞에 심어준다 (~/.wakeup 이 쓰는 것과 동일한 값).
mac_ssh() {
    {
        printf '%s\n' 'export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH'
        printf '%s\n' 'export DOCKER_HOST="unix://$HOME/.colima/default/docker.sock"'
        cat
    } | ssh -o BatchMode=yes -o ConnectTimeout=15 "$MAC_HOST" bash -s
}

worker_states() {
    ops_ssh <<EOF 2>/dev/null | tr -d ' '
docker exec postgres psql -U airflow -d airflow -tAc "SELECT worker_name||'='||state FROM edge_worker WHERE worker_name IN ('mac-server','mac-server-big') ORDER BY worker_name"
EOF
}

# ---- preflight: mac 도달성 -------------------------------------------------------
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$MAC_HOST" true 2>/dev/null; then
    warn "SSH 로 $MAC_HOST 에 도달할 수 없음 — 맥이 자거나 꺼져 있음."
    echo
    echo "  최근 6시간 node_exporter up 이력 (ops-vm Prometheus):"
    ops_ssh <<'EOF' 2>/dev/null || true
end=$(date -u +%s); start=$((end-21600))
docker exec prometheus wget -qO- "http://localhost:9090/api/v1/query_range?query=up%7Bjob%3D%22node_mac_server%22%7D&start=${start}&end=${end}&step=300" \
  | python3 -c "
import json,sys,datetime
d=json.load(sys.stdin)['data']['result']
if not d: print('    (데이터 없음)'); sys.exit()
prev=None
for t,v in d[0]['values']:
    if v!=prev:
        ts=datetime.datetime.fromtimestamp(float(t), datetime.timezone.utc).strftime('%m-%d %H:%M UTC')
        print(f'    {ts} -> up={v}')
        prev=v
"
echo
echo "  tailscale:"
tailscale status 2>/dev/null | grep -i mac-server | sed 's/^/    /' || echo "    (안 보임)"
EOF
    echo
    echo "  진단: up 이 ~50분마다 잠깐 1 이 됐다 사라지면 = 맥이 dark wake 중 (pmset 슬립 방지 리셋)."
    echo "  조치: 맥을 물리적으로 깨운 뒤(키보드/마우스) 이 스크립트를 다시 실행하세요."
    exit 1
fi

# ---- --pre-reboot: 재부팅 전 안전 정지 -----------------------------------------
if [[ "$MODE" == pre-reboot ]]; then
    log "edge worker drain 후 정지 (재부팅 전) ..."
    mac_ssh <<EOF
set -e
cd "$MAC_AIRFLOW_DIR"
docker compose -f infra/mac-server/docker-compose.yml stop ${SERVICES[*]}
EOF
    log "메타DB 에서 OFFLINE 등록 대기 (최대 60s) ..."
    for _ in $(seq 1 20); do
        st=$(worker_states || true)
        if ! grep -qvE '=(offline|unknown)$' <<<"$st" && [[ -n "$st" ]]; then
            echo "$st" | sed 's/^/  /'
            log "두 워커 모두 내려감. 이제 재부팅 안전."
            log "재부팅 후: bash scripts/recover-mac-server.sh"
            exit 0
        fi
        sleep 3
    done
    warn "60s 안에 OFFLINE 확인 실패 — 현재 상태:"
    worker_states | sed 's/^/  /' >&2
    warn "그대로 재부팅해도 복구 모드가 정리하지만, 잠시 후 다시 --pre-reboot 를 시도해도 된다."
    exit 1
fi

# ============================================================================
#  복구 모드
# ============================================================================

# ---- 1. 전원 설정 (이번 장애의 근본 원인) -------------------------------------
log "1/8 pmset 슬립 방지 설정 확인 ..."
mac_ssh <<'EOF' || warn "pmset 단계에서 문제 — 위 출력 확인"
set -e
need_fix=0
vals=$(pmset -g custom 2>/dev/null || pmset -g)
for k in "sleep" "standby " "hibernatemode" "disksleep"; do
    v=$(echo "$vals" | grep -E "^[[:space:]]*${k}" | head -1 | awk '{print $2}')
    if [[ -n "$v" && "$v" != "0" ]]; then
        echo "  drift: $k = $v (기대값 0)"
        need_fix=1
    fi
done
if [[ "$need_fix" == 1 ]]; then
    if sudo -n pmset -a sleep 0 standby 0 hibernatemode 0 disksleep 0 2>/dev/null; then
        echo "  재적용 완료 (sudo -n)"
    else
        echo "  !! sudo 비밀번호 필요 — 맥에서 직접 실행하세요:"
        echo "       sudo pmset -a sleep 0 standby 0 hibernatemode 0 disksleep 0"
    fi
else
    echo "  ok: 전부 0"
fi

plist=/Library/LaunchDaemons/local.pmset-nosleep.plist
if [[ ! -f "$plist" ]]; then
    src="$HOME/projects/nexus-prime/hosts/mac-server/launchd/local.pmset-nosleep.plist"
    echo "  LaunchDaemon 미설치."
    if [[ -f "$src" ]] && sudo -n cp "$src" "$plist" 2>/dev/null && sudo -n launchctl load "$plist" 2>/dev/null; then
        echo "  LaunchDaemon 설치+load 완료"
    else
        echo "  !! 맥에서 직접 실행하세요:"
        echo "       sudo cp $src $plist"
        echo "       sudo launchctl load $plist"
    fi
else
    echo "  ok: LaunchDaemon 설치됨"
fi
EOF

# ---- 2. Colima -----------------------------------------------------------------
log "2/8 Colima 기동 확인 ..."
mac_ssh <<'EOF' || die "Colima 를 기동하지 못함 — 맥에서 'colima start' 수동 확인"
set -e
if colima status 2>&1 | grep -q "colima is running"; then
    echo "  ok: 이미 running"
else
    echo "  미기동 — LaunchAgent kickstart"
    launchctl kickstart -k "gui/$(id -u)/local.airflow.colima" 2>/dev/null \
        || colima start -f &
    for i in $(seq 1 60); do
        docker info >/dev/null 2>&1 && { echo "  docker 응답 ($((i*2))s)"; break; }
        sleep 2
    done
    docker info >/dev/null 2>&1 || { echo "  !! 120s 내 docker 무응답"; exit 1; }
fi
EOF

# ---- 3. DOCKER_GID 정합성 (DooD task 용, 자동 수정 안 함) ---------------------
log "3/8 DOCKER_GID 정합성 확인 ..."
mac_ssh <<EOF || warn "DOCKER_GID 확인 건너뜀"
set -e
vm_gid=\$(colima ssh -- getent group docker 2>/dev/null | cut -d: -f3)
env_gid=\$(grep -E '^DOCKER_GID=' "$MAC_ENV_FILE" 2>/dev/null | cut -d= -f2)
if [[ -z "\$vm_gid" ]]; then
    echo "  Colima VM docker gid 조회 실패 — skip"
elif [[ "\$vm_gid" != "\$env_gid" ]]; then
    echo "  !! 불일치: VM=\$vm_gid, .env=\$env_gid"
    echo "     $MAC_ENV_FILE 의 DOCKER_GID 를 \$vm_gid 로 고친 뒤 edge worker recreate 필요"
    echo "     (DooD @task.docker task 만 조용히 깨짐 — 지금 워커 자체는 뜬다)"
else
    echo "  ok: \$vm_gid"
fi
EOF

# ---- 4. 인프라 컨테이너 (MinIO + promtail) -----------------------------------
log "4/8 인프라 컨테이너 (MinIO + promtail) ..."
mac_ssh <<EOF || warn "인프라 컨테이너 up 실패 — 위 출력 확인"
set -e
cd "$MAC_NEXUS_DIR"
docker network inspect nexus >/dev/null 2>&1 || docker network create nexus
docker compose -f compose/_hosts/mac-server.yml --env-file compose/_hosts/mac-server.env up -d
EOF

# ---- 5. LaunchAgent 3종 ------------------------------------------------------
log "5/8 LaunchAgent (colima / node_exporter / rclone-minio) ..."
mac_ssh <<'EOF' || warn "LaunchAgent 확인 중 문제"
uid=$(id -u)
for label in local.airflow.colima local.node_exporter local.rclone-minio; do
    if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
        echo "  ok: $label"
    else
        plist="$HOME/Library/LaunchAgents/$label.plist"
        if [[ -f "$plist" ]] && launchctl load "$plist" 2>/dev/null; then
            echo "  loaded: $label"
        else
            echo "  !! $label 미로드 ($plist 없음/실패) — README 셋업 절차 확인"
        fi
    fi
done
EOF

# ---- 6. sleepwatcher (다음 sleep/wake 자동 복구) ----------------------------
log "6/8 sleepwatcher + ~/.wakeup ..."
mac_ssh <<'EOF' || warn "sleepwatcher 확인 중 문제"
if [[ ! -x "$HOME/.wakeup" ]]; then
    echo "  !! ~/.wakeup 없음/비실행 — airflow-stack docs/setup.md 'sleep/wake 자동 복구' 참조"
fi
if brew services list 2>/dev/null | grep -E '^sleepwatcher' | grep -q started; then
    echo "  ok: sleepwatcher started"
else
    echo "  sleepwatcher 미기동 — 시작"
    brew services start sleepwatcher 2>/dev/null || echo "  !! 시작 실패 — brew install sleepwatcher 확인"
fi
EOF

# ---- 7. edge worker 재등록 --------------------------------------------------
log "7/8 edge worker 상태 확인 ..."
states=$(worker_states || true)
echo "$states" | sed 's/^/  /'
if [[ -n "$states" ]] && ! grep -qvE '=(idle|running)$' <<<"$states"; then
    log "  두 워커 모두 idle/running — 재등록 불필요"
else
    log "  재등록 진행 (stop → remove-remote-edge-worker → force-recreate)"
    # docker restart 연타 금지: restart:unless-stopped 와 경합해 150s liveness 를
    # 영영 못 채우는 self-inflicted crash loop 가 된다 (airflow3-learnings.md sleep/wake).
    mac_ssh <<EOF
set -e
cd "$MAC_AIRFLOW_DIR"
docker compose -f infra/mac-server/docker-compose.yml stop ${SERVICES[*]}
EOF
    for w in "${WORKERS[@]}"; do
        # 이 두 이름만 건드린다 — ops-vm/worker-vm 등록을 지우면 그 워커도 409 로 깨진다.
        ops_ssh <<EOF || warn "remove-remote-edge-worker $w 실패 (이미 없을 수 있음)"
docker exec airflow-dag-processor-1 airflow edge remove-remote-edge-worker -H $w
EOF
    done
    mac_ssh <<EOF || die "edge worker force-recreate 실패"
set -e
cd "$MAC_AIRFLOW_DIR"
docker compose -f infra/mac-server/docker-compose.yml up -d --force-recreate ${SERVICES[*]}
EOF
fi

# ---- 8. 검증 폴링 ---------------------------------------------------------------
log "8/8 검증 (최대 120s) ..."
ok_workers=0
for _ in $(seq 1 40); do
    states=$(worker_states || true)
    if [[ -n "$states" ]] && ! grep -qvE '=(idle|running)$' <<<"$states"; then
        ok_workers=1
        break
    fi
    sleep 3
done

mac_probe=$(mac_ssh <<'EOF' 2>/dev/null || true
printf 'minio_mount='
ls "$HOME/minio/models" >/dev/null 2>&1 && echo ok || echo FAIL
printf 'containers='
docker ps --format '{{.Names}}' | grep -E '^(minio|promtail)$' | paste -sd, -
EOF
)
node_up=$(ops_ssh <<'EOF' 2>/dev/null || true
docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22node_mac_server%22%7D' \
  | python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 'nodata')"
EOF
)

echo
echo "  =================== 복구 요약 ==================="
echo "  edge worker:  $(worker_states | paste -sd' ' -)"
echo "  node up:      $node_up"
echo "$mac_probe" | sed 's/^/  /'
echo "  ================================================"

fail=0
[[ "$ok_workers" == 1 ]] || { warn "edge worker 가 idle/running 아님"; fail=1; }
[[ "$node_up" == "1" ]]  || { warn "Prometheus node_mac_server up != 1 ($node_up)"; fail=1; }
grep -q 'minio_mount=ok' <<<"$mac_probe" || { warn "rclone MinIO 마운트 확인 실패"; fail=1; }

if [[ "$fail" == 0 ]]; then
    log "복구 완료 — 전부 정상."
else
    die "일부 항목 실패 (위 WARN 참조). 잠시 후 재실행하거나 runbook 수동 절차 확인."
fi
