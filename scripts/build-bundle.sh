#!/usr/bin/env bash
# 저장소의 lib/*.sh 를 하나의 .command 파일로 묶습니다 (맥 더블클릭 실행 가능).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/dist/MacMini-Cursor-Setup.command"
mkdir -p "$REPO_ROOT/dist"

{
  cat <<'HEADER'
#!/usr/bin/env bash
set -euo pipefail
# 맥미니 통합 셋업 — 단일 파일 배포본 (저장소에서 scripts/build-bundle.sh 실행으로 생성)
#
# 배포 방법 예시:
#   - GitHub Releases 에 이 .command 파일만 첨부하거나
#   - gist / raw URL 로 올린 뒤:  curl -fsSL "<raw URL>" -o setup.command && chmod +x setup.command && ./setup.command
#
# 보안: 인터넷에서 받은 파일은 Finder 에서 우클릭 → "열기" 로 첫 실행(게이트키퍼).
# 기본은 브라우저 대시보드(로컬)입니다. 터미널만 전체 마법사:  ./MacMini-Cursor-Setup.command --full-wizard 또는 --cli
#
ROOT="$(cd "$(dirname "$0")" && pwd)"
export CURSOR_SETUP_ROOT="$ROOT"

HEADER

  for name in common status_report workspace_services dashboard_html dashboard_flow gui preflight github cursor_agent summary workspace_flow; do
    printf '# --- scripts/lib/%s.sh ---\n' "$name.sh"
    tail -n +2 "$REPO_ROOT/scripts/lib/${name}.sh"
    printf '\n'
  done

  printf 'cursor_agent_worker_plist_template() {\n'
  printf '  cat <<'\''PLIST_TMPL_EOF'\''\n'
  cat "$REPO_ROOT/templates/com.cursor.agent.worker.plist"
  printf 'PLIST_TMPL_EOF\n'
  printf '}\n\n'

  printf 'cursor_agent_worker_entry_template() {\n'
  printf '  cat <<'\''ENTRY_TMPL_EOF'\''\n'
  cat "$REPO_ROOT/templates/agent-worker-entry.sh"
  printf 'ENTRY_TMPL_EOF\n'
  printf '}\n\n'

  cat <<'EARLY_DASH'
# --- 내부: 로컬 대시보드 (단일 파일 번들용) ---
if [[ "${1:-}" == "--_cursor-setup-write-allowlist" ]]; then
  shift
  _al_out="${1:-}"
  [[ -n "$_al_out" ]] || exit 1
  discover_workspace_paths > "$_al_out" || exit 1
  exit 0
fi
if [[ "${1:-}" == "--_cursor-setup-write-dash" ]]; then
  shift
  _dash_out="${1:-}"
  [[ -n "$_dash_out" ]] || exit 1
  if [[ -f "$ROOT/setup" ]]; then
    export CURSOR_SETUP_EXEC_HINT="$ROOT/setup"
  elif [[ -f "$ROOT/MacMini-Cursor-Setup.command" ]]; then
    export CURSOR_SETUP_EXEC_HINT="$ROOT/MacMini-Cursor-Setup.command"
  else
    export CURSOR_SETUP_EXEC_HINT="$ROOT/MacMini-Cursor-Setup.command"
  fi
  CURSOR_SETUP_HTML_QUIET=1 status_dashboard_write_html_interactive "$_dash_out" || exit 1
  if [[ -n "${CURSOR_DASH_ALLOWLIST:-}" ]]; then
    discover_workspace_paths > "$CURSOR_DASH_ALLOWLIST"
  fi
  exit 0
fi
if [[ "${1:-}" == "--rename-repo" ]]; then
  shift
  _rr_path="${1:-}"
  _rr_name="${2:-}"
  [[ -n "$_rr_path" && -n "$_rr_name" ]] || exit 1
  _rr_path="$(expand_tilde "$_rr_path")"
  _rr_path="$(cd "$_rr_path" 2>/dev/null && pwd -P)" || {
    log_err "폴더 없음: $_rr_path"
    exit 1
  }
  cd "$_rr_path" || exit 1
  github_validate_repo_name "$_rr_name" || {
    log_err "저장소 이름: 영숫자 . _ - 만, 1~100자"
    exit 1
  }
  _rr_origin="$(git remote get-url origin 2>/dev/null || true)"
  _rr_cur="$(github_repo_name_from_remote_url "$_rr_origin" 2>/dev/null)" || true
  [[ -n "$_rr_cur" ]] || {
    log_err "github.com origin 이 아닙니다."
    exit 1
  }
  if [[ "$_rr_cur" == "$_rr_name" ]]; then
    log_info "이미 저장소 이름이 '$_rr_name' 입니다."
    exit 0
  fi
  log_info "GitHub 저장소 이름: $_rr_cur → $_rr_name"
  gh repo rename "$_rr_name" --yes || exit 1
  log_info "완료. 대시보드를 새로고침 하세요."
  exit 0
fi

EARLY_DASH

  awk '
    /^usage\(\)/ { out=1 }
    out {
      if (/^# shellcheck source=/) next
      if (/^[[:space:]]*# shellcheck disable=SC1091[[:space:]]*$/) next
      if (/^[[:space:]]*source "\$ROOT\/scripts\/lib\//) next
      print
    }
  ' "$REPO_ROOT/setup"
} > "$OUT"

chmod +x "$OUT"
printf '생성됨: %s (%s 바이트)\n' "$OUT" "$(wc -c < "$OUT" | tr -d ' ')"
