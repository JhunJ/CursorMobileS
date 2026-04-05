#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "[smoke] setup --help"
bash ./setup --help >/dev/null

echo "[smoke] setup --status"
bash ./setup --status >/dev/null

echo "[smoke] bundle rebuild check"
./scripts/build-bundle.sh >/dev/null
git diff --exit-code -- dist/MacMini-Cursor-Setup.command >/dev/null

echo "[smoke] readme assets check"
./scripts/verify-readme-assets.sh >/dev/null

echo "[smoke] git safe verify"
./scripts/git-safe-verify.sh >/dev/null

echo "[smoke] OK"
