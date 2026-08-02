#!/bin/sh
# daily_claude_ping DAG (airflow-stack) forced command 본체.
#
# 재시도 루프는 mac sleep/wake 직후 claude 가 일시 실패하는 경우의 셀프 복구용.
# claude 인증 만료("Not logged in")는 재시도로 복구되지 않으므로 즉시 중단하고
# 실패로 반환 — airflow-stack 쪽 DAG 가 이 메시지를 감지해 fast-fail 처리한다.
#
# <CLAUDE> 를 실제 claude 실행 경로로 치환 후 배포 (README 참조).

CLAUDE="<CLAUDE>"
i=0
while [ "$i" -lt 10 ]; do
  out=$("$CLAUDE" -p "ping" < /dev/null 2>&1) && { printf '%s\n' "$out"; exit 0; }
  case "$out" in
    *"Not logged in"*|*"Please run /login"*) break ;;
  esac
  i=$((i + 1))
  sleep 30
done
printf 'ping failed: %s\n' "$out" >&2
exit 1
