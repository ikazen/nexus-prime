#!/usr/bin/env bash
# 인터랙티브 세션 초기 워크스페이스. git 인증은 이미 credential.helper store 로
# 설정돼 있어(compose.yml wrapper 의 OMNIGENT_INTERACTIVE_GH_TOKEN 물질화 이후 실행)
# 여기선 토큰을 다루지 않는다. 실패는 repo 별 격리 — 한 repo 문제가 세션 기동을 막지
# 않도록 항상 exit 0.
set -uo pipefail

PROJECTS_DIR="/root/projects"
CLAUDE_DIR="${HOME:-/root}/.claude"
CLAUDE_CONFIG_REPO="https://github.com/ikazen/claude-config.git"

mkdir -p "$PROJECTS_DIR"
for r in reflexion-rondo pot-of-greed enemy-controller airflow-stack; do
  dest="$PROJECTS_DIR/$r"
  if [ -d "$dest/.git" ]; then
    echo "[init] $r 존재 — skip"
  else
    echo "[init] clone $r"
    git clone "https://github.com/ikazen/$r.git" "$dest" || echo "[init] WARN: $r clone 실패"
  fi
done

# ~/.claude 를 claude-config 작업트리로 오버레이. vendor 런타임 파일(cache/sessions/
# plugins 등)은 claude-config 의 .gitignore '*' allowlist 로 보존된다 — tracked config
# 만 checkout 대상.
if [ ! -d "$CLAUDE_DIR/.git" ]; then
  git -C "$CLAUDE_DIR" init -q
  git -C "$CLAUDE_DIR" remote add origin "$CLAUDE_CONFIG_REPO" 2>/dev/null \
    || git -C "$CLAUDE_DIR" remote set-url origin "$CLAUDE_CONFIG_REPO"
fi
if git -C "$CLAUDE_DIR" fetch -q --depth 1 origin main; then
  git -C "$CLAUDE_DIR" checkout -q -f -B main FETCH_HEAD
  chmod +x "$CLAUDE_DIR"/hooks/*.sh "$CLAUDE_DIR"/hooks/lib/*.sh 2>/dev/null || true
  # omnigent 세션(--setting-sources all)이 병합할 user settings — 훅만 담긴 omni 변형으로
  # 덮어쓴다. 전체 settings.json(model/plugin 등 랩탑 전용 설정)은 쓰지 않는다.
  if [ -f "$CLAUDE_DIR/settings.omni.json" ]; then
    cp -f "$CLAUDE_DIR/settings.omni.json" "$CLAUDE_DIR/settings.json"
  fi
else
  echo "[init] WARN: claude-config fetch 실패 — OMNIGENT_INTERACTIVE_GH_TOKEN scope 에 claude-config 포함 여부 확인"
fi

exit 0
