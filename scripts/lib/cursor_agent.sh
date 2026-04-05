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

cursor_agent_launchctl_bootstrap_worker_plist() {
  local uid="$1" plist="$2" label="$3" err
  launchctl bootout "gui/$uid/$label" 2>/dev/null || true
  sleep 0.35
  err=$(mktemp)
  if launchctl bootstrap "gui/$uid" "$plist" 2>"$err"; then
    rm -f "$err"
    return 0
  fi
  log_warn "launchctl bootstrap 1차 실패 — 재시도: $(head -c 200 "$err" 2>/dev/null | tr '\n' ' ')"
  rm -f "$err"
  sleep 0.55
  launchctl bootout "gui/$uid/$label" 2>/dev/null || true
  sleep 0.35
  if ! launchctl bootstrap "gui/$uid" "$plist"; then
    log_err "launchctl bootstrap 실패 — 터미널: launchctl bootout gui/$uid/$label 후 다시 setup"
    return 1
  fi
  return 0
}

# 레거시 단일 com.cursor.agent.worker.plist → 경로별 com.cursor.agent.worker.<hash>.plist
cursor_agent_migrate_legacy_worker_plist() {
  local legacy="$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist"
  [[ -f "$legacy" ]] || return 0
  local old_wd suf label np uid agent_bin wrap_script plist_src plist_tmp log_dir
  old_wd=$(plutil_string "$legacy" WorkingDirectory)
  [[ -n "$old_wd" ]] || {
    rm -f "$legacy"
    return 0
  }
  old_wd=$(expand_tilde "$old_wd")
  old_wd=$(cd "$old_wd" 2>/dev/null && pwd -P) || return 0
  suf=$(cursor_agent_worker_suffix_for_path "$old_wd") || return 0
  label="com.cursor.agent.worker.$suf"
  np="$HOME/Library/LaunchAgents/${label}.plist"
  uid="$(id -u)"
  launchctl bootout "gui/$uid/com.cursor.agent.worker" 2>/dev/null || true
  sleep 0.3
  if [[ -f "$np" ]]; then
    rm -f "$legacy"
    return 0
  fi
  agent_bin="$HOME/.local/bin/agent"
  wrap_script="$HOME/.cursor-setup/agent-worker-entry.sh"
  log_dir="$HOME/Library/Logs/CursorAgentWorker"
  plist_src=""
  plist_tmp=""
  if [[ -n "${CURSOR_SETUP_ROOT:-}" ]] && [[ -f "$CURSOR_SETUP_ROOT/templates/com.cursor.agent.worker.plist" ]]; then
    plist_src="$CURSOR_SETUP_ROOT/templates/com.cursor.agent.worker.plist"
  elif declare -F cursor_agent_worker_plist_template >/dev/null 2>&1; then
    plist_tmp="$(mktemp -t cursor-worker-plist)"
    cursor_agent_worker_plist_template > "$plist_tmp"
    plist_src="$plist_tmp"
  fi
  [[ -n "$plist_src" && -f "$plist_src" ]] || {
    [[ -n "$plist_tmp" ]] && rm -f "$plist_tmp"
    return 0
  }
  ensure_dir "$log_dir"
  sed -e "s|__LABEL__|$label|g" \
      -e "s|__WRAP_SCRIPT__|$wrap_script|g" \
      -e "s|__AGENT_BIN__|$agent_bin|g" \
      -e "s|__WORK_DIR__|$old_wd|g" \
      -e "s|__LOG_OUT__|$log_dir/agent-worker-$suf.log|g" \
      -e "s|__LOG_ERR__|$log_dir/agent-worker-$suf.err.log|g" \
      "$plist_src" > "$np"
  [[ -n "$plist_tmp" ]] && rm -f "$plist_tmp"
  if cursor_agent_launchctl_bootstrap_worker_plist "$uid" "$np" "$label"; then
    rm -f "$legacy"
    launchctl kickstart -k "gui/$uid/$label" 2>/dev/null || true
  fi
  return 0
}

# $1 작업 폴더 — 경로별 LaunchAgent 등록·기동 (대시보드에서 폴더마다 setup 시)
cursor_agent_install_launchagent_for_workspace_dir() {
  local work_dir="${1:?}"
  work_dir=$(expand_tilde "$work_dir")
  work_dir=$(cd "$work_dir" 2>/dev/null && pwd -P) || {
    log_err "작업 폴더 없음: $1"
    return 1
  }

  local plist_src="" plist_tmp="" label suf plist_dst log_dir wrap_script agent_bin uid
  agent_bin="$HOME/.local/bin/agent"
  wrap_script="$HOME/.cursor-setup/agent-worker-entry.sh"
  log_dir="$HOME/Library/Logs/CursorAgentWorker"
  ensure_dir "$log_dir"

  if [[ -n "${CURSOR_SETUP_ROOT:-}" ]] && [[ -f "$CURSOR_SETUP_ROOT/templates/com.cursor.agent.worker.plist" ]]; then
    plist_src="$CURSOR_SETUP_ROOT/templates/com.cursor.agent.worker.plist"
  elif declare -F cursor_agent_worker_plist_template >/dev/null 2>&1; then
    plist_tmp="$(mktemp -t cursor-worker-plist)"
    cursor_agent_worker_plist_template > "$plist_tmp"
    plist_src="$plist_tmp"
  fi

  if [[ -z "$plist_src" ]] || [[ ! -f "$plist_src" ]]; then
    log_err "worker plist 템플릿 없음"
    [[ -n "$plist_tmp" ]] && rm -f "$plist_tmp"
    return 1
  fi

  cursor_agent_install_worker_entry_script || {
    [[ -n "$plist_tmp" ]] && rm -f "$plist_tmp"
    return 1
  }

  suf=$(cursor_agent_worker_suffix_for_path "$work_dir") || {
    [[ -n "$plist_tmp" ]] && rm -f "$plist_tmp"
    return 1
  }
  label="com.cursor.agent.worker.$suf"
  plist_dst="$HOME/Library/LaunchAgents/${label}.plist"

  sed -e "s|__LABEL__|$label|g" \
      -e "s|__WRAP_SCRIPT__|$wrap_script|g" \
      -e "s|__AGENT_BIN__|$agent_bin|g" \
      -e "s|__WORK_DIR__|$work_dir|g" \
      -e "s|__LOG_OUT__|$log_dir/agent-worker-$suf.log|g" \
      -e "s|__LOG_ERR__|$log_dir/agent-worker-$suf.err.log|g" \
      "$plist_src" > "$plist_dst"
  [[ -n "$plist_tmp" ]] && rm -f "$plist_tmp"
  log_info "LaunchAgent plist 저장됨 ($label)"

  uid="$(id -u)"
  cursor_agent_launchctl_bootstrap_worker_plist "$uid" "$plist_dst" "$label" || return 1
  launchctl kickstart -k "gui/$uid/$label" 2>/dev/null || true
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

  work_dir=$(expand_tilde "$work_dir")
  work_dir=$(cd "$work_dir" 2>/dev/null && pwd -P) || {
    log_err "작업 폴더 없음"
    exit 1
  }

  cursor_agent_migrate_legacy_worker_plist

  if [[ "${CURSOR_SETUP_WORKSPACE_LOCKED:-0}" == "1" ]] || prompt_yn "이 폴더용 워커 자동 실행(재부팅 후에도) 등록할까요?" "y"; then
    cursor_agent_install_launchagent_for_workspace_dir "$work_dir" || exit 1
  else
    printf '%s\n' "  cd $(printf '%q' "$work_dir") && $agent_bin worker start"
  fi
}
