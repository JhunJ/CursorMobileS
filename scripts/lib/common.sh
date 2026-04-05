#!/usr/bin/env bash
# 공통: 로깅, 프롬프트, dry-run, 경로 유틸 (bash 3.2 호환)

CURSOR_SETUP_DRY_RUN="${CURSOR_SETUP_DRY_RUN:-0}"
# CURSOR_SETUP_WITH_CF: 비어 있으면 preflight에서 물어봄. 1=포함, 0=건너뜀.
# CURSOR_SETUP_FAST_PROMPTS: 1이면 질문 없이 각 프롬프트의 기본값만 사용 (setup에서 기본 1, --interactive 로 끔)

log_info() { printf '%s\n' "[정보] $*"; }
log_warn() { printf '%s\n' "[경고] $*" >&2; }
log_err() { printf '%s\n' "[오류] $*" >&2; }

is_dry_run() {
  [[ "$CURSOR_SETUP_DRY_RUN" == "1" ]]
}

run_cmd() {
  if is_dry_run; then
    printf '%s\n' "[dry-run] $*"
    return 0
  fi
  "$@"
}

fast_prompts_enabled() {
  [[ "${CURSOR_SETUP_FAST_PROMPTS:-0}" == "1" ]]
}

# 배포 시 개인 경로 대신: CURSOR_SETUP_DEFAULT_WORKSPACE, 브랜드는 CURSOR_DASH_BRAND
cursor_setup_default_workspace_dir() {
  if [[ -n "${CURSOR_SETUP_DEFAULT_WORKSPACE:-}" ]]; then
    expand_tilde "${CURSOR_SETUP_DEFAULT_WORKSPACE}"
    return 0
  fi
  if [[ -n "${CURSOR_SETUP_ROOT:-}" ]]; then
    printf '%s\n' "$CURSOR_SETUP_ROOT"
    return 0
  fi
  printf '%s\n' "$HOME"
}

# 기본값이 대문자면 그게 기본 (Y/n 또는 y/N)
prompt_yn() {
  local msg="$1"
  local def="${2:-n}"
  if declare -F gui_mode_enabled >/dev/null 2>&1 && gui_mode_enabled; then
    log_info "[창] $msg"
    if gui_yes_no_dialog "$msg" "$def"; then return 0; else return 1; fi
  fi
  if fast_prompts_enabled; then
    if [[ "$def" == "y" || "$def" == "Y" ]]; then
      log_info "[자동] 예 — $msg"
      return 0
    fi
    log_info "[자동] 아니오 — $msg"
    return 1
  fi
  local hint
  if [[ "$def" == "y" || "$def" == "Y" ]]; then
    hint="[Y/n]"
  else
    hint="[y/N]"
  fi
  local ans
  printf '%s %s ' "$msg" "$hint" >&2
  read -r ans
  if [[ -z "$ans" ]]; then
    ans="$def"
  fi
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_with_default() {
  local msg="$1"
  local def="$2"
  if declare -F gui_mode_enabled >/dev/null 2>&1 && gui_mode_enabled; then
    log_info "[창 입력] $msg"
    gui_text_dialog "$msg" "$def"
    return
  fi
  if fast_prompts_enabled; then
    log_info "[자동] $msg → $def"
    printf '%s\n' "$def"
    return
  fi
  local val
  printf '%s [%s]: ' "$msg" "$def" >&2
  read -r val
  if [[ -z "$val" ]]; then
    printf '%s\n' "$def"
  else
    printf '%s\n' "$val"
  fi
}

ensure_dir() {
  local d="$1"
  if is_dry_run; then
    log_info "[dry-run] mkdir -p $d"
    return 0
  fi
  mkdir -p "$d"
}

# 한 줄이 없을 때만 파일 끝에 추가
append_line_once() {
  local file="$1"
  local line="$2"
  if [[ ! -f "$file" ]]; then
    if is_dry_run; then
      log_info "[dry-run] echo >> $file"
      return 0
    fi
    touch "$file"
  fi
  if grep -Fxq "$line" "$file" 2>/dev/null; then
    return 0
  fi
  if is_dry_run; then
    log_info "[dry-run] append to $file: $line"
    return 0
  fi
  printf '%s\n' "$line" >> "$file"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_macos() {
  [[ "$(uname -s)" == "Darwin" ]]
}

expand_tilde() {
  local p="$1"
  if [[ "$p" == ~* ]]; then
    p="${p/#\~/$HOME}"
  fi
  printf '%s\n' "$p"
}

cloudflared_cert_ok() {
  [[ -f "$HOME/.cloudflared/cert.pem" ]]
}

plutil_string() {
  local plist="$1"
  local key="$2"
  plutil -extract "$key" raw "$plist" 2>/dev/null || true
}

realpath_dir() {
  cd "$1" 2>/dev/null && pwd -P || printf '%s\n' "$1"
}

# plist 의 WorkingDirectory(~ 포함)·다른 문자열 표기와 실제 폴더가 같으면 0
dirs_same() {
  local a="${1:-}" b="${2:-}"
  [[ -z "$a" || -z "$b" ]] && return 1
  a=$(expand_tilde "$a")
  b=$(expand_tilde "$b")
  local ra rb
  ra=$(cd "$a" 2>/dev/null && pwd -P) || return 1
  rb=$(cd "$b" 2>/dev/null && pwd -P) || return 1
  [[ "$ra" == "$rb" ]] && return 0
  if [[ "$(uname -s)" == "Darwin" ]]; then
    local ia ib da db
    ia=$(stat -f '%i' "$ra" 2>/dev/null) || return 1
    ib=$(stat -f '%i' "$rb" 2>/dev/null) || return 1
    da=$(stat -f '%d' "$ra" 2>/dev/null) || return 1
    db=$(stat -f '%d' "$rb" 2>/dev/null) || return 1
    [[ "$ia" == "$ib" && "$da" == "$db" ]] && return 0
  fi
  return 1
}

# 실경로 기준 12자 hex — 폴더마다 별도 LaunchAgent 라벨에 사용
cursor_agent_worker_suffix_for_path() {
  local rp="${1:-}"
  [[ -n "$rp" ]] || return 1
  rp=$(expand_tilde "$rp")
  if ! rp=$(cd "$rp" 2>/dev/null && pwd -P); then
    rp=$(realpath_dir "$rp" 2>/dev/null) || return 1
  fi
  [[ -n "$rp" ]] || return 1
  printf '%s' "$rp" | shasum -a 256 2>/dev/null | awk '{print substr($1,1,12)}'
}

cursor_agent_worker_label_for_path() {
  local suf
  suf="$(cursor_agent_worker_suffix_for_path "$1")" || return 1
  printf 'com.cursor.agent.worker.%s\n' "$suf"
}

# LaunchAgents 안의 Cursor worker plist 한 줄씩 (레거시 단일 + 경로별)
cursor_agent_worker_list_plists() {
  shopt -s nullglob
  local f
  for f in "$HOME/Library/LaunchAgents"/com.cursor.agent.worker.plist "$HOME/Library/LaunchAgents"/com.cursor.agent.worker.*.plist; do
    [[ -f "$f" ]] || continue
    printf '%s\n' "$f"
  done
  shopt -u nullglob
}

cursor_agent_worker_plist_path_for_workspace() {
  local ws="$1" wf pw
  ws=$(realpath_dir "$ws")
  while IFS= read -r wf; do
    [[ -z "$wf" ]] && continue
    pw=$(plutil_string "$wf" WorkingDirectory)
    dirs_same "$pw" "$ws" && { printf '%s\n' "$wf"; return 0; }
  done < <(cursor_agent_worker_list_plists)
  return 1
}

cursor_agent_worker_registered_count() {
  local n=0 wf
  while IFS= read -r wf; do
    [[ -n "$wf" ]] && n=$((n + 1))
  done < <(cursor_agent_worker_list_plists)
  printf '%s\n' "$n"
}

cursor_agent_worker_running_count() {
  local n=0 wf lb
  while IFS= read -r wf; do
    [[ -z "$wf" ]] && continue
    lb=$(plutil_string "$wf" Label)
    [[ -n "$lb" ]] || continue
    launchagent_running "$lb" && n=$((n + 1))
  done < <(cursor_agent_worker_list_plists)
  printf '%s\n' "$n"
}

cursor_worker_process_running() {
  pgrep -f 'agent.*worker' >/dev/null 2>&1 || pgrep -f '/agent worker' >/dev/null 2>&1
}

cloudflared_process_running() {
  pgrep -x cloudflared >/dev/null 2>&1 || pgrep -f 'cloudflared tunnel' >/dev/null 2>&1
}

launchagent_running() {
  local label="$1"
  local out
  out=$(launchctl print "gui/$(id -u)/$label" 2>/dev/null || true)
  if printf '%s\n' "$out" | grep -qiE 'state = running|active count = [1-9]|runs *= *1'; then
    return 0
  fi
  [[ "$label" == "com.cursor.agent.worker" ]] && cursor_worker_process_running && return 0
  [[ "$label" == "com.cloudflared.tunnel" ]] && cloudflared_process_running && return 0
  return 1
}

cursor_agent_state_file_present() {
  [[ -f "$HOME/.cursor/agent-cli-state.json" ]]
}
