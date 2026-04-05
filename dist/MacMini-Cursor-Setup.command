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

# --- scripts/lib/common.sh.sh ---
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

# --- scripts/lib/status_report.sh.sh ---
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

# --- scripts/lib/dashboard_html.sh.sh ---
# 브라우저 HTML 대시보드 (GitHub Desktop 스타일). status_report.sh 이후에 source.

html_escape() {
  printf '%s' "${1:-}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

_dashboard_card() {
  local dot_class="$1"
  local title="$2"
  local body="$3"
  local extra="${4:-}"
  printf '      <div class="card">\n'
  printf '        <div class="card-h"><span class="dot %s"></span>%s</div>\n' "$dot_class" "$(html_escape "$title")"
  printf '        <div class="card-b">%s' "$(html_escape "$body")"
  [[ -n "$extra" ]] && printf '<div class="small mono">%s</div>' "$(html_escape "$extra")"
  printf '</div>\n      </div>\n'
}

dashboard_global_cards_html() {
  local cf_dot cf_title cf_body cf_extra cf_line tid host svc
  if cloudflare_looks_connected; then
    cf_dot="ok"
    cf_title="Cloudflare Tunnel"
    if cf_line=$(parse_cf_config_summary 2>/dev/null); then
      IFS=$'\t' read -r tid host svc <<<"$cf_line"
      cf_body="구성됨"
      cf_extra="도메인 ${host:-?} → ${svc:-?}"
    else
      cf_body="연결로 판단됨"
      cf_extra="config.yml 확인"
    fi
    if cloudflare_tunnel_running; then
      cf_body="${cf_body} · 터널 동작 중"
    else
      cf_body="${cf_body} · 터널 프로세스 없음"
    fi
  else
    cf_dot="bad"
    cf_title="Cloudflare Tunnel"
    cf_body="연결·설정 없음"
    cf_extra="~/.cloudflared/config.yml · cert · credentials.json"
  fi
  _dashboard_card "$cf_dot" "$cf_title" "$cf_body" "$cf_extra"

  if github_cli_logged_in; then
    _dashboard_card "ok" "GitHub" "로그인됨 ($(gh api user -q .login 2>/dev/null || echo 계정))" ""
  else
    _dashboard_card "bad" "GitHub" "gh 로그인 필요" "웹 브라우저로 로그인 (대시보드 버튼)"
  fi

  if [[ -x "$HOME/.local/bin/agent" ]]; then
    _dashboard_card "ok" "Cursor Agent" "CLI 설치됨" ""
  else
    _dashboard_card "warn" "Cursor Agent" "CLI 미설치" "~/.local/bin/agent"
  fi

  if [[ -f "$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist" ]]; then
    local pwd
    pwd=$(plutil_string "$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist" WorkingDirectory)
    if launchagent_running "com.cursor.agent.worker"; then
      _dashboard_card "ok" "Cursor 워커 (전역)" "LaunchAgent 동작 중" "$pwd"
    else
      _dashboard_card "warn" "Cursor 워커 (전역)" "plist 있음 · 지금 멈춤" "$pwd"
    fi
  elif cursor_worker_process_running; then
    _dashboard_card "warn" "Cursor 워커 (전역)" "프로세스만 실행 중" "LaunchAgent 없음"
  else
    _dashboard_card "bad" "Cursor 워커 (전역)" "미등록" ""
  fi

  if [[ -f "$HOME/Library/LaunchAgents/com.cloudflared.tunnel.plist" ]]; then
    if launchagent_running "com.cloudflared.tunnel"; then
      _dashboard_card "ok" "cloudflared 서비스" "Tunnel LaunchAgent 동작" ""
    else
      _dashboard_card "warn" "cloudflared 서비스" "plist 등록 · 멈춤" ""
    fi
  elif cloudflared_process_running; then
    _dashboard_card "ok" "cloudflared" "터널 프로세스 실행 중" ""
  else
    _dashboard_card "warn" "cloudflared" "백그라운드 터널 없음" ""
  fi
}

dashboard_workspace_rows_html() {
  local ws name origin br line worker_detail
  while IFS= read -r ws || [[ -n "$ws" ]]; do
    [[ -z "$ws" ]] && continue
    name=$(basename "$ws")
    if [[ -d "$ws/.git" ]]; then
      origin=$(cd "$ws" && git remote get-url origin 2>/dev/null || echo "origin 없음")
      br=$(cd "$ws" && git branch --show-current 2>/dev/null || echo "?")
      line=$(git_one_line_status "$ws")
    else
      origin="(Git 아님)"
      br="-"
      line="-"
    fi
    worker_detail=$(worker_status_detail_for_workspace "$ws")
    printf '    <div class="repo">\n'
    printf '      <div class="repo-top"><span class="repo-name">%s</span></div>\n' "$(html_escape "$name")"
    printf '      <div class="repo-path mono">%s</div>\n' "$(html_escape "$ws")"
    printf '      <div class="repo-meta"><span><strong>브랜치</strong> %s</span></div>\n' "$(html_escape "$br")"
    printf '      <div class="repo-meta mono">%s</div>\n' "$(html_escape "$origin")"
    printf '      <div class="repo-git mono">%s</div>\n' "$(html_escape "$line")"
    printf '      <div class="repo-worker">워커: %s</div>\n' "$(html_escape "$worker_detail")"
    printf '    </div>\n'
  done <<<"$(discover_workspace_paths)"
}

# 대시보드 서버용: 미완료 힌트 + 터미널로 이어가기 버튼
workspace_gap_hint_for_path() {
  local ws="$1"
  local hints="" sep=""
  if [[ ! -d "$ws" ]]; then
    printf '%s\n' "폴더 없음"
    return 0
  fi
  if [[ ! -d "$ws/.git" ]]; then
    hints="Git 초기화"
    sep=" · "
  fi
  if [[ -d "$ws/.git" ]] && ! (cd "$ws" && git remote get-url origin >/dev/null 2>&1); then
    hints="${hints}${sep}GitHub 원격"
    sep=" · "
  fi
  if ! github_cli_logged_in; then
    hints="${hints}${sep}gh 로그인"
    sep=" · "
  fi
  local ws_r plist pw
  ws_r=$(realpath_dir "$ws")
  plist="$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist"
  if [[ -f "$plist" ]]; then
    pw=$(plutil_string "$plist" WorkingDirectory)
    pw=$(realpath_dir "$pw")
    if [[ "$pw" != "$ws_r" ]]; then
      hints="${hints}${sep}워커를 이 폴더로"
      sep=" · "
    elif ! launchagent_running "com.cursor.agent.worker" && ! cursor_worker_process_running; then
      hints="${hints}${sep}워커 기동"
      sep=" · "
    fi
  else
    hints="${hints}${sep}워커 등록"
    sep=" · "
  fi
  if [[ -z "$hints" ]]; then
    printf '%s\n' "OK"
  else
    printf '%s\n' "${hints}"
  fi
}

dashboard_global_actions_html() {
  printf '    <div class="section-title section-muted">고급</div>\n'
  printf '    <div class="action-row">\n'
  printf '      <form method="post" action="/tunnel"><button type="submit" class="btn btn-secondary">Tunnel</button></form>\n'
  printf '      <form method="post" action="/full-wizard"><button type="submit" class="btn btn-secondary">전체 마법사</button></form>\n'
  printf '    </div>\n'
}

# 로컬 서버 대시보드: 카드마다 눌러서 터미널에서 이어가기
dashboard_global_cards_html_interactive() {
  local cf_line tid host svc cf_body cf_extra gh_user agent_bin cf_dot ports rows h s ingress_data
  if cloudflare_looks_connected; then cf_dot="ok"; else cf_dot="bad"; fi
  ports="$(mac_listen_tcp_ports_csv 2>/dev/null || true)"
  printf '      <div class="card card-setup">\n'
  printf '        <div class="card-h"><span class="dot %s"></span>Cloudflare</div>\n' "$cf_dot"
  if cloudflare_looks_connected; then
    cf_body="연결됨"
    if cf_line=$(parse_cf_config_summary 2>/dev/null); then
      IFS=$'\t' read -r tid host svc <<<"$cf_line"
      cf_extra="${host:-?} → ${svc:-?}"
    else
      cf_extra=""
    fi
    if cloudflare_tunnel_running; then
      cf_body="${cf_body} · 실행 중"
    else
      cf_body="${cf_body} · 중지"
    fi
    printf '        <p class="card-lead ok">%s</p>\n' "$(html_escape "$cf_body")"
    [[ -n "$cf_extra" ]] && printf '        <p class="card-sub mono">%s</p>\n' "$(html_escape "$cf_extra")"
    printf '        <div class="cf-detail">\n'
    printf '          <div class="cf-detail-title">라우트</div>\n'
    ingress_data=$(cloudflare_config_ingress_pairs)
    printf '          <ul class="mono">\n'
    if [[ -z "$ingress_data" ]]; then
      printf '            <li>없음</li>\n'
    else
      while IFS=$'\t' read -r h s || [[ -n "$h" ]]; do
        [[ -z "$h" ]] && continue
        printf '            <li>%s → %s</li>\n' "$(html_escape "$h")" "$(html_escape "$s")"
      done <<<"$ingress_data"
    fi
    printf '          </ul>\n'
    printf '          <div class="cf-detail-title">터널 (CLI)</div>\n'
    printf '          <ul class="mono">\n'
    rows=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" ]] && continue
      printf '            <li>%s</li>\n' "$(html_escape "$line")"
      rows=$((rows + 1))
    done < <(cloudflared_tunnel_list_rows)
    [[ "$rows" -eq 0 ]] && printf '            <li>—</li>\n'
    printf '          </ul>\n'
    printf '        </div>\n'
    if [[ -n "$ports" ]]; then
      printf '        <div class="cf-ports mono">%s</div>\n' "$(html_escape "$ports")"
    fi
    printf '        <div class="card-actions">\n'
    printf '          <form method="post" action="/tunnel"><button type="submit" class="btn btn-secondary btn-small">다시 설정</button></form>\n'
    printf '        </div>\n'
  else
    printf '        <p class="card-lead bad">미설정</p>\n'
    if [[ -n "$ports" ]]; then
      printf '        <div class="cf-ports mono">%s</div>\n' "$(html_escape "$ports")"
    fi
    printf '        <form method="post" action="/tunnel"><button type="submit" class="btn">Tunnel 설정</button></form>\n'
  fi
  printf '      </div>\n'

  printf '      <div class="card card-setup">\n'
  if github_cli_logged_in; then
    gh_user="$(gh api user -q .login 2>/dev/null || true)"
    printf '        <div class="card-h"><span class="dot ok"></span>GitHub</div>\n'
    printf '        <p class="card-lead ok">%s</p>\n' "$(html_escape "${gh_user:-로그인됨}")"
    printf '        <div class="card-actions">\n'
    printf '          <form method="post" action="/action/open-github"><button type="submit" class="btn btn-secondary btn-small">github.com</button></form>\n'
    printf '          <form method="post" action="/action/gh-login"><button type="submit" class="btn btn-secondary btn-small">다시 로그인</button></form>\n'
    printf '        </div>\n'
  else
    printf '        <div class="card-h"><span class="dot bad"></span>GitHub</div>\n'
    printf '        <p class="card-lead bad">로그인 필요</p>\n'
    printf '        <form method="post" action="/action/gh-login"><button type="submit" class="btn">로그인</button></form>\n'
  fi
  printf '      </div>\n'

  agent_bin="$HOME/.local/bin/agent"
  printf '      <div class="card card-setup">\n'
  if [[ -x "$agent_bin" ]]; then
    if cursor_agent_state_file_present; then
      printf '        <div class="card-h"><span class="dot ok"></span>Agent CLI</div>\n'
      printf '        <p class="card-lead ok">설치됨</p>\n'
      printf '        <div class="card-actions">\n'
      printf '          <form method="post" action="/action/agent-login"><button type="submit" class="btn btn-secondary btn-small">로그인</button></form>\n'
      printf '          <form method="post" action="/action/open-cursor-docs"><button type="submit" class="btn btn-secondary btn-small">문서</button></form>\n'
      printf '        </div>\n'
    else
      printf '        <div class="card-h"><span class="dot warn"></span>Agent CLI</div>\n'
      printf '        <p class="card-lead bad">로그인 필요</p>\n'
      printf '        <form method="post" action="/action/agent-login"><button type="submit" class="btn">로그인</button></form>\n'
    fi
  else
    printf '        <div class="card-h"><span class="dot bad"></span>Agent CLI</div>\n'
    printf '        <p class="card-lead bad">미설치</p>\n'
    printf '        <form method="post" action="/action/agent-install"><button type="submit" class="btn">설치</button></form>\n'
  fi
  printf '      </div>\n'

  printf '      <div class="card card-setup">\n'
  if [[ -f "$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist" ]]; then
    local pwd
    pwd=$(plutil_string "$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist" WorkingDirectory)
    if launchagent_running "com.cursor.agent.worker"; then
      printf '        <div class="card-h"><span class="dot ok"></span>워커</div>\n'
      printf '        <p class="card-lead ok">실행 중</p>\n'
      printf '        <p class="card-sub mono">%s</p>\n' "$(html_escape "$pwd")"
      printf '        <div class="card-actions">\n'
      printf '          <form method="post" action="/action/worker-kickstart"><button type="submit" class="btn btn-secondary btn-small">재시작</button></form>\n'
      printf '        </div>\n'
    else
      printf '        <div class="card-h"><span class="dot warn"></span>워커</div>\n'
      printf '        <p class="card-lead bad">중지</p>\n'
      printf '        <p class="card-sub mono">%s</p>\n' "$(html_escape "$pwd")"
      printf '        <form method="post" action="/action/worker-kickstart"><button type="submit" class="btn">시작</button></form>\n'
    fi
  elif cursor_worker_process_running; then
    printf '        <div class="card-h"><span class="dot warn"></span>워커</div>\n'
    printf '        <p class="card-lead bad">프로세스만 실행</p>\n'
    printf '        <p class="card-sub">아래 폴더에서 등록</p>\n'
  else
    printf '        <div class="card-h"><span class="dot bad"></span>워커</div>\n'
    printf '        <p class="card-lead bad">미등록</p>\n'
    printf '        <p class="card-sub">아래 폴더에서 설정</p>\n'
  fi
  printf '      </div>\n'
}

dashboard_global_actions_html_interactive() {
  printf '    <div class="section-title section-muted">고급</div>\n'
  printf '    <div class="action-row">\n'
  printf '      <form method="post" action="/full-wizard"><button type="submit" class="btn btn-secondary">전체 마법사</button></form>\n'
  printf '    </div>\n'
}

dashboard_workspace_rows_html_interactive() {
  local ws name origin br line worker_detail gap
  while IFS= read -r ws || [[ -n "$ws" ]]; do
    [[ -z "$ws" ]] && continue
    name=$(basename "$ws")
    if [[ -d "$ws/.git" ]]; then
      origin=$(cd "$ws" && git remote get-url origin 2>/dev/null || echo "origin 없음")
      br=$(cd "$ws" && git branch --show-current 2>/dev/null || echo "?")
      line=$(git_one_line_status "$ws")
    else
      origin="(Git 아님)"
      br="-"
      line="-"
    fi
    worker_detail=$(worker_status_detail_for_workspace "$ws")
    gap=$(workspace_gap_hint_for_path "$ws")
    printf '    <div class="repo" data-ws-path="%s">\n' "$(html_escape "$ws")"
    printf '      <div class="repo-top"><button type="button" class="ws-star-btn" title="즐겨찾기" aria-label="즐겨찾기" aria-pressed="false">☆</button><span class="repo-name">%s</span></div>\n' "$(html_escape "$name")"
    printf '      <div class="repo-path mono">%s</div>\n' "$(html_escape "$ws")"
    printf '      <div class="repo-meta"><span><strong>브랜치</strong> %s</span></div>\n' "$(html_escape "$br")"
    printf '      <div class="repo-meta mono">%s</div>\n' "$(html_escape "$origin")"
    printf '      <div class="repo-git mono">%s</div>\n' "$(html_escape "$line")"
    printf '      <div class="repo-worker">%s</div>\n' "$(html_escape "$worker_detail")"
    printf '      <div class="gap-hint">%s</div>\n' "$(html_escape "$gap")"
    printf '      <form class="repo-form" method="post" action="/configure">\n'
    printf '        <input type="hidden" name="path" value="%s" />\n' "$(html_escape "$ws")"
    printf '        <button type="submit" class="btn">이 폴더 설정</button>\n'
    printf '      </form>\n'
    printf '    </div>\n'
  done <<<"$(discover_workspace_paths)"
}

dashboard_emit_html_template() {
  cat <<'DASH_TMPL'
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>맥미니</title>
<style>
  :root { --bg:#0d1117; --surface:#161b22; --border:#30363d; --text:#e6edf3; --muted:#8b949e; --accent:#2f81f7; --ok:#3fb950; --warn:#d29922; --bad:#f85149; }
  * { box-sizing: border-box; }
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif; background:var(--bg); color:var(--text); font-size:14px; line-height:1.45; }
  .app { display:grid; grid-template-columns:minmax(200px,260px) 1fr; min-height:100vh; }
  @media (max-width:720px){ .app{ grid-template-columns:1fr;} .sidebar{ border-right:none; border-bottom:1px solid var(--border);} }
  .sidebar { background:#010409; border-right:1px solid var(--border); padding:20px 16px; }
  .sidebar h1 { font-size:13px; font-weight:600; margin:0 0 8px; color:var(--muted); text-transform:uppercase; letter-spacing:.04em; }
  .brand { font-size:18px; font-weight:700; margin-bottom:16px; }
  .sidebar p { font-size:12px; color:var(--muted); margin:0 0 12px; }
  .sidebar-tag { font-size:11px; opacity:.9; margin-bottom:16px !important; }
  .main { padding:24px 28px 48px; max-width:960px; }
  .section-title { font-size:12px; font-weight:600; color:var(--muted); text-transform:uppercase; margin:0 0 12px; letter-spacing:.04em; }
  .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(200px,1fr)); gap:12px; margin-bottom:28px; }
  .card { background:var(--surface); border:1px solid var(--border); border-radius:8px; padding:14px; }
  .card-setup { display:flex; flex-direction:column; align-items:flex-start; gap:6px; min-height:120px; }
  .card-h { font-weight:600; font-size:13px; display:flex; align-items:center; gap:8px; margin-bottom:4px; }
  .card-lead { font-size:13px; margin:0; font-weight:600; line-height:1.35; }
  .card-lead.ok { color:var(--ok); }
  .card-lead.bad { color:var(--bad); }
  .card-sub { font-size:12px; color:var(--muted); margin:0; line-height:1.4; max-width:100%; }
  .card-actions { display:flex; flex-wrap:wrap; gap:8px; margin-top:6px; }
  .btn-small { font-size:12px; padding:6px 10px; }
  .section-muted { opacity:.95; margin-top:4px !important; }
  .side-exec { font-size:11px; color:var(--muted); margin-top:12px; padding-top:12px; border-top:1px solid var(--border); line-height:1.4; word-break:break-all; }
  .side-note { font-size:10px; color:var(--muted); margin:8px 0 0; line-height:1.35; }
  .side-note kbd { background:#21262d; padding:2px 6px; border-radius:4px; font-size:10px; }
  .card-b { font-size:12px; color:var(--muted); }
  .card-b .small { margin-top:6px; font-size:11px; }
  .dot { width:8px; height:8px; border-radius:50%; flex-shrink:0; }
  .dot.ok { background:var(--ok); box-shadow:0 0 8px rgba(63,185,80,.35); }
  .dot.warn { background:var(--warn); }
  .dot.bad { background:var(--bad); }
  .mono { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:11px; word-break:break-all; }
  .repo { background:var(--surface); border:1px solid var(--border); border-radius:10px; padding:16px 18px; margin-bottom:14px; }
  .repo-name { font-size:16px; font-weight:600; }
  .repo-path { color:var(--muted); font-size:11px; margin:6px 0 10px; }
  .repo-meta { font-size:12px; color:var(--muted); margin-bottom:6px; }
  .repo-git { font-size:12px; margin-bottom:8px; }
  .repo-worker { font-size:12px; color:var(--accent); border-top:1px solid var(--border); padding-top:10px; margin-top:6px; }
  .gap-hint { font-size:12px; color:var(--muted); margin:10px 0 8px; line-height:1.4; }
  .repo-form { margin:0; }
  .btn { appearance:none; border:none; cursor:pointer; font-size:13px; font-weight:600; padding:8px 14px; border-radius:6px; background:var(--accent); color:#fff; }
  .btn:hover { filter:brightness(1.08); }
  .btn-secondary { background:#21262d; color:var(--text); border:1px solid var(--border); }
  .action-row { display:flex; flex-wrap:wrap; gap:10px; margin-bottom:24px; }
  .action-row form { margin:0; }
  footer { margin-top:32px; font-size:11px; color:var(--muted); border-top:1px solid var(--border); padding-top:14px; }
  footer a { color:var(--accent); }
  code { background:#21262d; padding:2px 6px; border-radius:4px; font-size:11px; }
  .dash-toast { position:fixed; bottom:0; left:0; right:0; z-index:9999; padding:14px 22px; background:#21262d; border-top:1px solid var(--border); font-size:13px; color:var(--text); line-height:1.45; box-shadow:0 -8px 24px rgba(0,0,0,.35); transform:translateY(110%); transition:transform .22s ease; }
  .dash-toast.visible { transform:translateY(0); }
  .ws-toolbar { display:flex; flex-wrap:wrap; align-items:center; gap:12px; margin:0 0 16px; padding:12px 14px; background:var(--surface); border:1px solid var(--border); border-radius:8px; }
  .ws-toolbar label { font-size:12px; color:var(--muted); font-weight:600; }
  .ws-search-input { flex:1; min-width:180px; max-width:420px; padding:8px 12px; border-radius:6px; border:1px solid var(--border); background:#0d1117; color:var(--text); font-size:14px; }
  .ws-search-input::placeholder { color:var(--muted); }
  .ws-favorites-block { margin-bottom:20px; padding-bottom:16px; border-bottom:1px solid var(--border); }
  .ws-favorites-block[hidden] { display:none !important; }
  .section-title.ws-sub { margin-top:0; }
  .ws-list { margin-bottom:8px; }
  .repo-top { display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
  .ws-star-btn { flex-shrink:0; width:36px; height:36px; border-radius:8px; border:1px solid var(--border); background:#21262d; color:var(--warn); font-size:18px; line-height:1; cursor:pointer; padding:0; }
  .ws-star-btn:hover { background:#30363d; }
  .ws-star-btn.active { color:var(--warn); }
  .cf-detail { margin-top:6px; padding-top:8px; border-top:1px solid var(--border); font-size:11px; }
  .cf-detail-title { color:var(--muted); font-weight:600; margin:12px 0 6px; font-size:10px; text-transform:uppercase; letter-spacing:.04em; }
  .cf-detail ul { margin:0 0 8px; padding-left:18px; color:var(--text); }
  .cf-detail li { margin:5px 0; word-break:break-word; }
  .cf-ports { margin-top:8px; padding:8px 10px; background:#0d1117; border-radius:6px; font-size:11px; color:var(--muted); line-height:1.35; border:1px solid var(--border); }
</style>
</head>
<body>
<div class="app">
  <aside class="sidebar">
    <h1>Cursor</h1>
    <div class="brand">맥미니</div>
    <p class="sidebar-tag">버튼 → 터미널</p>
    __SIDEBAR_EXEC__
  </aside>
  <main class="main">
    <div class="section-title">__H_S1__</div>
    <div class="grid">
__GLOBAL_CARDS__
    </div>
__GLOBAL_ACTIONS__
    <div class="section-title">__H_S2__</div>
    <div class="ws-toolbar">
      <label for="ws-search">검색</label>
      <input type="search" id="ws-search" class="ws-search-input" placeholder="이름 · 경로" autocomplete="off" enterkeyhint="search" />
    </div>
    <div id="ws-favorites-block" class="ws-favorites-block" hidden>
      <div class="section-title ws-sub">즐겨찾기</div>
      <div id="ws-favorites-list" class="ws-list"></div>
    </div>
    <div class="section-title ws-sub" id="ws-all-heading">폴더</div>
    <div id="ws-all-list" class="ws-list">
__WORKSPACES__
    </div>
    <footer>__GENERATED_AT____FOOTER_NOTE__</footer>
  </main>
</div>
__DASH_STAY_SCRIPT__
</body>
</html>
DASH_TMPL
}

# stdout: 생성된 HTML 경로
status_dashboard_write_html() {
  local out="${1:-}"
  [[ -n "$out" ]] || out="$(mktemp /tmp/cursor-dash.XXXXXX).html"
  local gfile gafile wfile tfile sfile gen
  gfile=$(mktemp)
  gafile=$(mktemp)
  wfile=$(mktemp)
  tfile=$(mktemp)
  sfile=$(mktemp)
  dashboard_global_cards_html > "$gfile"
  printf '\n' > "$gafile"
  printf '%s\n' '<p class="side-note">로컬 서버: <code>./setup</code></p>' > "$sfile"
  if ! discover_workspace_paths | grep -q .; then
    printf '%s\n' '    <div class="repo"><div class="repo-name">폴더 없음</div><div class="repo-path mono">~/Dev · workspaces.txt</div></div>' > "$wfile"
  else
    dashboard_workspace_rows_html > "$wfile"
  fi
  dashboard_emit_html_template > "$tfile"
  gen=$(date '+%Y-%m-%d %H:%M:%S')
  local fnote
  fnote=''
  if command_exists python3; then
    TPL="$tfile" G="$gfile" GA="$gafile" W="$wfile" SB="$sfile" O="$out" GEN="$gen" FN="$fnote" HS1="전역" HS2="폴더" python3 <<'PY'
import pathlib, os
t = pathlib.Path(os.environ["TPL"]).read_text(encoding="utf-8")
g = pathlib.Path(os.environ["G"]).read_text(encoding="utf-8")
ga = pathlib.Path(os.environ["GA"]).read_text(encoding="utf-8")
w = pathlib.Path(os.environ["W"]).read_text(encoding="utf-8")
sb = pathlib.Path(os.environ["SB"]).read_text(encoding="utf-8")
pathlib.Path(os.environ["O"]).write_text(
    t.replace("__GLOBAL_CARDS__", g)
    .replace("__GLOBAL_ACTIONS__", ga)
    .replace("__WORKSPACES__", w)
    .replace("__GENERATED_AT__", os.environ["GEN"])
    .replace("__FOOTER_NOTE__", os.environ["FN"])
    .replace("__SIDEBAR_EXEC__", sb)
    .replace("__H_S1__", os.environ["HS1"])
    .replace("__H_S2__", os.environ["HS2"])
    .replace("__DASH_STAY_SCRIPT__", ""),
    encoding="utf-8",
)
PY
  else
    log_err "python3 가 필요합니다 (HTML 대시보드)"
    rm -f "$gfile" "$gafile" "$wfile" "$tfile" "$sfile"
    return 1
  fi
  rm -f "$gfile" "$gafile" "$wfile" "$tfile" "$sfile"
  [[ "${CURSOR_SETUP_HTML_QUIET:-0}" == "1" ]] || printf '%s\n' "$out"
}

_dashboard_stay_script_fragment() {
  cat <<'JSEOF'
<div id="dash-toast" class="dash-toast" role="status" aria-live="polite"></div>
<script>
(function () {
  document.addEventListener('submit', function (e) {
    var f = e.target;
    if (!f || f.tagName !== 'FORM') return;
    var method = (f.getAttribute('method') || 'get').toLowerCase();
    if (method !== 'post') return;
    var act = f.getAttribute('action') || '';
    if (!act || act.charAt(0) !== '/') return;
    e.preventDefault();
    var bar = document.getElementById('dash-toast');
    var btn = f.querySelector('button[type="submit"]');
    if (bar) {
      bar.textContent = '터미널 확인…';
      bar.classList.add('visible');
    }
    if (btn) btn.disabled = true;
    /* FormData 는 multipart 로 나가서 서버(parse_qs)가 필드를 못 읽음 → /configure path 빈 값·403 방지 */
    fetch(act, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' },
      body: new URLSearchParams(new FormData(f)),
      credentials: 'same-origin'
    })
      .then(function (res) {
        if (res.status === 403) {
          if (bar) bar.textContent = '허용 목록 없음 → 아래 새로고침 후 다시';
          return;
        }
        if (!res.ok) {
          if (bar) bar.textContent = '오류 ' + res.status + ' · ./setup --workspace …';
          return;
        }
        var reloadQuick = ['/action/gh-login', '/action/agent-login', '/action/worker-kickstart'];
        var reloadSlow = ['/action/agent-install', '/tunnel'];
        if (reloadQuick.indexOf(act) !== -1) {
          if (bar) bar.textContent = '잠시 후 새로고침…';
          setTimeout(function () { window.location.reload(); }, 2200);
        } else if (reloadSlow.indexOf(act) !== -1) {
          if (bar) bar.textContent = '끝나면 새로고침…';
          setTimeout(function () { window.location.reload(); }, act === '/action/agent-install' ? 9000 : 5000);
        } else if (act === '/configure') {
          if (bar) bar.textContent = '터미널에서 진행 · 끝나면 새로고침';
        } else if (act === '/full-wizard') {
          if (bar) bar.textContent = '터미널 마법사 · 상태는 새로고침';
        } else if (act === '/action/open-github' || act === '/action/open-cursor-docs') {
          if (bar) bar.textContent = '브라우저 확인';
        } else {
          if (bar) bar.textContent = '완료 · 필요 시 새로고침';
        }
      })
      .catch(function () {
        if (bar) bar.textContent = '연결 실패 · 127.0.0.1 대시보드인지 확인';
      })
      .finally(function () {
        if (btn) btn.disabled = false;
      });
  });
})();
</script>
JSEOF
}

_dashboard_ws_search_fav_script_fragment() {
  cat <<'WSEOF'
<script>
(function () {
  var LS_KEY = 'cursorSetupWorkspaceFavorites_v1';
  function getFavs() {
    try {
      var raw = localStorage.getItem(LS_KEY);
      if (!raw) return [];
      var a = JSON.parse(raw);
      return Array.isArray(a) ? a : [];
    } catch (e) { return []; }
  }
  function setFavs(arr) {
    localStorage.setItem(LS_KEY, JSON.stringify(arr));
  }
  function collectCards() {
    var out = [];
    var all = document.getElementById('ws-all-list');
    var fav = document.getElementById('ws-favorites-list');
    [fav, all].forEach(function (list) {
      if (!list) return;
      Array.prototype.slice.call(list.querySelectorAll('.repo[data-ws-path]')).forEach(function (c) {
        out.push(c);
      });
    });
    return out;
  }
  function layoutWorkspaces() {
    var allList = document.getElementById('ws-all-list');
    var favList = document.getElementById('ws-favorites-list');
    if (!allList || !favList) return;
    var favs = getFavs();
    collectCards().forEach(function (card) {
      var p = card.getAttribute('data-ws-path');
      if (!p) return;
      var on = favs.indexOf(p) !== -1;
      var btn = card.querySelector('.ws-star-btn');
      if (btn) {
        btn.textContent = on ? '\u2605' : '\u2606';
        btn.classList.toggle('active', on);
        btn.setAttribute('aria-pressed', on ? 'true' : 'false');
      }
      if (on) favList.appendChild(card);
      else allList.appendChild(card);
    });
    applyWorkspaceSearch();
  }
  function applyWorkspaceSearch() {
    var inp = document.getElementById('ws-search');
    var q = inp && inp.value ? inp.value.trim().toLowerCase() : '';
    ['ws-favorites-list', 'ws-all-list'].forEach(function (id) {
      var el = document.getElementById(id);
      if (!el) return;
      el.querySelectorAll('.repo[data-ws-path]').forEach(function (card) {
        var path = (card.getAttribute('data-ws-path') || '').toLowerCase();
        var nm = '';
        var ne = card.querySelector('.repo-name');
        if (ne) nm = (ne.textContent || '').toLowerCase();
        var show = !q || path.indexOf(q) !== -1 || nm.indexOf(q) !== -1;
        card.style.display = show ? '' : 'none';
      });
    });
    var block = document.getElementById('ws-favorites-block');
    var favList = document.getElementById('ws-favorites-list');
    if (block && favList) {
      var vis = 0;
      favList.querySelectorAll('.repo[data-ws-path]').forEach(function (c) {
        if (c.style.display !== 'none') vis++;
      });
      block.hidden = vis === 0;
    }
    var h = document.getElementById('ws-all-heading');
    if (h) h.textContent = getFavs().length > 0 ? '나머지 폴더' : '폴더';
  }
  document.addEventListener('DOMContentLoaded', function () {
    document.body.addEventListener('click', function (e) {
      var t = e.target;
      if (!t || !t.classList || !t.classList.contains('ws-star-btn')) return;
      e.preventDefault();
      e.stopPropagation();
      var card = t.closest('.repo');
      if (!card) return;
      var p = card.getAttribute('data-ws-path');
      if (!p) return;
      var favs = getFavs();
      var i = favs.indexOf(p);
      if (i === -1) favs.push(p);
      else favs.splice(i, 1);
      setFavs(favs);
      layoutWorkspaces();
    });
    var search = document.getElementById('ws-search');
    if (search) {
      search.addEventListener('input', applyWorkspaceSearch);
      search.addEventListener('search', applyWorkspaceSearch);
    }
    layoutWorkspaces();
  });
})();
</script>
WSEOF
}

# 로컬 대시보드 서버용 (버튼·새로고침 링크 포함)
status_dashboard_write_html_interactive() {
  local out="${1:-}"
  [[ -n "$out" ]] || out="$(mktemp /tmp/cursor-dash.XXXXXX).html"
  local gfile gafile wfile tfile sfile gen setup_ex
  gfile=$(mktemp)
  gafile=$(mktemp)
  wfile=$(mktemp)
  tfile=$(mktemp)
  sfile=$(mktemp)
  local _root="${CURSOR_SETUP_ROOT:-${ROOT:-.}}"
  if [[ -n "${CURSOR_SETUP_EXEC_HINT:-}" ]]; then
    setup_ex="$CURSOR_SETUP_EXEC_HINT"
  elif [[ -f "$_root/setup" ]]; then
    setup_ex="$_root/setup"
  elif [[ -f "$_root/MacMini-Cursor-Setup.command" ]]; then
    setup_ex="$_root/MacMini-Cursor-Setup.command"
  else
    setup_ex="$_root/setup"
  fi
  {
    printf '<div class="side-exec">%s</div>\n' "$(html_escape "$setup_ex")"
    printf '<p class="side-note">끄기: 터미널 <kbd>Ctrl+C</kbd></p>\n'
  } > "$sfile"
  dashboard_global_cards_html_interactive > "$gfile"
  dashboard_global_actions_html_interactive > "$gafile"
  if ! discover_workspace_paths | grep -q .; then
    printf '%s\n' '    <div class="repo"><div class="repo-name">폴더 없음</div><div class="repo-path mono"><a href="/refresh">새로고침</a> · ~/Dev 또는 ~/.cursor-setup/workspaces.txt</div><form class="repo-form" method="post" action="/full-wizard"><button type="submit" class="btn">전체 마법사</button></form></div>' > "$wfile"
  else
    dashboard_workspace_rows_html_interactive > "$wfile"
  fi
  dashboard_emit_html_template > "$tfile"
  local jfile
  jfile=$(mktemp)
  {
    _dashboard_stay_script_fragment
    _dashboard_ws_search_fav_script_fragment
  } > "$jfile"
  gen=$(date '+%Y-%m-%d %H:%M:%S')
  local fnote
  fnote=' · <a href="/refresh">새로고침</a>'
  if command_exists python3; then
    TPL="$tfile" G="$gfile" GA="$gafile" W="$wfile" SB="$sfile" JF="$jfile" O="$out" GEN="$gen" FN="$fnote" HS1="전역" HS2="폴더" python3 <<'PY'
import pathlib, os
t = pathlib.Path(os.environ["TPL"]).read_text(encoding="utf-8")
g = pathlib.Path(os.environ["G"]).read_text(encoding="utf-8")
ga = pathlib.Path(os.environ["GA"]).read_text(encoding="utf-8")
w = pathlib.Path(os.environ["W"]).read_text(encoding="utf-8")
sb = pathlib.Path(os.environ["SB"]).read_text(encoding="utf-8")
js = pathlib.Path(os.environ["JF"]).read_text(encoding="utf-8")
pathlib.Path(os.environ["O"]).write_text(
    t.replace("__GLOBAL_CARDS__", g)
    .replace("__GLOBAL_ACTIONS__", ga)
    .replace("__WORKSPACES__", w)
    .replace("__GENERATED_AT__", os.environ["GEN"])
    .replace("__FOOTER_NOTE__", os.environ["FN"])
    .replace("__SIDEBAR_EXEC__", sb)
    .replace("__H_S1__", os.environ["HS1"])
    .replace("__H_S2__", os.environ["HS2"])
    .replace("__DASH_STAY_SCRIPT__", js),
    encoding="utf-8",
)
PY
  else
    log_err "python3 가 필요합니다 (HTML 대시보드)"
    rm -f "$gfile" "$gafile" "$wfile" "$tfile" "$sfile" "$jfile"
    return 1
  fi
  rm -f "$gfile" "$gafile" "$wfile" "$tfile" "$sfile" "$jfile"
  [[ "${CURSOR_SETUP_HTML_QUIET:-0}" == "1" ]] || printf '%s\n' "$out"
}

status_dashboard_open_html() {
  local f
  f="$(status_dashboard_write_html "${1:-}")" || return 1
  if is_dry_run; then
    log_info "[dry-run] open $f"
  else
    open "$f"
  fi
  printf '%s\n' "$f"
}

# --- scripts/lib/dashboard_flow.sh.sh ---
# 브라우저 대시보드(127.0.0.1) — 클릭 시 터미널에서 이어 실행

dashboard_write_allowlist_file() {
  local dest="$1"
  discover_workspace_paths > "$dest"
}

# 임시 파일에 내장 Python 대시보드 서버 기록 후 경로 출력
_dashboard_server_write_py() {
  local out="$1"
  python3 <<'PY' > "$out"
import textwrap, sys
code = r'''
import os, subprocess, urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
import shlex

class H(BaseHTTPRequestHandler):
    server_version = "CursorSetupDash/1.0"

    def log_message(self, fmt, *args):
        pass

    def _run_term(self, script_body, auto_close=False):
        if auto_close:
            script_body = script_body + "; exit"
        wrapped = "bash -lc " + shlex.quote(script_body)
        def aq(s):
            return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
        scpt = "tell application \"Terminal\" to do script " + aq(wrapped)
        subprocess.run(["osascript", "-e", scpt], check=False)

    def _regen(self):
        setup = os.environ["CURSOR_SETUP_SCRIPT"]
        htm = os.environ["CURSOR_DASH_HTML"]
        subprocess.run([setup, "--_cursor-setup-write-dash", htm], check=False)

    def _allow_ok(self, path):
        path = os.path.realpath(path)
        if not path or not os.path.isdir(path):
            return False
        al = os.environ.get("CURSOR_DASH_ALLOWLIST", "")
        if not al or not os.path.isfile(al):
            return False
        with open(al, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    if os.path.realpath(line) == path:
                        return True
                except OSError:
                    continue
        return False

    def _html_ok(self):
        b = (
            "<!DOCTYPE html><html lang=\"ko\"><meta charset=\"utf-8\">"
            "<body style=\"font-family:system-ui;background:#0d1117;color:#e6edf3;padding:24px\">"
            "<p>터미널 창이 열렸습니다. 질문은 거기서 이어서 답해 주세요.</p>"
            "<p><a href=\"/\" style=\"color:#2f81f7\">대시보드로</a></p></body></html>"
        )
        return b.encode("utf-8")

    def _html_denied(self):
        b = (
            "<!DOCTYPE html><html lang=\"ko\"><meta charset=\"utf-8\">"
            "<body style=\"font-family:system-ui;background:#0d1117;color:#e6edf3;padding:24px\">"
            "<p>허용되지 않은 경로입니다.</p>"
            "<p><a href=\"/\" style=\"color:#2f81f7\">대시보드로</a></p></body></html>"
        )
        return b.encode("utf-8")

    def do_GET(self):
        p = self.path.split("?", 1)[0]
        if p == "/refresh":
            self._regen()
            self.send_response(302)
            self.send_header("Location", "/")
            self.end_headers()
            return
        if p in ("/", "/index.html"):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            with open(os.environ["CURSOR_DASH_HTML"], "rb") as fp:
                self.wfile.write(fp.read())
            return
        self.send_error(404)

    def do_POST(self):
        root = os.environ["CURSOR_SETUP_ROOT"]
        setup = os.environ["CURSOR_SETUP_SCRIPT"]
        p = self.path
        if p == "/configure":
            allow_path = os.environ.get("CURSOR_DASH_ALLOWLIST", "")
            if allow_path:
                subprocess.run(
                    [setup, "--_cursor-setup-write-allowlist", allow_path],
                    check=False,
                )
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8", errors="replace")
            q = urllib.parse.parse_qs(body)
            raw = (q.get("path") or [""])[0].strip()
            if not self._allow_ok(raw):
                self.send_response(403)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(self._html_denied())
                return
            inner = "cd {} && /bin/bash {} --workspace {}".format(
                shlex.quote(root), shlex.quote(setup), shlex.quote(raw)
            )
            self._run_term(inner, auto_close=False)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            return
        if p == "/full-wizard":
            inner = "cd {} && /bin/bash {} --full-wizard".format(shlex.quote(root), shlex.quote(setup))
            self._run_term(inner, auto_close=False)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            return
        if p == "/tunnel":
            inner = "cd {} && /bin/bash {} --tunnel-only".format(shlex.quote(root), shlex.quote(setup))
            self._run_term(inner, auto_close=False)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            return
        if p.startswith("/action/"):
            uid = os.getuid()
            ag = os.path.expanduser("~/.local/bin/agent")
            agq = shlex.quote(ag)
            act = {
                "/action/gh-login": (
                    "echo ''; echo 'GitHub: 브라우저에서 로그인을 마치면 이 탭이 닫히고 대시보드를 새로고침하세요.'; "
                    "gh auth login --web --git-protocol https --hostname github.com"
                ),
                "/action/agent-install": "curl -fsSL https://cursor.com/install | bash",
                "/action/agent-login": "test -x {} && {} login || echo 'agent 없음 — 위에서 CLI 설치를 먼저 누르세요'".format(
                    agq, agq
                ),
                "/action/open-github": "open https://github.com",
                "/action/open-cursor-docs": "open https://cursor.com/docs",
                "/action/worker-kickstart": "launchctl kickstart -k gui/{}/com.cursor.agent.worker 2>/dev/null || true".format(
                    uid
                ),
            }
            auto_close = {
                "/action/gh-login": True,
                "/action/agent-install": True,
                "/action/agent-login": True,
                "/action/open-github": True,
                "/action/open-cursor-docs": True,
                "/action/worker-kickstart": True,
            }
            inner = act.get(p)
            if inner:
                self._run_term(inner, auto_close=auto_close.get(p, False))
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(self._html_ok())
                return
        self.send_error(404)


def main():
    port = int(os.environ["CURSOR_DASH_PORT"])
    host = "127.0.0.1"
    httpd = HTTPServer((host, port), H)
    print("[정보] 대시보드 http://{}:{}/ (종료: Ctrl+C)".format(host, port), flush=True)
    httpd.serve_forever()

if __name__ == "__main__":
    main()
'''
sys.stdout.write(textwrap.dedent(code))
PY
}

dashboard_server_main_blocking() {
  local root="${CURSOR_SETUP_ROOT:-$ROOT}"
  local port html allow py preferred
  if ! command_exists python3; then
    log_err "대시보드 서버에 python3 가 필요합니다."
    return 1
  fi
  preferred="${CURSOR_DASH_PORT:-58741}"
  if python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', int('$preferred'))); s.close()" 2>/dev/null; then
    port="$preferred"
  else
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    log_info "기본 포트 ${preferred} 사용 중 — 임시 포트 ${port} 로 뜹니다 (즐겨찾기는 포트마다 따로 저장됩니다)."
  fi
  html="$(mktemp).html"
  allow="$(mktemp)"
  py="$(mktemp).py"
  dashboard_write_allowlist_file "$allow"
  local setup_cmd="$root/setup"
  [[ -f "$setup_cmd" ]] || setup_cmd="$root/MacMini-Cursor-Setup.command"
  export CURSOR_SETUP_EXEC_HINT="$setup_cmd"
  "$setup_cmd" --_cursor-setup-write-dash "$html" || {
    log_err "대시보드 HTML 생성 실패"
    rm -f "$allow" "$py"
    return 1
  }
  _dashboard_server_write_py "$py"
  chmod +x "$py" 2>/dev/null || true

  export CURSOR_DASH_PORT="$port"
  export CURSOR_DASH_HTML="$html"
  export CURSOR_DASH_ALLOWLIST="$allow"
  export CURSOR_SETUP_SCRIPT="$setup_cmd"
  export CURSOR_SETUP_ROOT="$root"

  _dashboard_cleanup() {
    rm -f "$html" "$allow" "$py" 2>/dev/null || true
  }
  trap '_dashboard_cleanup' EXIT INT TERM

  ( sleep 0.35 && open "http://127.0.0.1:${port}/" ) &
  python3 "$py"
}

# --- scripts/lib/gui.sh.sh ---
# macOS 그래픽 안내 (osascript)

CURSOR_SETUP_GUI="${CURSOR_SETUP_GUI:-0}"

gui_mode_enabled() {
  [[ "${CURSOR_SETUP_GUI:-0}" == "1" ]] && is_macos && command_exists osascript
}

_gui_write_msg() {
  printf '%s' "$1" > "$2"
}

_gui_as_escape() {
  printf '%s' "$1" | sed "s/\\\\/\\\\\\\\/g; s/\"/\\\\\"/g" | tr '\n' ' '
}

gui_alert_info() {
  local title="$1"
  local body="$2"
  local tf bf
  tf="$(mktemp /tmp/cs_gui_t.XXXXXX)"
  bf="$(mktemp /tmp/cs_gui_b.XXXXXX)"
  _gui_write_msg "$title" "$tf"
  _gui_write_msg "$body" "$bf"
  local ts bs
  ts=$(_gui_as_escape "$(cat "$tf")")
  bs=$(_gui_as_escape "$(cat "$bf")")
  rm -f "$tf" "$bf"
  osascript -e "display alert \"$ts\" message \"$bs\" as informational buttons {\"확인\"} default button \"확인\"" 2>/dev/null || true
}

# 브라우저 HTML 대시보드 연 뒤, 짧은 버튼 창
gui_show_startup_dashboard() {
  local wd="${1:-$HOME/Dev/AutoCRF}"
  if declare -F status_dashboard_open_html >/dev/null 2>&1; then
    status_dashboard_open_html >/dev/null 2>&1 || log_warn "HTML 대시보드를 열지 못했어요 (python3 확인)."
  fi

  local out ec
  out=$(osascript -e 'display dialog "브라우저에 상태 대시보드를 열었어요. (저장소마다 카드가 나뉩니다)" with title "맥미니 셋업" buttons {"종료", "터미널 로그", "설정"} default button "설정" with icon note' 2>/dev/null) || true
  ec=$?
  if [[ $ec -ne 0 ]] || [[ -z "$out" ]]; then
    printf '\n'
    return 1
  fi
  printf '%s\n' "$out"
  return 0
}

gui_pick_graphic_mode() {
  local body="이제부터 질문을 어떻게 보여줄까요?

그림(창) / 글자만(터미널)"
  local b
  b=$(_gui_as_escape "$body")
  local out
  out=$(osascript -e "display dialog \"$b\" with title \"맥미니 셋업\" buttons {\"글자만\", \"그림(창)\"} default button \"그림(창)\" with icon note" 2>/dev/null) || true
  case "$out" in
    *"그림"*) return 0 ;;
    *) return 1 ;;
  esac
}

gui_yes_no_dialog() {
  local msg="$1"
  local def="${2:-n}"
  local mf
  mf="$(mktemp /tmp/cs_gui_m.XXXXXX)"
  _gui_write_msg "$msg" "$mf"
  local m
  m=$(_gui_as_escape "$(cat "$mf")")
  rm -f "$mf"
  local out
  if [[ "$def" == "y" || "$def" == "Y" ]]; then
    out=$(osascript -e "display dialog \"$m\" with title \"질문\" buttons {\"아니요\", \"네\"} default button \"네\" with icon note" 2>/dev/null) || true
  else
    out=$(osascript -e "display dialog \"$m\" with title \"질문\" buttons {\"아니요\", \"네\"} default button \"아니요\" with icon note" 2>/dev/null) || true
  fi
  case "$out" in
    *"네"*) return 0 ;;
    *) return 1 ;;
  esac
}

gui_text_dialog() {
  local msg="$1"
  local def="$2"
  local mf
  mf="$(mktemp /tmp/cs_gui_m.XXXXXX)"
  _gui_write_msg "$msg" "$mf"
  local m d
  m=$(_gui_as_escape "$(cat "$mf")")
  d=$(_gui_as_escape "$def")
  rm -f "$mf"
  local out
  out=$(osascript \
    -e "set defaultAns to \"$d\"" \
    -e "set r to display dialog \"$m\" default answer defaultAns with title \"입력\" buttons {\"취소\", \"확인\"} default button \"확인\" with icon note" \
    -e 'if button returned of r is "취소" then return defaultAns' \
    -e 'return text returned of r' 2>/dev/null) || out="$def"
  printf '%s\n' "$out"
}

gui_after_parse_choose_mode() {
  # UI는 브라우저 대시보드(로컬 서버)로 통일. 연속 osascript 마법사는 쓰지 않습니다.
  return 0
}

gui_finish_celebrate() {
  gui_mode_enabled || return 0
  gui_alert_info "끝" "아래 터미널 요약과 브라우저 대시보드를 참고하세요."
}

# --- scripts/lib/preflight.sh.sh ---
# Preflight: macOS, git, Homebrew, 선택적 gh / cloudflared

preflight_main() {
  log_info "[1/5] 준비"

  if ! command_exists git; then
    log_err "git 없음 → 터미널에 입력: xcode-select --install"
    exit 1
  fi

  if ! command_exists brew; then
    log_warn "Homebrew 없음 (gh, cloudflared 설치에 필요)"
    if prompt_yn "brew.sh 안내 페이지를 열까요?" "y"; then
      run_cmd open "https://brew.sh"
    fi
    log_err "brew 설치 후 이 스크립트를 다시 실행하세요."
    exit 1
  fi

  if ! command_exists gh; then
    log_info "gh 설치 중…"
    run_cmd brew install gh
  else
    log_info "gh: 이미 설치됨"
  fi

  local want_cf=0
  if [[ "${CURSOR_SETUP_DASHBOARD_CF_LOCKED:-0}" == "1" ]]; then
    [[ "${CURSOR_SETUP_WITH_CF:-}" == "1" ]] && want_cf=1 || want_cf=0
  elif [[ "$CURSOR_SETUP_WITH_CF" == "1" ]]; then
    want_cf=1
  elif [[ "$CURSOR_SETUP_WITH_CF" == "0" ]]; then
    want_cf=0
  else
    if cloudflared_cert_ok && [[ -f "$HOME/.cloudflared/config.yml" ]]; then
      log_info "Cloudflare: 설정 있음 → Tunnel 단계 생략"
      want_cf=0
    elif prompt_yn "Cloudflare Tunnel(도메인)도 할까요?" "n"; then
      want_cf=1
    fi
  fi
  export CURSOR_SETUP_WITH_CF="$want_cf"

  if [[ "$want_cf" == "1" ]] && ! command_exists cloudflared; then
    log_info "cloudflared 설치 중…"
    run_cmd brew install cloudflared
  elif [[ "$want_cf" == "1" ]]; then
    log_info "cloudflared: 이미 설치됨"
  fi
}

# --- scripts/lib/github.sh.sh ---
# Git 초기화, gh 인증, 원격 생성 및 push

github_main() {
  log_info "[2/5] Git · GitHub"

  local default_work="$HOME/Dev/AutoCRF"
  if [[ "${CURSOR_SETUP_WORKSPACE_LOCKED:-0}" == "1" && -n "${CURSOR_SETUP_WORK_DIR:-}" ]]; then
    CURSOR_SETUP_WORK_DIR="$(expand_tilde "$CURSOR_SETUP_WORK_DIR")"
    export CURSOR_SETUP_WORK_DIR
    log_info "작업 폴더(고정): $CURSOR_SETUP_WORK_DIR"
  else
    local work_raw
    work_raw="$(prompt_with_default "작업 폴더 (여기서 Git 씀)" "$default_work")"
    CURSOR_SETUP_WORK_DIR="$(expand_tilde "$work_raw")"
    export CURSOR_SETUP_WORK_DIR
  fi

  ensure_dir "$CURSOR_SETUP_WORK_DIR"
  if ! is_dry_run; then
    cd "$CURSOR_SETUP_WORK_DIR"
  fi

  if is_dry_run; then
    log_info "[dry-run] cd $CURSOR_SETUP_WORK_DIR"
  fi

  if ! is_dry_run; then
    if [[ ! -d "$CURSOR_SETUP_WORK_DIR/.git" ]]; then
      run_cmd git init
      run_cmd git branch -M main
    fi
  else
    log_info "[dry-run] git init (필요 시)"
  fi

  if ! is_dry_run; then
    cd "$CURSOR_SETUP_WORK_DIR"
    if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
      if [[ -z "$(find . -maxdepth 1 -mindepth 1 ! -name '.git' 2>/dev/null | head -1)" ]]; then
        printf '%s\n' "# 기준 작업 폴더" > README.md
      fi
      run_cmd git add -A
      if ! git diff --cached --quiet 2>/dev/null; then
        run_cmd git commit -m "initial commit"
      else
        run_cmd git commit --allow-empty -m "initial commit"
      fi
    fi
  fi

  if ! is_dry_run; then
    if gh auth status -h github.com >/dev/null 2>&1; then
      log_info "GitHub: 로그인됨"
    else
      log_info "GitHub 웹 로그인: 브라우저가 열리면 github.com 에서 인증을 마치세요."
      run_cmd gh auth login --web --git-protocol https --hostname github.com || {
        log_err "gh auth login 실패"
        exit 1
      }
    fi
  else
    log_info "[dry-run] gh auth"
  fi

  local remote_url=""
  if ! is_dry_run; then
    cd "$CURSOR_SETUP_WORK_DIR"
    remote_url="$(git remote get-url origin 2>/dev/null || true)"
  fi

  if [[ -n "$remote_url" ]]; then
    log_info "origin 있음 → 저장소 만들기 생략"
    CURSOR_SETUP_REPO_NAME="$(basename "$remote_url" .git)"
    export CURSOR_SETUP_REPO_NAME
    if ! is_dry_run; then
      run_cmd git push -u origin main 2>/dev/null || log_warn "push 실패 시: git push -u origin main"
    fi
    return 0
  fi

  local default_repo
  default_repo="$(basename "$CURSOR_SETUP_WORK_DIR")"
  local repo_input
  repo_input="$(prompt_with_default "GitHub 저장소 이름" "$default_repo")"
  CURSOR_SETUP_REPO_NAME="$repo_input"
  export CURSOR_SETUP_REPO_NAME

  if ! is_dry_run; then
    cd "$CURSOR_SETUP_WORK_DIR"
    if prompt_yn "비공개 저장소 만들고 연결할까요?" "y"; then
      run_cmd gh repo create "$CURSOR_SETUP_REPO_NAME" --private --source=. --remote=origin --push
    else
      log_info "나중에: gh repo create 또는 git remote add origin …"
    fi
  else
    log_info "[dry-run] gh repo create $CURSOR_SETUP_REPO_NAME …"
  fi
}

# --- scripts/lib/cursor_agent.sh.sh ---
# Cursor CLI 설치, PATH, agent login, LaunchAgent

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
  ensure_dir "$log_dir"

  if [[ -z "$plist_src" ]] || [[ ! -f "$plist_src" ]]; then
    log_err "worker plist 템플릿 없음"
    [[ -n "$plist_tmp" ]] && rm -f "$plist_tmp"
    exit 1
  fi

  local old_wd=""
  [[ -f "$plist_dst" ]] && old_wd=$(plutil_string "$plist_dst" WorkingDirectory)

  sed -e "s|__AGENT_BIN__|$agent_bin|g" \
      -e "s|__WORK_DIR__|$work_dir|g" \
      -e "s|__LOG_OUT__|$log_dir/agent-worker.log|g" \
      -e "s|__LOG_ERR__|$log_dir/agent-worker.err.log|g" \
      "$plist_src" > "$plist_dst"
  [[ -n "$plist_tmp" ]] && rm -f "$plist_tmp"
  log_info "LaunchAgent plist 저장됨"

  if [[ "$old_wd" == "$work_dir" ]] && [[ -n "$old_wd" ]] && launchagent_running "com.cursor.agent.worker"; then
    log_info "워커: 이미 이 폴더로 실행 중"
    return 0
  fi

  if [[ "$old_wd" == "$work_dir" ]] && [[ -n "$old_wd" ]]; then
    log_info "워커: 같은 폴더로 재기동"
    launchctl bootout "gui/$(id -u)/com.cursor.agent.worker" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist_dst"
    launchctl kickstart -k "gui/$(id -u)/com.cursor.agent.worker" 2>/dev/null || true
    return 0
  fi

  if [[ "${CURSOR_SETUP_WORKSPACE_LOCKED:-0}" == "1" ]] || prompt_yn "워커 자동 실행(재부팅 후에도) 등록할까요?" "y"; then
    launchctl bootout "gui/$(id -u)/com.cursor.agent.worker" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist_dst"
    launchctl kickstart -k "gui/$(id -u)/com.cursor.agent.worker" 2>/dev/null || true
  else
    printf '%s\n' "  cd $(printf '%q' "$work_dir") && $agent_bin worker start"
  fi
}

# --- scripts/lib/cloudflare_tunnel.sh.sh ---
# Cloudflare Tunnel (선택)

cloudflare_tunnel_main() {
  local work_dir="${1:-}"

  if [[ "${CURSOR_SETUP_WITH_CF:-0}" != "1" ]]; then
    return 0
  fi

  log_info "[4/5] Cloudflare Tunnel"

  if ! command_exists cloudflared; then
    log_warn "cloudflared 없음 — brew install cloudflared 후 다시 실행"
    return 0
  fi

  if is_dry_run; then
    log_info "[dry-run] cloudflared …"
    return 0
  fi

  if [[ "${CURSOR_SETUP_CF_FORCE:-0}" != "1" ]] && cloudflared_cert_ok && [[ -f "$HOME/.cloudflared/config.yml" ]]; then
    log_info "Tunnel 설정 있음 → 이 단계 생략 (--with-cloudflare 로 다시 설정 가능)"
    return 0
  fi

  if cloudflared_cert_ok; then
    log_info "Cloudflare: cert 있음 → login 생략"
  else
    if prompt_yn "Cloudflare 로그인(브라우저) 할까요?" "y"; then
      cloudflared tunnel login || {
        log_err "tunnel login 실패"
        return 1
      }
    else
      log_warn "login 없으면 터널을 못 만듦"
      return 0
    fi
  fi

  local tunnel_name
  tunnel_name="$(prompt_with_default "터널 이름" "autocrf-mini")"

  local create_out
  create_out="$(cloudflared tunnel create "$tunnel_name" 2>&1)" || true
  printf '%s\n' "$create_out"

  local tunnel_id
  tunnel_id="$(printf '%s\n' "$create_out" | sed -nE 's/.*id ([0-9a-fA-F-]{36}).*/\1/p' | head -1)"
  if [[ -z "$tunnel_id" ]]; then
    tunnel_id="$(cloudflared tunnel list 2>/dev/null | awk -v n="$tunnel_name" 'NF>=2 && $2==n && $1 ~ /^[0-9a-fA-F-]{36}$/ {print $1; exit}')"
  fi
  if [[ -z "$tunnel_id" ]] && command_exists cloudflared; then
    local info_out
    info_out="$(cloudflared tunnel info "$tunnel_name" 2>/dev/null || true)"
    tunnel_id="$(printf '%s\n' "$info_out" | sed -nE 's/.*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}).*/\1/p' | head -1)"
  fi
  if [[ -z "$tunnel_id" ]]; then
    log_err "터널 ID 확인 실패 — cloudflared tunnel list"
    return 1
  fi

  local cred_file="$HOME/.cloudflared/${tunnel_id}.json"
  if [[ ! -f "$cred_file" ]]; then
    log_warn "자격 파일 경로 확인: $cred_file"
  fi

  local hostname
  hostname="$(prompt_with_default "공개 도메인 (예: app.example.com)" "app.example.com")"

  if prompt_yn "DNS 자동 연결할까요? (Cloudflare에 도메인 있을 때)" "y"; then
    cloudflared tunnel route dns "$tunnel_name" "$hostname" || log_warn "route dns 실패 — 웹에서 수동 가능"
  fi

  local port
  port="$(prompt_with_default "맥에서 받을 포트 (로컬)" "8080")"

  local cf_dir="$HOME/.cloudflared"
  ensure_dir "$cf_dir"
  local cfg="$cf_dir/config.yml"
  if [[ -f "$cfg" ]]; then
    cp "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)"
    log_info "기존 config.yml 백업함"
  fi

  local svc="http://127.0.0.1:${port}"
  {
    printf '%s\n' "tunnel: $tunnel_id"
    printf '%s\n' "credentials-file: $cred_file"
    printf '%s\n' "ingress:"
    printf '%s\n' "  - hostname: $hostname"
    printf '%s\n' "    service: $svc"
    printf '%s\n' "  - service: http_status:404"
  } > "$cfg"

  log_info "설정: $cfg"
  log_info "테스트: cloudflared tunnel --config $(printf '%q' "$cfg") run $(printf '%q' "$tunnel_name")"

  if prompt_yn "Tunnel도 재부팅 후 자동 실행할까요?" "y"; then
    cloudflare_write_tunnel_plist "$tunnel_name" "$cfg"
  fi
}

cloudflare_write_tunnel_plist() {
  local tunnel_name="$1"
  local cfg="$2"
  local plist_dst="$HOME/Library/LaunchAgents/com.cloudflared.tunnel.plist"
  local log_dir="$HOME/Library/Logs/CloudflaredTunnel"
  ensure_dir "$log_dir"

  local cloudflared_bin
  cloudflared_bin="$(command -v cloudflared)"

  cat > "$plist_dst" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.cloudflared.tunnel</string>
	<key>ProgramArguments</key>
	<array>
		<string>${cloudflared_bin}</string>
		<string>tunnel</string>
		<string>--config</string>
		<string>${cfg}</string>
		<string>run</string>
		<string>${tunnel_name}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>${log_dir}/tunnel.log</string>
	<key>StandardErrorPath</key>
	<string>${log_dir}/tunnel.err.log</string>
</dict>
</plist>
EOF

  launchctl bootout "gui/$(id -u)/com.cloudflared.tunnel" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist_dst"
  launchctl kickstart -k "gui/$(id -u)/com.cloudflared.tunnel" 2>/dev/null || true
  log_info "Tunnel LaunchAgent 등록"
}

# 대시보드에서 "Tunnel만" 터미널로 열 때
tunnel_only_main() {
  export CURSOR_SETUP_DASHBOARD_CF_LOCKED=1
  export CURSOR_SETUP_WITH_CF=1
  if [[ "${CURSOR_SETUP_CF_FORCE:-0}" != "1" ]]; then
    export CURSOR_SETUP_CF_FORCE=0
  fi
  log_info "Cloudflare Tunnel 단계만 진행합니다."
  preflight_main
  cloudflare_tunnel_main "${1:-$HOME/Dev/AutoCRF}"
}

# --- scripts/lib/summary.sh.sh ---
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

# --- scripts/lib/workspace_flow.sh.sh ---
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
  export CURSOR_SETUP_DASHBOARD_CF_LOCKED=1
  export CURSOR_SETUP_WITH_CF=0
  export CURSOR_SETUP_SKIP_FINISH_GUI=1

  log_info "선택한 폴더만 설정합니다: $wd"

  preflight_main
  github_main
  cursor_agent_main "$CURSOR_SETUP_WORK_DIR"
  summary_main "$CURSOR_SETUP_WORK_DIR" "${CURSOR_SETUP_REPO_NAME:-}"
}

cursor_agent_worker_plist_template() {
  cat <<'PLIST_TMPL_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.cursor.agent.worker</string>
	<key>ProgramArguments</key>
	<array>
		<string>__AGENT_BIN__</string>
		<string>worker</string>
		<string>start</string>
	</array>
	<key>WorkingDirectory</key>
	<string>__WORK_DIR__</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>__LOG_OUT__</string>
	<key>StandardErrorPath</key>
	<string>__LOG_ERR__</string>
</dict>
</plist>
PLIST_TMPL_EOF
}

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

usage() {
  cat <<'EOF'
맥미니 통합 셋업 (Cursor + GitHub + 선택 Cloudflare Tunnel)

실행 파일
  • 이 저장소를 쓸 때:  프로젝트 폴더의 ./setup
  • 배포용 한 파일:    dist/MacMini-Cursor-Setup.command (scripts/build-bundle.sh 로 생성 후 더블클릭)

사용법:
  ./setup [옵션]

기본:
  인수 없이 실행하면 브라우저 대시보드(로컬)만 뜹니다.
  폴더 카드에서 버튼을 누르면 터미널이 열리고, 그 폴더 기준으로 아직 안 된 설정만 이어갑니다.

옵션:
  --full-wizard       터미널에서 처음부터 전체 마법사 (구 방식)
  --workspace PATH    위와 동일 흐름을 터미널에서 바로 (대시보드 없이)
  --tunnel-only       Cloudflare Tunnel 단계만 터미널에서
  --interactive       질문을 하나씩 터미널에서 물어봄 (기본은 자동으로 기본값만 사용)
  --gui               전체 마법사 + 창(osa) 질문
  --cli               환영/대시보드 없이 터미널 전체 마법사
  --with-cloudflare   Tunnel 포함해 전체 마법사
  --skip-cloudflare   Tunnel 제외 전체 마법사
  --dry-run           명령만 보여 주기
  --status [폴더]     터미널에 상태만 (기본 ~/Dev/AutoCRF)
  --dashboard         기본과 동일 (로컬 대시보드 서버)
  -h, --help          도움말

단일 파일: scripts/build-bundle.sh → dist/MacMini-Cursor-Setup.command
EOF
}

CURSOR_SETUP_DRY_RUN=0
CURSOR_SETUP_RUN_MAIN=0
CURSOR_SETUP_WORKSPACE_PATH=""
CURSOR_SETUP_TUNNEL_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) CURSOR_SETUP_DRY_RUN=1; export CURSOR_SETUP_DRY_RUN; CURSOR_SETUP_RUN_MAIN=1; shift ;;
    --gui)
      export CURSOR_SETUP_GUI=1
      export CURSOR_SETUP_GUI_INTERACTIVE_CHOSEN=1
      CURSOR_SETUP_RUN_MAIN=1
      shift
      ;;
    --cli)
      export CURSOR_SETUP_CLI=1
      export CURSOR_SETUP_GUI=0
      export CURSOR_SETUP_GUI_INTERACTIVE_CHOSEN=1
      CURSOR_SETUP_RUN_MAIN=1
      shift
      ;;
    --interactive)
      export CURSOR_SETUP_FAST_PROMPTS=0
      shift
      ;;
    --full-wizard)
      CURSOR_SETUP_RUN_MAIN=1
      shift
      ;;
    --workspace)
      shift
      CURSOR_SETUP_WORKSPACE_PATH="${1:-}"
      if [[ -z "$CURSOR_SETUP_WORKSPACE_PATH" || "$CURSOR_SETUP_WORKSPACE_PATH" == -* ]]; then
        log_err "--workspace 다음에 폴더 경로가 필요합니다."
        exit 1
      fi
      shift
      CURSOR_SETUP_RUN_MAIN=1
      ;;
    --tunnel-only)
      CURSOR_SETUP_TUNNEL_ONLY=1
      CURSOR_SETUP_RUN_MAIN=1
      shift
      ;;
    --with-cloudflare)
      export CURSOR_SETUP_WITH_CF=1
      export CURSOR_SETUP_CF_FORCE=1
      export CURSOR_SETUP_CF_USER_PRESET=1
      CURSOR_SETUP_RUN_MAIN=1
      shift
      ;;
    --skip-cloudflare)
      export CURSOR_SETUP_WITH_CF=0
      export CURSOR_SETUP_CF_USER_PRESET=1
      CURSOR_SETUP_RUN_MAIN=1
      shift
      ;;
    --dashboard)
      shift
      ;;
    --status)
      shift
      _st_dir="${1:-}"
      if [[ -n "$_st_dir" && "$_st_dir" != -* ]]; then
        shift
      else
        _st_dir="$HOME/Dev/AutoCRF"
      fi
      status_dashboard_print "$(expand_tilde "$_st_dir")" ""
      unset _st_dir
      exit 0
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      log_err "알 수 없는 옵션: $1"
      usage
      exit 1
      ;;
  esac
done

: "${CURSOR_SETUP_FAST_PROMPTS:=1}"
export CURSOR_SETUP_FAST_PROMPTS

if [[ -n "$CURSOR_SETUP_WORKSPACE_PATH" ]]; then
  gui_after_parse_choose_mode
  if ! is_macos; then
    log_err "macOS 전용"
    exit 1
  fi
  workspace_setup_main "$CURSOR_SETUP_WORKSPACE_PATH"
  exit 0
fi

if [[ "$CURSOR_SETUP_TUNNEL_ONLY" == "1" ]]; then
  gui_after_parse_choose_mode
  if ! is_macos; then
    log_err "macOS 전용"
    exit 1
  fi
  tunnel_only_main
  exit 0
fi

if [[ "$CURSOR_SETUP_RUN_MAIN" == "1" ]]; then
  gui_after_parse_choose_mode

  main() {
    if ! is_macos; then
      log_err "macOS 전용"
      exit 1
    fi

    preflight_main

    github_main

    cursor_agent_main "$CURSOR_SETUP_WORK_DIR"

    cloudflare_tunnel_main "$CURSOR_SETUP_WORK_DIR"

    summary_main "$CURSOR_SETUP_WORK_DIR" "$CURSOR_SETUP_REPO_NAME"
  }

  main "$@"
  exit 0
fi

# 기본: 로컬 HTTP 대시보드만 (osascript 연속 창 없음)
if ! is_macos; then
  log_err "macOS 전용"
  exit 1
fi
if ! command_exists python3; then
  log_err "기본 대시보드에 python3 가 필요합니다. 설치 후 다시 실행하거나 ./setup --full-wizard 를 쓰세요."
  exit 1
fi
gui_after_parse_choose_mode
dashboard_server_main_blocking
exit 0
