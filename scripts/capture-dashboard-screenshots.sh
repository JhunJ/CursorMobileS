#!/usr/bin/env bash
# Capture docs/screenshots/*.png via Playwright (see capture_dashboard_screenshots.py).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/scripts/capture_dashboard_screenshots.py" "$@"
