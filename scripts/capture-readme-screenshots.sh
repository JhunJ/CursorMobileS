#!/usr/bin/env bash
# Capture dashboard PNGs for README using Chrome headless (no interactive window).
# Only http://127.0.0.1 — never a public/WAN IP in the address bar.
#
# Usage (from repo root):
#   ./scripts/capture-readme-screenshots.sh
#       Uses CURSOR_DASH_PORT or 58741 if a dashboard is already listening.
#   ./scripts/capture-readme-screenshots.sh --auto-start
#       Starts a temporary dashboard on 127.0.0.1:58991 (override with CURSOR_DASH_CAPTURE_PORT), captures, then exits.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/docs/screenshots"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
AUTO_START=0
CAP_PORT="${CURSOR_DASH_CAPTURE_PORT:-58991}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-start) AUTO_START=1; shift ;;
    -h|--help)
      sed -n '1,15p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -x "$CHROME" ]]; then
  echo "Chrome not found at: $CHROME" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

port_listen() {
  local p="$1"
  lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
}

pick_port() {
  if [[ -n "${CURSOR_DASH_PORT:-}" ]] && port_listen "${CURSOR_DASH_PORT}"; then
    printf '%s\n' "${CURSOR_DASH_PORT}"
    return 0
  fi
  if port_listen 58741; then
    printf '%s\n' "58741"
    return 0
  fi
  if [[ "$AUTO_START" == 1 ]]; then
    printf '%s\n' "$CAP_PORT"
    return 0
  fi
  return 1
}

DASH_PID=""
cleanup() {
  if [[ -n "$DASH_PID" ]] && kill -0 "$DASH_PID" 2>/dev/null; then
    kill "$DASH_PID" 2>/dev/null || true
    wait "$DASH_PID" 2>/dev/null || true
  fi
  # setup leaves a Python http.server child; stop anything still LISTENing on our capture port.
  if [[ -n "${PORT:-}" ]]; then
    local pids
    pids=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null) || true
    if [[ -n "$pids" ]]; then
      kill $pids 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT

PORT="$(pick_port)" || {
  echo "No dashboard listening. Start ./setup in another terminal, or run:" >&2
  echo "  ./scripts/capture-readme-screenshots.sh --auto-start" >&2
  exit 1
}

if [[ "$AUTO_START" == 1 ]] && ! port_listen "$PORT"; then
  echo "[capture] Starting temporary dashboard on 127.0.0.1:${PORT} ..."
  (
    cd "$REPO_ROOT"
    export CURSOR_DASH_HOST="127.0.0.1"
    export CURSOR_DASH_PORT="$PORT"
    export CURSOR_DASH_OPEN_BROWSER="0"
    exec ./setup
  ) &
  DASH_PID=$!
  for _ in $(seq 1 80); do
    port_listen "$PORT" && break
    sleep 0.25
  done
  if ! port_listen "$PORT"; then
    echo "[capture] Timed out waiting for port $PORT" >&2
    exit 1
  fi
  sleep 0.75
fi

BASE="http://127.0.0.1:${PORT}"

shot() {
  local out="$1"
  local url="$2"
  local w="${3:-1440}"
  local h="${4:-920}"
  echo "[capture] $out ← $url (${w}x${h})"
  # No --user-data-dir: fresh profiles sometimes deadlock when Chrome is busy; each URL is self-contained via ?lang=.
  if ! "$CHROME" \
    --headless=new \
    --disable-gpu \
    --no-sandbox \
    --hide-scrollbars \
    --window-size="${w},${h}" \
    --virtual-time-budget=8000 \
    --screenshot="$out" \
    "$url" 2>/dev/null; then
    echo "[capture] Chrome failed for $out" >&2
    exit 1
  fi
  if [[ ! -s "$out" ]]; then
    echo "[capture] Empty file: $out" >&2
    exit 1
  fi
}

shot "$OUT_DIR/dashboard-en.png" "${BASE}/?lang=en" 1440 920
shot "$OUT_DIR/dashboard-ko.png" "${BASE}/?lang=ko" 1440 920
shot "$OUT_DIR/dashboard-en-full.png" "${BASE}/?lang=en" 1440 2000

echo "[capture] Done:"
ls -la "$OUT_DIR"/dashboard-en.png "$OUT_DIR"/dashboard-ko.png "$OUT_DIR/dashboard-en-full.png"
