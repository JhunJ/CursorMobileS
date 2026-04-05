#!/usr/bin/env bash
# 설치·실행·Git 요약 (한눈에 보기)

github_cli_logged_in() {
  command_exists gh && gh auth status -h github.com >/dev/null 2>&1
}

# 맥에서 LISTEN 중인 TCP 포트 번호 나열 (참고용)
mac_listen_tcp_ports_csv() {
  command_exists lsof || return 0
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '
    NR>1 {
      n = split($9, a, ":");
      port = a[n];
      if (port ~ /^[0-9]+$/) p[port] = 1
    }
    END {
      for (x in p) print x
    }' | sort -un | head -40 | paste -sd, -
}

# 작업 폴더 목록: ~/.cursor-setup/workspaces.txt + ~/Dev 직하위 전체 + ~/Dev 아래(깊은) Git 루트
discover_workspace_paths() {
  {
    local f="$HOME/.cursor-setup/workspaces.txt"
    local d line gitdir
    if [[ -f "$f" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        d=$(expand_tilde "$line")
        [[ -d "$d" ]] && printf '%s\n' "$(realpath_dir "$d")"
      done < "$f"
    fi
    if [[ -d "$HOME/Dev" ]]; then
      shopt -s nullglob
      for d in "$HOME/Dev"/*; do
        [[ -d "$d" ]] || continue
        printf '%s\n' "$(realpath_dir "$d")"
      done
      shopt -u nullglob
      while IFS= read -r gitdir; do
        [[ -z "$gitdir" ]] && continue
        case "$gitdir" in
          *"/node_modules/"* | *"/vendor/"* | *"/.npm/"* | *"/.yarn/"*) continue ;;
        esac
        d="$(dirname "$gitdir")"
        [[ -d "$d" ]] && printf '%s\n' "$(realpath_dir "$d")"
      done < <(find "$HOME/Dev" -maxdepth 8 -type d -name .git 2>/dev/null)
    fi
  } | sort -u
}

# 이 작업 폴더에 대한 Cursor 워커 상태 (plist · 프로세스 · CLI 상태파일)
worker_status_detail_for_workspace() {
  local ws="$1"
  local ws_r plist lb
  ws_r=$(realpath_dir "$ws")

  if plist=$(cursor_agent_worker_plist_path_for_workspace "$ws" 2>/dev/null); then
    lb=$(plutil_string "$plist" Label)
    if launchagent_running "$lb"; then
      printf '%s\n' "워커 · 이 폴더 · 실행 중"
    else
      printf '%s\n' "워커 · 이 폴더 · 중지"
    fi
    return 0
  fi

  if [[ -f "$HOME/.cursor/agent-cli-state.json" ]] && { grep -Fq "$ws_r" "$HOME/.cursor/agent-cli-state.json" 2>/dev/null || grep -Fq "$ws" "$HOME/.cursor/agent-cli-state.json" 2>/dev/null; }; then
    if cursor_worker_process_running; then
      printf '%s\n' "워커 · CLI에 경로 있음 · 실행"
    else
      printf '%s\n' "워커 · CLI만 (LaunchAgent 없음)"
    fi
    return 0
  fi

  if cursor_worker_process_running; then
    printf '%s\n' "워커 실행 중 (폴더 미확인)"
    return 0
  fi

  printf '%s\n' "워커 없음"
}

# 대시보드 창용 짧은 글 (줄바꿈 포함)
status_dashboard_compact_for_dialog() {
  local w="${1:-}"
  [[ -z "$w" ]] && w="$(cursor_setup_default_workspace_dir)"
  w=$(expand_tilde "$w")

  local gh_ko ag_ko wk_ko

  if github_cli_logged_in; then
    gh_ko="로그인됨 ($(gh api user -q .login 2>/dev/null || echo 계정))"
  else
    gh_ko="로그인 필요"
  fi

  if [[ -x "$HOME/.local/bin/agent" ]]; then
    ag_ko="설치됨"
  else
    ag_ko="미설치"
  fi

  local _wreg _wrun
  _wreg=$(cursor_agent_worker_registered_count)
  _wrun=$(cursor_agent_worker_running_count)
  if [[ "$_wreg" -gt 0 ]]; then
    if [[ "$_wrun" -eq "$_wreg" ]]; then
      wk_ko="워커 ${_wreg}개 모두 실행 중"
    elif [[ "$_wrun" -gt 0 ]]; then
      wk_ko="워커 등록 ${_wreg} · 실행 ${_wrun}"
    else
      wk_ko="워커 등록 ${_wreg}개(멈춤)"
    fi
  elif cursor_worker_process_running; then
    wk_ko="프로세스만 실행 중"
  else
    wk_ko="워커 미등록"
  fi

  printf '%s\n' "지금 맥 상태 요약입니다."
  printf '%s\n' ""
  printf '%s\n' "· GitHub: $gh_ko"
  printf '%s\n' "· Cursor: $ag_ko · $wk_ko"
  printf '%s\n' "· 작업 폴더: $w"
  if [[ -d "$w/.git" ]]; then
    printf '%s\n' "· Git: $(git_one_line_status "$w")"
  else
    printf '%s\n' "· Git: 저장소 아님"
  fi
  printf '%s\n' ""
  printf '%s\n' "「설정」으로 마법사를 시작하세요."
}

git_one_line_status() {
  local d="${1:-}"
  [[ -d "$d/.git" ]] || { printf '%s\n' "(Git 폴더 아님)"; return; }
  (cd "$d" && git status -sb 2>/dev/null) | head -1
}

# 대시보드 출력 (비밀·토큰 출력 없음)
status_dashboard_print() {
  local work_dir="${1:-}"
  local repo_hint="${2:-}"

  local w="${work_dir:-}"
  [[ -z "$w" ]] && w="$(cursor_setup_default_workspace_dir)"
  local uid
  uid=$(id -u)

  printf '\n'
  printf '%s\n' "┌─────────────────────────────────────────────────────────────┐"
  printf '%s\n' "│  셋업 상태 요약 (관리 화면)                                  │"
  printf '%s\n' "└─────────────────────────────────────────────────────────────┘"

  printf '\n%s\n' "■ 도구 설치"
  printf '  %-22s %s\n' "git" "$(command_exists git && echo "있음" || echo "없음")"
  printf '  %-22s %s\n' "Homebrew" "$(command_exists brew && echo "있음" || echo "없음")"
  printf '  %-22s %s\n' "GitHub CLI (gh)" "$(command_exists gh && echo "있음" || echo "없음")"
  printf '  %-22s %s\n' "Cursor agent" "$([[ -x "$HOME/.local/bin/agent" ]] && echo "있음" || echo "없음")"

  printf '\n%s\n' "■ GitHub"
  if github_cli_logged_in; then
    local gl
    gl=$(gh api user -q .login 2>/dev/null || echo "(계정)")
    printf '  %-22s %s\n' "로그인" "됨 ($gl)"
  else
    printf '  %-22s %s\n' "로그인" "안 됨"
  fi

  printf '\n%s\n' "■ 작업 폴더 · Git"
  printf '  %-22s %s\n' "경로" "$w"
  if [[ -d "$w/.git" ]]; then
    local origin br line
    origin=$(cd "$w" && git remote get-url origin 2>/dev/null || echo "(origin 없음)")
    br=$(cd "$w" && git branch --show-current 2>/dev/null || echo "?")
    line=$(git_one_line_status "$w")
    printf '  %-22s %s\n' "origin" "$origin"
    printf '  %-22s %s\n' "브랜치" "$br"
    printf '  %-22s %s\n' "상태" "$line"
  else
    printf '  %-22s %s\n' "Git" "저장소 아님"
  fi
  [[ -n "$repo_hint" ]] && printf '  %-22s %s\n' "저장소 이름(참고)" "$repo_hint"

  printf '\n%s\n' "■ Cursor 워커 (LaunchAgent)"
  local p_worker wd lb _wl
  _wl=$(cursor_agent_worker_list_plists)
  if [[ -n "$_wl" ]]; then
    printf '  %-22s %s\n' "등록 수" "$(cursor_agent_worker_registered_count) plist"
    while IFS= read -r p_worker; do
      [[ -z "$p_worker" ]] && continue
      wd=$(plutil_string "$p_worker" WorkingDirectory)
      lb=$(plutil_string "$p_worker" Label)
      printf '  %-22s %s\n' "$lb" "${wd:-?}"
      if launchagent_running "$lb"; then
        printf '  %-22s %s\n' "  └ 실행" "동작 중"
      else
        printf '  %-22s %s\n' "  └ 실행" "멈춤/미기동"
      fi
    done <<<"$_wl"
  else
    printf '  %-22s %s\n' "LaunchAgent" "미등록"
  fi
  printf '  %-22s %s\n' "관리 HTTP 포트" "(기본 설정 없음 — worker 옵션으로만 가능)"
  if cursor_agent_state_file_present; then
    printf '  %-22s %s\n' "CLI 상태 파일" "있음 (로그인·사용 이력 가능)"
  else
    printf '  %-22s %s\n' "CLI 상태 파일" "없음"
  fi

  printf '\n%s\n' "■ Cursor 웹에서 직접 (자동 불가)"
  printf '  %s\n' "  Self-hosted agents ON · 기본 저장소 · main · agent/"
  printf '\n%s\n' "───────────────────────────────────────────────────────────────"
}
