#!/usr/bin/env bash
# 마무리: 짧은 안내 + 상태 요약

CURSOR_DASHBOARD_URL="${CURSOR_DASHBOARD_URL:-https://cursor.com/dashboard}"
CURSOR_DOCS_AGENTS_URL="${CURSOR_DOCS_AGENTS_URL:-https://cursor.com/docs}"

summary_main() {
  local work_dir="${1:-}"
  local repo_name="${2:-}"

  log_info "[5/5] 마무리"

  if declare -F status_dashboard_print >/dev/null 2>&1; then
    status_dashboard_print "$work_dir" "$repo_name"
  fi

  cat <<EOF

▶ 웹에서 한 번만 (Cursor 사이트)
  • Self-hosted agents 켜기 · 저장소 지정 · main · agent/

▶ 습관
  끝날 때 push · 다시 할 때 pull

▶ agent 합치기
  git checkout main && git pull && git merge agent/이름 && git push

EOF

  if prompt_yn "Cursor 대시보드 웹을 열까요?" "y"; then
    run_cmd open "$CURSOR_DASHBOARD_URL"
  fi

  if prompt_yn "문서를 열까요?" "n"; then
    run_cmd open "$CURSOR_DOCS_AGENTS_URL"
  fi

  log_info "끝. 브라우저 대시보드: ./setup (또는 ./setup --dashboard)"

  if [[ "${CURSOR_SETUP_SKIP_FINISH_GUI:-0}" != "1" ]] && declare -F gui_finish_celebrate >/dev/null 2>&1; then
    gui_finish_celebrate
  fi
}
