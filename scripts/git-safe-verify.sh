#!/usr/bin/env bash
# 레포에 비밀·민감 경로 등이 추적되지 않았는지 검사합니다.
# 푸시 전: ./scripts/git-safe-verify.sh  ·  CI 에서도 실행됩니다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bad=0

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    *.pem | *.p12 | *.key)
      printf '%s\n' "git-safe-verify: ERROR — private key/credential file 이 추적 중입니다: $f" >&2
      bad=1
      ;;
  esac
done < <(git ls-files)

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if [[ "$f" == .cloudflared/* || "$f" == *"/.cloudflared/"* ]]; then
    printf '%s\n' "git-safe-verify: ERROR — .cloudflared 는 홈 디렉터리(~/.cloudflared)에만 두세요: $f" >&2
    bad=1
  fi
done < <(git ls-files)

# PEM 본문
if git grep -n 'BEGIN [A-Z0-9 ]*PRIVATE KEY' -- . ':!dist/MacMini-Cursor-Setup.command' >/dev/null 2>&1; then
  printf '%s\n' "git-safe-verify: ERROR — 추적된 파일에 PEM 비밀키 본문이 있습니다." >&2
  bad=1
fi

if [[ "$bad" -ne 0 ]]; then
  printf '%s\n' "git-safe-verify: 실패 — 위 항목을 제거한 뒤 다시 커밋하세요." >&2
  exit 1
fi

printf '%s\n' "git-safe-verify: OK (추적 파일 기준)"
