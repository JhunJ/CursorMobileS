#!/bin/bash
# LaunchAgent 가 인자로 작업 폴더·agent 경로를 넘깁니다. 기동 전 원격과 맞춤(fetch + ff-only pull).
set -euo pipefail
WORK_DIR="${1:?}"
AGENT_BIN="${2:?}"
cd "$WORK_DIR" || exit 1
export PATH="$HOME/.local/bin:$PATH"
if [[ -d .git ]]; then
  git fetch origin 2>/dev/null || true
  cur=$(git branch --show-current 2>/dev/null || true)
  if [[ -n "$cur" ]]; then
    if git rev-parse '@{u}' >/dev/null 2>&1; then
      git pull --ff-only 2>/dev/null || true
    elif git rev-parse "refs/remotes/origin/$cur" >/dev/null 2>&1; then
      git pull --ff-only origin "$cur" 2>/dev/null || true
    fi
  fi
fi
exec "$AGENT_BIN" worker start
