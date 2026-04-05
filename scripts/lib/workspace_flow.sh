#!/usr/bin/env bash
# 대시보드에서 선택한 작업 폴더만: 미완료 단계를 터미널에서 이어감

workspace_setup_main() {
  local wd
  wd="$(expand_tilde "${1:-}")"
  if [[ ! -d "$wd" ]]; then
    log_err "폴더가 없습니다: $wd"
    exit 1
  fi

  export CURSOR_SETUP_WORKSPACE_LOCKED=1
  export CURSOR_SETUP_WORK_DIR="$wd"
  export CURSOR_SETUP_GUI=0
  export CURSOR_SETUP_SKIP_FINISH_GUI=1

  log_info "선택한 폴더만 설정합니다: $wd"

  preflight_main
  github_main
  cursor_agent_main "$CURSOR_SETUP_WORK_DIR"
  summary_main "$CURSOR_SETUP_WORK_DIR" "${CURSOR_SETUP_REPO_NAME:-}"
}
