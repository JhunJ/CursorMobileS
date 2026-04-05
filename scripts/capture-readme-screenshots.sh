#!/usr/bin/env bash
# Capture the dashboard home screen for README (Chrome headless, no window).
# URL uses http://127.0.0.1 only — no public IP in the address bar.
#
# From repo root:
#   ./scripts/capture-readme-screenshots.sh
#       Uses CURSOR_DASH_PORT or 58741 if a dashboard is already listening.
#   ./scripts/capture-readme-screenshots.sh --auto-start
#       Starts a temporary dashboard on 127.0.0.1:58991 (override: CURSOR_DASH_CAPTURE_PORT).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/docs/screenshots"
OUT_EN="$OUT_DIR/dashboard-en.png"
OUT_KO="$OUT_DIR/dashboard-ko.png"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
AUTO_START=0
CAP_PORT="${CURSOR_DASH_CAPTURE_PORT:-58991}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-start) AUTO_START=1; shift ;;
    -h|--help) sed -n '1,12p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -x "$CHROME" ]] || { echo "Chrome not found: $CHROME" >&2; exit 1; }
mkdir -p "$OUT_DIR"

port_listen() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

pick_port() {
  [[ -n "${CURSOR_DASH_PORT:-}" ]] && port_listen "${CURSOR_DASH_PORT}" && { printf '%s\n' "${CURSOR_DASH_PORT}"; return 0; }
  port_listen 58741 && { printf '%s\n' "58741"; return 0; }
  [[ "$AUTO_START" == 1 ]] && { printf '%s\n' "$CAP_PORT"; return 0; }
  return 1
}

DASH_PID=""
cleanup() {
  if [[ -n "$DASH_PID" ]] && kill -0 "$DASH_PID" 2>/dev/null; then
    kill "$DASH_PID" 2>/dev/null || true
    wait "$DASH_PID" 2>/dev/null || true
  fi
  if [[ -n "${PORT:-}" ]]; then
    local pids
    pids=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null) || true
    [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
  fi
}
trap cleanup EXIT

PORT="$(pick_port)" || {
  echo "No dashboard listening. Run ./setup elsewhere, or: $0 --auto-start" >&2
  exit 1
}

if [[ "$AUTO_START" == 1 ]] && ! port_listen "$PORT"; then
  echo "[capture] Starting temporary dashboard on 127.0.0.1:${PORT} ..."
  ( cd "$REPO_ROOT" && exec env CURSOR_DASH_HOST=127.0.0.1 CURSOR_DASH_PORT="$PORT" CURSOR_DASH_OPEN_BROWSER=0 ./setup ) &
  DASH_PID=$!
  for _ in $(seq 1 80); do port_listen "$PORT" && break; sleep 0.25; done
  port_listen "$PORT" || { echo "[capture] Timeout waiting for port $PORT" >&2; exit 1; }
  sleep 0.75
fi

BASE="http://127.0.0.1:${PORT}"

shot() {
  local out="$1"
  local url="$2"
  echo "[capture] $out ← $url"
  "$CHROME" \
    --headless=new \
    --disable-gpu \
    --no-sandbox \
    --hide-scrollbars \
    --window-size=1440,920 \
    --virtual-time-budget=8000 \
    --screenshot="$out" \
    "$url" 2>/dev/null
  [[ -s "$out" ]] || { echo "[capture] Failed: $out" >&2; exit 1; }
}

shot "$OUT_EN" "${BASE}/?lang=en"
shot "$OUT_KO" "${BASE}/?lang=ko"
echo "[capture] Done:"
ls -la "$OUT_EN" "$OUT_KO"
