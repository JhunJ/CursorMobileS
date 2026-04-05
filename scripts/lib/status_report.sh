#!/usr/bin/env bash
# 설치·실행·Git·Tunnel 요약 (한눈에 보기)

parse_cf_config_summary() {
  local cfg="$HOME/.cloudflared/config.yml"
  [[ -f "$cfg" ]] || return 1
  local tunnel_line host_line svc_line
  tunnel_line=$(grep -E '^tunnel:' "$cfg" | head -1 | sed 's/^tunnel:[[:space:]]*//')
  host_line=$(grep -E 'hostname:' "$cfg" | head -1 | sed 's/.*hostname:[[:space:]]*//')
  svc_line=$(grep -E 'service: http' "$cfg" | head -1 | sed 's/.*service:[[:space:]]*//')
  printf '%s\t%s\t%s\n' "${tunnel_line:-?}" "${host_line:-?}" "${svc_line:-?}"
}

cloudflare_has_tunnel_credentials() {
  local f
  shopt -s nullglob
  for f in "$HOME/.cloudflared"/*.json; do
    [[ -f "$f" ]] || continue
    case "$f" in
      *cert*) continue ;;
    esac
    return 0
  done
  shopt -u nullglob
  return 1
}

cloudflared_tunnel_list_ok() {
  command_exists cloudflared || return 1
  cloudflared tunnel list 2>/dev/null | grep -qE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}'
}

# config.yml 에 터널·호스트가 있으면 구성된 것으로 봄 (cert 없어도 token JSON 등으로 동작 가능)
cloudflare_looks_connected() {
  local cf_line tid host svc
  cf_line=$(parse_cf_config_summary 2>/dev/null) || return 1
  IFS=$'\t' read -r tid host svc <<<"$cf_line"
  [[ -n "$host" && "$host" != "?" ]] || [[ -n "$tid" && "$tid" != "?" ]] || return 1
  cloudflared_cert_ok && return 0
  cloudflare_has_tunnel_credentials && return 0
  cloudflared_tunnel_list_ok && return 0
  return 1
}

cloudflare_tunnel_running() {
  launchagent_running "com.cloudflared.tunnel" && return 0
  cloudflared_process_running && return 0
  return 1
}

github_cli_logged_in() {
  command_exists gh && gh auth status -h github.com >/dev/null 2>&1
}

# config.yml 의 ingress hostname → service (터널 라우트 요약)
cloudflare_config_ingress_pairs() {
  local cfg="$HOME/.cloudflared/config.yml"
  [[ -f "$cfg" ]] || return 0
  command_exists python3 || return 0
  CF_CFG="$cfg" python3 <<'PY'
import os, re, pathlib
p = pathlib.Path(os.environ["CF_CFG"])
t = p.read_text(encoding="utf-8", errors="replace")
for block in re.split(r"\n\s*-\s+", t):
    hm = re.search(r"hostname:\s*(\S+)", block)
    sv = re.search(r"service:\s*(\S+)", block)
    if hm and sv and "http_status" not in sv.group(1):
        print(hm.group(1) + "\t" + sv.group(1))
PY
}

# cloudflared CLI 에 등록된 터널 (이름·ID 일부)
cloudflared_tunnel_list_rows() {
  command_exists cloudflared || return 0
  cloudflared tunnel list 2>/dev/null | tail -n +2 | head -20
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
  local ws_r plist pw
  ws_r=$(realpath_dir "$ws")
  plist="$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist"

  if [[ -f "$plist" ]]; then
    pw=$(plutil_string "$plist" WorkingDirectory)
    pw=$(realpath_dir "$pw")
    if [[ "$pw" == "$ws_r" ]]; then
      if launchagent_running "com.cursor.agent.worker" || cursor_worker_process_running; then
        printf '%s\n' "워커 · 이 폴더 · 실행 중"
      else
        printf '%s\n' "워커 · 이 폴더 · 중지"
      fi
      return 0
    fi
    printf '%s\n' "워커 · 다른 폴더 ($pw)"
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
  local w="${1:-$HOME/Dev/AutoCRF}"
  w=$(expand_tilde "$w")

  local cf_ko gh_ko ag_ko wk_ko
  if cloudflare_looks_connected; then
    local _h _s cf_line
    cf_line=$(parse_cf_config_summary 2>/dev/null) || true
    IFS=$'\t' read -r _ _h _s <<<"$cf_line"
    if cloudflare_tunnel_running; then
      cf_ko="연결됨 · $_h · 터널 실행 중"
    else
      cf_ko="설정됨 · $_h · 터널 미실행"
    fi
  else
    cf_ko="연결 안 됨"
  fi

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

  if [[ -f "$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist" ]]; then
    if launchagent_running "com.cursor.agent.worker"; then
      wk_ko="워커 실행 중"
    else
      wk_ko="워커 등록됨(멈춤)"
    fi
  elif cursor_worker_process_running; then
    wk_ko="프로세스만 실행 중"
  else
    wk_ko="워커 미등록"
  fi

  printf '%s\n' "지금 맥 상태 요약입니다."
  printf '%s\n' ""
  printf '%s\n' "· Cloudflare: $cf_ko"
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

  local w="${work_dir:-$HOME/Dev/AutoCRF}"
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
  printf '  %-22s %s\n' "cloudflared" "$(command_exists cloudflared && echo "있음" || echo "없음")"
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
  local p_worker="$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist"
  if [[ -f "$p_worker" ]]; then
    local wd
    wd=$(plutil_string "$p_worker" WorkingDirectory)
    printf '  %-22s %s\n' "등록 plist" "있음"
    printf '  %-22s %s\n' "작업 디렉터리" "${wd:-?}"
    if launchagent_running "com.cursor.agent.worker"; then
      printf '  %-22s %s\n' "실행" "동작 중"
    else
      printf '  %-22s %s\n' "실행" "멈춤/미기동"
    fi
  else
    printf '  %-22s %s\n' "LaunchAgent" "미등록"
  fi
  printf '  %-22s %s\n' "관리 HTTP 포트" "(기본 설정 없음 — worker 옵션으로만 가능)"
  if cursor_agent_state_file_present; then
    printf '  %-22s %s\n' "CLI 상태 파일" "있음 (로그인·사용 이력 가능)"
  else
    printf '  %-22s %s\n' "CLI 상태 파일" "없음"
  fi

  printf '\n%s\n' "■ Cloudflare Tunnel"
  if cloudflared_cert_ok; then
    printf '  %-22s %s\n' "로그인(cert)" "있음"
  else
    printf '  %-22s %s\n' "로그인(cert)" "없음/미확인"
  fi
  local cf_line
  if cf_line=$(parse_cf_config_summary 2>/dev/null); then
    local tid host svc
    IFS=$'\t' read -r tid host svc <<<"$cf_line"
    printf '  %-22s %s\n' "config.yml" "있음 (~/.cloudflared/)"
    printf '  %-22s %s\n' "터널 ID" "$tid"
    printf '  %-22s %s\n' "공개 도메인" "$host"
    printf '  %-22s %s\n' "로컬로 보내는 주소" "$svc"
  else
    printf '  %-22s %s\n' "config.yml" "없음 또는 읽기 실패"
  fi
  local p_cf="$HOME/Library/LaunchAgents/com.cloudflared.tunnel.plist"
  if [[ -f "$p_cf" ]]; then
    if launchagent_running "com.cloudflared.tunnel"; then
      printf '  %-22s %s\n' "터널 LaunchAgent" "동작 중"
    else
      printf '  %-22s %s\n' "터널 LaunchAgent" "등록됨, 멈춤/미기동"
    fi
  else
    printf '  %-22s %s\n' "터널 LaunchAgent" "미등록"
  fi

  printf '\n%s\n' "■ Cursor 웹에서 직접 (자동 불가)"
  printf '  %s\n' "  Self-hosted agents ON · 기본 저장소 · main · agent/"
  printf '\n%s\n' "───────────────────────────────────────────────────────────────"
}
