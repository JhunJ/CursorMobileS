#!/usr/bin/env bash
# Cursor CLI 설치, PATH, agent login, LaunchAgent

cursor_agent_install_worker_entry_script() {
  local dest="$HOME/.cursor-setup/agent-worker-entry.sh"
  local src=""
  if [[ -n "${CURSOR_SETUP_ROOT:-}" && -f "$CURSOR_SETUP_ROOT/templates/agent-worker-entry.sh" ]]; then
    src="$CURSOR_SETUP_ROOT/templates/agent-worker-entry.sh"
  fi
  ensure_dir "$HOME/.cursor-setup"
  if [[ -n "$src" ]]; then
    cp "$src" "$dest"
  elif declare -F cursor_agent_worker_entry_template >/dev/null 2>&1; then
    cursor_agent_worker_entry_template > "$dest"
  else
    log_err "templates/agent-worker-entry.sh 없음"
    return 1
  fi
  chmod +x "$dest"
  return 0
}

cursor_agent_main() {
  local work_dir="${1:-}"
  if [[ -z "$work_dir" ]]; then
    log_err "작업 폴더 없음"
    exit 1
  fi

  log_info "[3/5] Cursor Agent"

  local path_line='export PATH="$HOME/.local/bin:$PATH"'
  append_line_once "$HOME/.zshrc" "$path_line"

  if [[ -f "$HOME/.zshrc" ]] && ! is_dry_run; then
    # shellcheck disable=SC1090
    source "$HOME/.zshrc" 2>/dev/null || true
  fi

  local agent_bin="$HOME/.local/bin/agent"
  if ! [[ -x "$agent_bin" ]]; then
    if [[ "${CURSOR_SETUP_WORKSPACE_LOCKED:-0}" == "1" ]] || prompt_yn "Cursor agent 설치할까요?" "y"; then
      if is_dry_run; then
        log_info "[dry-run] curl cursor.com/install | bash"
      else
        curl -fsSL "https://cursor.com/install" | bash
      fi
    else
      log_warn "agent 없음 — 나중에: curl -fsSL https://cursor.com/install | bash"
    fi
  else
    log_info "agent: 이미 설치됨"
  fi

  if ! [[ -x "$agent_bin" ]] && ! is_dry_run; then
    log_warn "agent 없어 Cursor 단계 생략"
    log_info "수동: $agent_bin login && cd $(printf '%q' "$work_dir") && $agent_bin worker start"
    return 0
  fi

  if is_dry_run; then
    log_info "[dry-run] agent login / LaunchAgent"
    return 0
  fi

  if cursor_agent_state_file_present; then
    log_info "agent: 로그인 이력 있음 → login 단계 생략 (다시 하려면 agent login)"
  else
    if [[ "${CURSOR_SETUP_WORKSPACE_LOCKED:-0}" == "1" ]] || prompt_yn "agent 로그인(브라우저) 할까요?" "y"; then
      "$agent_bin" login || log_warn "login 실패 — 수동: $agent_bin login"
    fi
  fi

  local plist_src=""
  local plist_tmp=""
  if [[ -n "${CURSOR_SETUP_ROOT:-}" ]] && [[ -f "$CURSOR_SETUP_ROOT/templates/com.cursor.agent.worker.plist" ]]; then
    plist_src="$CURSOR_SETUP_ROOT/templates/com.cursor.agent.worker.plist"
  elif declare -F cursor_agent_worker_plist_template >/dev/null 2>&1; then
    plist_tmp="$(mktemp -t cursor-worker-plist)"
    cursor_agent_worker_plist_template > "$plist_tmp"
    plist_src="$plist_tmp"
  fi

  local plist_dst="$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist"
  local log_dir="$HOME/Library/Logs/CursorAgentWorker"
  local wrap_script="$HOME/.cursor-setup/agent-worker-entry.sh"
  ensure_dir "$log_dir"

  cursor_agent_install_worker_entry_script || exit 1

  if [[ -z "$plist_src" ]] || [[ ! -f "$plist_src" ]]; then
    log_err "worker plist 템플릿 없음"
    [[ -n "$plist_tmp" ]] && rm -f "$plist_tmp"
    exit 1
  fi

  local old_wd=""
  [[ -f "$plist_dst" ]] && old_wd=$(plutil_string "$plist_dst" WorkingDirectory)

  sed -e "s|__WRAP_SCRIPT__|$wrap_script|g" \
      -e "s|__AGENT_BIN__|$agent_bin|g" \
      -e "s|__WORK_DIR__|$work_dir|g" \
      -e "s|__LOG_OUT__|$log_dir/agent-worker.log|g" \
      -e "s|__LOG_ERR__|$log_dir/agent-worker.err.log|g" \
      "$plist_src" > "$plist_dst"
  [[ -n "$plist_tmp" ]] && rm -f "$plist_tmp"
  log_info "LaunchAgent plist 저장됨"

  cursor_agent_launchctl_bootstrap_worker() {
    local uid plist err
    uid="$(id -u)"
    plist="$plist_dst"
    launchctl bootout "gui/$uid/com.cursor.agent.worker" 2>/dev/null || true
    sleep 0.35
    err=$(mktemp)
    if launchctl bootstrap "gui/$uid" "$plist" 2>"$err"; then
      rm -f "$err"
      return 0
    fi
    log_warn "launchctl bootstrap 1차 실패 — 재시도 (macOS EIO 등): $(head -c 200 "$err" 2>/dev/null | tr '\n' ' ')"
    rm -f "$err"
    sleep 0.55
    launchctl bootout "gui/$uid/com.cursor.agent.worker" 2>/dev/null || true
    sleep 0.35
    if ! launchctl bootstrap "gui/$uid" "$plist"; then
      log_err "launchctl bootstrap 실패 — 터미널에서: launchctl bootout gui/$uid/com.cursor.agent.worker 후 다시 setup"
      return 1
    fi
    return 0
  }

  if [[ "$old_wd" == "$work_dir" ]] && [[ -n "$old_wd" ]]; then
    log_info "워커: 같은 폴더 — plist·진입 스크립트 반영을 위해 재기동"
    cursor_agent_launchctl_bootstrap_worker || return 1
    launchctl kickstart -k "gui/$(id -u)/com.cursor.agent.worker" 2>/dev/null || true
    return 0
  fi

  if [[ "${CURSOR_SETUP_WORKSPACE_LOCKED:-0}" == "1" ]] || prompt_yn "워커 자동 실행(재부팅 후에도) 등록할까요?" "y"; then
    cursor_agent_launchctl_bootstrap_worker || return 1
    launchctl kickstart -k "gui/$(id -u)/com.cursor.agent.worker" 2>/dev/null || true
  else
    printf '%s\n' "  cd $(printf '%q' "$work_dir") && $agent_bin worker start"
  fi
}
