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

def strip_inline_comment(s: str) -> str:
    in_single = False
    in_double = False
    out = []
    for ch in s:
        if ch == "'" and not in_double:
            in_single = not in_single
            out.append(ch)
            continue
        if ch == '"' and not in_single:
            in_double = not in_double
            out.append(ch)
            continue
        if ch == "#" and not in_single and not in_double:
            break
        out.append(ch)
    return "".join(out).strip()

def clean_scalar(v: str) -> str:
    v = strip_inline_comment(v).strip()
    if len(v) >= 2 and ((v[0] == v[-1] == '"') or (v[0] == v[-1] == "'")):
        v = v[1:-1].strip()
    return v

def add_kv(rule: dict, key: str, value: str) -> None:
    key = (key or "").strip().lower()
    if not key:
        return
    rule[key] = clean_scalar(value)

p = pathlib.Path(os.environ["CF_CFG"])
t = p.read_text(encoding="utf-8", errors="replace")
lines = t.splitlines()
in_ingress = False
rules = []
cur = None

for raw in lines:
    line = raw.rstrip()
    stripped = line.strip()
    if not in_ingress:
        if re.match(r"^ingress\s*:\s*$", stripped):
            in_ingress = True
        continue
    if not stripped:
        continue
    # ingress 섹션이 끝나면 중단 (다음 top-level key)
    if not line.startswith((" ", "\t", "-")) and re.match(r"^[A-Za-z0-9_-]+\s*:", stripped):
        break
    m_item = re.match(r"^\s*-\s*(.*)$", line)
    if m_item:
        if cur:
            rules.append(cur)
        cur = {}
        rest = m_item.group(1).strip()
        if rest:
            m_kv = re.match(r"^([A-Za-z0-9_-]+)\s*:\s*(.*)$", rest)
            if m_kv:
                add_kv(cur, m_kv.group(1), m_kv.group(2))
        continue
    if cur is None:
        continue
    m_kv = re.match(r"^\s+([A-Za-z0-9_-]+)\s*:\s*(.*)$", line)
    if m_kv:
        add_kv(cur, m_kv.group(1), m_kv.group(2))

if cur:
    rules.append(cur)

for r in rules:
    host = (r.get("hostname") or r.get("host") or "").strip()
    svc = (r.get("service") or "").strip()
    if not host or not svc:
        continue
    if "http_status" in svc:
        continue
    print(f"{host}\t{svc}")
PY
}

# ingress 의 service URL 에서 로컬 포트 추출 (sed 금지: 127.0.0.1 → 잘못된 "1" 방지)
cloudflare_service_local_port() {
  local svc="${1:-}"
  [[ -n "$svc" ]] || return 1
  local out
  out="$(
    CF_INGRESS_SVC="$svc" python3 <<'PY'
import os, urllib.parse

s = (os.environ.get("CF_INGRESS_SVC") or "").strip()
if not s or "://" not in s:
    raise SystemExit(1)
u = urllib.parse.urlparse(s)
port = u.port
if port is None:
    if u.scheme in ("http", "ws"):
        port = 80
    elif u.scheme in ("https", "wss"):
        port = 443
    else:
        raise SystemExit(1)
print(port, end="")
PY
  )" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

# config ingress 에 나온 로컬 포트들 (중복 제거, 쉼표 구분) — 안내용
cloudflare_config_ingress_local_ports_unique_csv() {
  local ports="" lp
  while IFS=$'\t' read -r _h s || [[ -n "$_h" ]]; do
    [[ -z "$_h" ]] && continue
    lp="$(cloudflare_service_local_port "$s" 2>/dev/null)" || continue
    [[ "$lp" =~ ^[0-9]+$ ]] || continue
    case ",$ports," in
      *",$lp,"*) ;;
      *) ports="${ports:+$ports,}$lp" ;;
    esac
  done < <(cloudflare_config_ingress_pairs)
  printf '%s' "$ports"
}

# stdout: 해당 포트로 연결된 hostname 한 줄씩 (중복 제거)
cloudflare_hostnames_for_port() {
  local want="${1:-}"
  want="${want// /}"
  [[ "$want" =~ ^[0-9]+$ ]] || return 0
  local h s lp seen=""
  while IFS=$'\t' read -r h s || [[ -n "$h" ]]; do
    [[ -z "$h" ]] && continue
    lp="$(cloudflare_service_local_port "$s" 2>/dev/null)" || continue
    [[ "$lp" == "$want" ]] || continue
    case "$seen" in
      *" ${h} "*) continue ;;
    esac
    printf '%s\n' "$h"
    seen="${seen} ${h} "
  done < <(cloudflare_config_ingress_pairs)
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

# --- scripts/lib/workspace_services.sh.sh ---
# 폴더별 실행 파일·명령 (~/.cursor-setup/workspace-services.jsonl) — exec(스크립트/ .command) 또는 shell + port

workspace_services_jsonl_path() {
  printf '%s\n' "${HOME}/.cursor-setup/workspace-services.jsonl"
}

# stdout: JSON 한 줄 {shell, port, disp, exec} — 탭/개행이 값에 있어도 깨지지 않음. jsonl 에 같은 path 가 여러 줄이면 마지막 줄이 우선.
workspace_service_config_line() {
  local abs="${1:-}"
  abs=$(cd "$abs" 2>/dev/null && pwd -P) || {
    printf '%s\n' '{"shell":"","port":"","disp":"","exec":""}'
    return 0
  }
  _WS_SVC_LOOKUP="$abs" python3 <<'PY'
import json, os, pathlib, shlex
p = pathlib.Path(os.environ["_WS_SVC_LOOKUP"]).resolve()
f = pathlib.Path.home() / ".cursor-setup" / "workspace-services.jsonl"
EMPTY = {"shell": "", "port": "", "disp": "", "exec": ""}


def _paths_match(ap, target):
    if ap == target:
        return True
    try:
        if ap.exists() and target.exists() and os.path.samefile(ap, target):
            return True
    except OSError:
        pass
    return os.path.normcase(str(ap)) == os.path.normcase(str(target))


def coerce_port(pv):
    if pv is None or isinstance(pv, bool):
        return None
    if isinstance(pv, (int, float)):
        try:
            n = int(pv)
        except (TypeError, ValueError):
            return None
        if isinstance(pv, float) and float(pv) != float(int(pv)):
            return None
        return n if 1 <= n <= 65535 else None
    s = str(pv).strip()
    if not s:
        return None
    try:
        n = int(float(s))
    except (ValueError, OverflowError):
        return None
    return n if 1 <= n <= 65535 else None


def port_from_obj(o):
    if not isinstance(o, dict):
        return ""
    for key in ("port", "devPort", "listen", "listenPort"):
        if key not in o:
            continue
        pn = coerce_port(o.get(key))
        if pn is not None:
            return str(pn)
    return ""


def _resolve_ep(ex):
    ep = pathlib.Path(ex).expanduser()
    try:
        return ep.resolve(strict=False)
    except TypeError:
        try:
            return ep.resolve()
        except OSError:
            pass
    except OSError:
        pass
    try:
        return pathlib.Path(os.path.realpath(ex))
    except OSError:
        return pathlib.Path(ex)


def effective_cmd_label_exec(o):
    sh = (o.get("shell") or "").strip().replace("\r", "").replace("\n", " ")
    ex = (o.get("exec") or "").strip().replace("\r", "")
    if ex:
        ep = _resolve_ep(ex)
        exec_abs = str(ep)
        cmd = "bash " + shlex.quote(exec_abs)
        disp = ep.name if ep.name else ex
        return cmd, disp, exec_abs
    if sh:
        label = sh if len(sh) <= 56 else sh[:56] + "…"
        return sh, label, ""
    return "", "", ""


if not f.is_file():
    print(json.dumps(EMPTY, ensure_ascii=False))
else:
    last = None
    for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            continue
        rawp = (o.get("path") or "").replace("\r", "").strip()
        ap = pathlib.Path(rawp).expanduser()
        try:
            try:
                ap = ap.resolve(strict=False)
            except TypeError:
                ap = ap.resolve()
        except OSError:
            ap = pathlib.Path(os.path.realpath(str(rawp)))
        if _paths_match(ap, p):
            last = o
    if last is None:
        print(json.dumps(EMPTY, ensure_ascii=False))
    else:
        cmd, disp, ex_abs = effective_cmd_label_exec(last)
        port_s = port_from_obj(last)
        print(
            json.dumps(
                {"shell": cmd, "port": port_s, "disp": disp, "exec": ex_abs},
                ensure_ascii=False,
            )
        )
PY
}

# 포트에 서버가 떠 있는지: LISTEN(lsof) 후 127.0.0.1 / ::1 연결 시도(nc)
workspace_service_port_listening() {
  local prt="${1:-}"
  [[ "$prt" =~ ^[0-9]+$ ]] || return 1
  lsof -nP -iTCP:"$prt" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  lsof -nP -iTCP:"$prt" 2>/dev/null | command grep -q LISTEN && return 0
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$prt" >/dev/null 2>&1 && return 0
    nc -z ::1 "$prt" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# stdin: discover_workspace_paths 와 동일한 한 줄당 한 경로 → LISTEN_JSON_OUT 에 JSON { "실경로": [포트,…], … }
# 주의: python heredoc 이 프로세스 stdin 을 쓰므로 파이프 내용은 임시 파일로 넘긴다.
workspace_listen_map_build() {
  local dest="${1:-}"
  [[ -n "$dest" ]] || return 1
  local _ws_paths
  _ws_paths=$(mktemp)
  cat > "$_ws_paths"
  LISTEN_JSON_OUT="$dest" WS_PATHS_FILE="$_ws_paths" python3 <<'PY'
import hashlib, json, os, subprocess, sys, time

def lsof_listen_rows():
    r = subprocess.run(
        ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"],
        capture_output=True,
        text=True,
        errors="replace",
        timeout=25,
    )
    if not (r.stdout or "").strip():
        return []
    # macOS 등에서 프로젝트와 무관한 LISTEN (미디어·시스템·GitHub Desktop 등)
    skip_cmd = frozenset(
        {
            "rapportd",
            "ControlCe",
            "ControlCenter",
            "GitHub",
        }
    )
    rows = []
    for line in r.stdout.strip().splitlines()[1:]:
        parts = line.split()
        if len(parts) < 4:
            continue
        if parts[0] in skip_cmd:
            continue
        try:
            pid = int(parts[1])
        except ValueError:
            continue
        if "(LISTEN)" not in parts:
            continue
        try:
            idx = parts.index("(LISTEN)")
        except ValueError:
            continue
        if idx < 1:
            continue
        addr = parts[idx - 1]
        if not addr or ":" not in addr:
            continue
        if "]:" in addr:
            port_s = addr.rsplit(":", 1)[-1].rstrip("]")
        else:
            port_s = addr.rsplit(":", 1)[-1]
        if not port_s.isdigit():
            continue
        rows.append((pid, int(port_s)))
    return rows


def get_pid_cwd(pid):
    r = subprocess.run(
        ["lsof", "-a", "-p", str(pid), "-d", "cwd"],
        capture_output=True,
        text=True,
        errors="replace",
        timeout=5,
    )
    if r.returncode != 0 or not (r.stdout or "").strip():
        return None
    lines = r.stdout.strip().splitlines()
    if len(lines) < 2:
        return None
    parts = lines[1].split()
    if len(parts) < 9:
        return None
    path = " ".join(parts[8:])
    try:
        return os.path.realpath(path)
    except OSError:
        return None


def get_pid_command(pid):
    for fmt in ("args=", "command="):
        r = subprocess.run(
            ["ps", "-p", str(pid), "-ww", "-o", fmt],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=4,
        )
        if r.returncode != 0:
            continue
        lines = [ln.strip() for ln in (r.stdout or "").splitlines() if ln.strip()]
        if not lines:
            continue
        if len(lines) >= 2 and lines[0].upper() in ("COMMAND", "ARGS"):
            lines = lines[1:]
        if lines:
            return " ".join(lines)
    return ""


def _home_dir_norm():
    try:
        return os.path.normcase(os.path.realpath(os.path.expanduser("~")).rstrip(os.sep))
    except OSError:
        return os.path.normcase(os.path.expanduser("~").rstrip(os.sep))


def cwd_matches_ws(cwd, ws, all_paths):
    if not cwd:
        return False
    sep = os.sep
    cw = os.path.normcase(cwd.rstrip(sep))
    try:
        w_abs = os.path.realpath(ws)
    except OSError:
        w_abs = ws
    wn = os.path.normcase(w_abs.rstrip(sep))
    home = _home_dir_norm()
    if cw == home and wn != home:
        return False
    if cw == wn:
        return True
    if cw.startswith(wn + sep):
        return True
    try:
        parent = os.path.normcase(os.path.dirname(w_abs.rstrip(sep)))
        if parent != cw:
            pass
        else:
            same_parent = []
            for p in all_paths:
                try:
                    pr = os.path.realpath(p)
                    pp = os.path.normcase(os.path.dirname(pr.rstrip(sep)))
                    if pp == parent:
                        same_parent.append(pr)
                except OSError:
                    continue
            if len(same_parent) == 1 and os.path.normcase(
                w_abs.rstrip(sep)
            ) == os.path.normcase(same_parent[0].rstrip(sep)):
                return True
    except (OSError, ValueError):
        pass
    return False


def load_ws_exec_hints(paths):
    hints = {p: set() for p in paths}
    jf = os.path.join(os.path.expanduser("~"), ".cursor-setup", "workspace-services.jsonl")
    if not os.path.isfile(jf):
        return hints
    with open(jf, encoding="utf-8", errors="replace") as fp:
        for line in fp:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            rawp = (o.get("path") or "").replace("\r", "").strip()
            if not rawp:
                continue
            try:
                ap = os.path.realpath(os.path.expanduser(rawp))
            except OSError:
                continue
            if ap not in hints:
                continue
            ex = (o.get("exec") or "").strip()
            if ex:
                hints[ap].add(os.path.basename(ex))
            sh = (o.get("shell") or "").replace("\r", "").strip()
            for tok in sh.replace("\t", " ").split():
                if tok.startswith("/") and os.sep in tok:
                    hints[ap].add(os.path.basename(tok))
    return hints


def cmdline_touches_any_hint(cmd, hint_set):
    if not cmd or not hint_set:
        return False
    cc = os.path.normcase(cmd)
    sep = os.sep
    for hint in hint_set:
        if not hint or len(hint) < 2:
            continue
        hc = os.path.normcase(hint)
        if hc not in cc:
            continue
        idx = 0
        while True:
            j = cc.find(hc, idx)
            if j < 0:
                break
            end = j + len(hc)
            before_ok = j == 0 or cc[j - 1] in (
                sep,
                " ",
                "\t",
                '"',
                "'",
                ":",
                "(",
                "[",
                "=",
            )
            after_ok = end >= len(cc) or cc[end] in (
                sep,
                " ",
                "\t",
                '"',
                "'",
                ":",
                ")",
                "]",
                ",",
                ";",
            )
            if before_ok and after_ok:
                return True
            idx = j + 1
    return False


_BORING_WS_BASENAMES = frozenset(
    {
        "dev",
        "src",
        "app",
        "web",
        "api",
        "lib",
        "doc",
        "test",
        "tmp",
        "temp",
        "core",
        "home",
        "user",
        "code",
        "work",
        "main",
        "empty",
    }
)


def _cmdline_excludes_ide_listener(cmd):
    c = (cmd or "").lower()
    return "cursor helper" in c or "extension-host" in c or "code helper" in c


def cmdline_touches_workspace_basename(cmd, ws):
    if not cmd or _cmdline_excludes_ide_listener(cmd):
        return False
    base = os.path.basename(ws.rstrip(os.sep))
    if len(base) < 5:
        return False
    if base.lower() in _BORING_WS_BASENAMES:
        return False
    w = base
    wc = os.path.normcase(w)
    cc = os.path.normcase(cmd)
    if wc not in cc:
        return False
    idx = 0
    sep = os.sep
    while True:
        i = cc.find(wc, idx)
        if i < 0:
            return False
        end = i + len(wc)
        if end >= len(cc) or cc[end] in (
            sep,
            " ",
            "\t",
            '"',
            "'",
            ":",
            ")",
            ",",
            ";",
            "[",
            "]",
        ):
            return True
        idx = i + 1


def cmdline_touches_workspace(cmd, ws):
    if not cmd or not ws or len(ws) < 4:
        return False
    w = ws.rstrip(os.sep)
    wc = os.path.normcase(w)
    cc = os.path.normcase(cmd)
    if wc not in cc:
        return False
    idx = 0
    sep = os.sep
    while True:
        i = cc.find(wc, idx)
        if i < 0:
            return False
        end = i + len(wc)
        if end >= len(cc) or cc[end] in (sep, " ", "\t", '"', "'", ":", ")", ",", ";"):
            return True
        idx = i + 1


def get_pid_open_realpaths(pid, max_lines=240):
    r = subprocess.run(
        ["lsof", "-p", str(pid)],
        capture_output=True,
        text=True,
        errors="replace",
        timeout=6,
    )
    if r.returncode != 0 or not (r.stdout or "").strip():
        return []
    out = []
    for line in (r.stdout or "").strip().splitlines()[1 : max_lines + 1]:
        parts = line.split()
        if len(parts) < 9:
            continue
        name = " ".join(parts[8:])
        if name.startswith("["):
            continue
        raw = name.split("->", 1)[0].strip()
        if not raw.startswith("/"):
            continue
        try:
            out.append(os.path.realpath(raw))
        except OSError:
            out.append(raw)
    return out


_lsof_paths_cache = {}


def get_cached_lsof_paths(pid):
    if pid not in _lsof_paths_cache:
        _lsof_paths_cache[pid] = get_pid_open_realpaths(pid)
    return _lsof_paths_cache[pid]


def open_paths_touch_workspace(paths, ws):
    """열린 파일 경로가 이 워크스페이스 디렉터리 아래에 있을 때만 (역방향 부모 매칭 제외)."""
    if not paths:
        return False
    wn = os.path.normcase(ws.rstrip(os.sep))
    wp = wn + os.sep
    for p in paths:
        try:
            pn = os.path.normcase(os.path.realpath(p))
        except OSError:
            pn = os.path.normcase(str(p))
        if pn == wn or pn.startswith(wp):
            return True
    return False


def pid_matches_workspace(pid, ws, cwd_by_pid, cmd_by_pid, all_paths, exec_hints):
    cwd = cwd_by_pid.get(pid)
    if cwd_matches_ws(cwd, ws, all_paths):
        return True
    cmd = cmd_by_pid.get(pid) or ""
    if cmdline_touches_any_hint(cmd, exec_hints.get(ws, ())):
        return True
    if cmdline_touches_workspace(cmd, ws):
        return True
    if cmdline_touches_workspace_basename(cmd, ws):
        return True
    return open_paths_touch_workspace(get_cached_lsof_paths(pid), ws)


def drop_ancestor_workspaces(hits):
    """중첩 경로가 같이 매칭되면 더 깊은(구체적인) 워크스페이스만 남긴다."""
    if len(hits) <= 1:
        return hits
    sep = os.sep
    hits = list(dict.fromkeys(hits))
    hits.sort(key=lambda x: -len(x))
    out = []
    for h in hits:
        hp = h.rstrip(sep) + sep
        if any(o.rstrip(sep).startswith(hp) for o in out):
            continue
        out.append(h)
    return out


paths = []
_ws_file = os.environ.get("WS_PATHS_FILE", "")
if _ws_file:
    with open(_ws_file, encoding="utf-8", errors="replace") as _fp:
        for line in _fp:
            line = line.strip()
            if not line:
                continue
            try:
                paths.append(os.path.realpath(line))
            except OSError:
                continue
else:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            paths.append(os.path.realpath(line))
        except OSError:
            continue
paths = list(dict.fromkeys(paths))


def _listen_cache_ttl():
    try:
        v = float(os.environ.get("CURSOR_DASH_LISTEN_CACHE_SEC", "2.5"))
    except (TypeError, ValueError):
        return 2.5
    return max(0.0, v)


def _listen_cache_key(ps):
    h = hashlib.sha256()
    for p in sorted(ps):
        h.update(p.encode("utf-8", errors="replace"))
        h.update(b"\0")
    h.update((os.environ.get("CURSOR_DASH_PORT") or "").encode("utf-8"))
    h.update(b"\0")
    h.update((os.environ.get("CURSOR_SETUP_ROOT") or "").encode("utf-8"))
    return h.hexdigest()


_listen_ttl = _listen_cache_ttl()
_outp_pre = os.environ.get("LISTEN_JSON_OUT", "")
if _outp_pre and _listen_ttl > 0 and paths:
    _ck = _listen_cache_key(paths)
    _cp = os.path.join(os.path.expanduser("~"), ".cursor-setup", ".dash-listen-cache.json")
    _now = time.time()
    try:
        if os.path.isfile(_cp):
            with open(_cp, encoding="utf-8") as _cfp:
                _cj = json.load(_cfp)
            if (
                isinstance(_cj, dict)
                and _cj.get("k") == _ck
                and isinstance(_cj.get("t"), (int, float))
                and _now - float(_cj["t"]) < _listen_ttl
                and isinstance(_cj.get("r"), dict)
            ):
                with open(_outp_pre, "w", encoding="utf-8") as _ofp:
                    json.dump(_cj["r"], _ofp, ensure_ascii=False)
                sys.exit(0)
    except Exception:
        pass

exec_hints = load_ws_exec_hints(paths)
listen = lsof_listen_rows()
pid_to_ports = {}
for pid, port in listen:
    pid_to_ports.setdefault(pid, set()).add(port)
cwd_by_pid = {}
cmd_by_pid = {}
for pid in list(pid_to_ports.keys()):
    cwd_by_pid[pid] = get_pid_cwd(pid)
    cmd_by_pid[pid] = get_pid_command(pid)
result = {p: [] for p in paths}
for pid, ports in pid_to_ports.items():
    hits = [
        ws
        for ws in paths
        if pid_matches_workspace(pid, ws, cwd_by_pid, cmd_by_pid, paths, exec_hints)
    ]
    hits = drop_ancestor_workspaces(hits)
    if len(hits) == 0:
        continue
    if len(hits) == 1:
        ws0 = hits[0]
        for pt in ports:
            result[ws0].append(pt)
        continue
    if len(hits) > 1:
        cwd = cwd_by_pid.get(pid)
        cmd = cmd_by_pid.get(pid) or ""
        ex = []
        if cwd:
            ncw = os.path.normcase(cwd.rstrip(os.sep))
            for ws in hits:
                if ncw == os.path.normcase(ws.rstrip(os.sep)):
                    ex.append(ws)
        if len(ex) == 1:
            ws0 = ex[0]
            for pt in ports:
                result[ws0].append(pt)
            continue
        cm = [ws for ws in hits if cmdline_touches_workspace(cmd, ws)]
        if len(cm) == 1:
            ws0 = cm[0]
            for pt in ports:
                result[ws0].append(pt)
            continue
# 대시보드 HTTP 포트는 프로젝트 dev 서버와 별개이므로 워크스페이스 LISTEN 목록에 넣지 않는다
# (넣으면 '실행 중'에 대시보드 포트가 같이 뜨고, 포트 끄기로 대시보드까지 죽일 위험이 있음)
for ws in paths:
    result[ws] = sorted(set(result[ws]))
outp = os.environ.get("LISTEN_JSON_OUT", "")
if outp:
    if _listen_ttl > 0 and paths:
        try:
            _cdir = os.path.join(os.path.expanduser("~"), ".cursor-setup")
            os.makedirs(_cdir, exist_ok=True)
            _cpw = os.path.join(_cdir, ".dash-listen-cache.json")
            with open(_cpw, "w", encoding="utf-8") as _cfp:
                json.dump(
                    {"k": _listen_cache_key(paths), "t": time.time(), "r": result},
                    _cfp,
                    ensure_ascii=False,
                )
        except Exception:
            pass
    with open(outp, "w", encoding="utf-8") as fp:
        json.dump(result, fp, ensure_ascii=False)
PY
  rm -f "$_ws_paths"
}

# CURSOR_DASH_LISTEN_MAP 파일 기준, 워크스페이스에 자동 감지된 LISTEN 포트(콤마)
workspace_listen_ports_csv() {
  local ws="$1"
  local mapf="${CURSOR_DASH_LISTEN_MAP:-}"
  [[ -f "$mapf" ]] || return 0
  local rp
  rp=$(cd "$ws" 2>/dev/null && pwd -P) || return 0
  MAPFILE="$mapf" RP="$rp" python3 -c "
import json, os
m = json.load(open(os.environ['MAPFILE'], encoding='utf-8'))
print(','.join(str(p) for p in m.get(os.environ['RP'], [])))
"
}

# --- scripts/lib/dashboard_html.sh.sh ---
# 브라우저 HTML 대시보드 (GitHub Desktop 스타일). status_report.sh 이후에 source.
# CURSOR_DASH_LANG=en|ko — 기본 en. 로컬 대시보드 서버가 쿠키(cursor_dash_lang)로 설정

dash_lang() { printf '%s' "${CURSOR_DASH_LANG:-en}"; }
is_dash_en() { [[ "$(dash_lang)" == "en" ]]; }
# $1 한국어 $2 English
_d() {
  if is_dash_en; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

html_escape() {
  printf '%s' "${1:-}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# macOS: 사이드바 LAN 주소 표시용 (en0 → en1 → en2)
dashboard_primary_ipv4() {
  local ifn ip
  for ifn in en0 en1 en2; do
    ip="$(ipconfig getifaddr "$ifn" 2>/dev/null)" || true
    [[ -n "$ip" ]] && printf '%s' "$ip" && return
  done
  printf ''
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
  cf_title="$(_d "Cloudflare Tunnel" "Cloudflare Tunnel")"
  if cloudflare_looks_connected; then
    cf_dot="ok"
    if cf_line=$(parse_cf_config_summary 2>/dev/null); then
      IFS=$'\t' read -r tid host svc <<<"$cf_line"
      cf_body="$(_d "구성됨" "Configured")"
      cf_extra="$(_d "도메인" "Domain") ${host:-?} → ${svc:-?}"
    else
      cf_body="$(_d "연결로 판단됨" "Connected (inferred)")"
      cf_extra="$(_d "config.yml 확인" "Check config.yml")"
    fi
    if cloudflare_tunnel_running; then
      cf_body="${cf_body} · $(_d "터널 동작 중" "tunnel running")"
    else
      cf_body="${cf_body} · $(_d "터널 프로세스 없음" "no tunnel process")"
    fi
  else
    cf_dot="bad"
    cf_body="$(_d "연결·설정 없음" "Not connected")"
    cf_extra="~/.cloudflared/config.yml · cert · credentials.json"
  fi
  _dashboard_card "$cf_dot" "$cf_title" "$cf_body" "$cf_extra"

  if github_cli_logged_in; then
    _dashboard_card "ok" "GitHub" "$(_d "로그인됨" "Signed in") ($(gh api user -q .login 2>/dev/null || echo "$(_d "계정" "account")"))" ""
  else
    _dashboard_card "bad" "GitHub" "$(_d "gh 로그인 필요" "gh sign-in required")" "$(_d "웹 브라우저로 로그인 (대시보드 버튼)" "Sign in via browser (dashboard buttons)")"
  fi

  if [[ -x "$HOME/.local/bin/agent" ]]; then
    _dashboard_card "ok" "Cursor Agent" "$(_d "CLI 설치됨" "CLI installed")" ""
  else
    _dashboard_card "warn" "Cursor Agent" "$(_d "CLI 미설치" "CLI not installed")" "~/.local/bin/agent"
  fi

  local _wr _wrun _wdot _wbody _wextra
  _wr=$(cursor_agent_worker_registered_count)
  _wrun=$(cursor_agent_worker_running_count)
  if [[ "$_wr" -gt 0 ]]; then
    if [[ "$_wrun" -eq "$_wr" ]]; then
      _wdot="ok"
      _wbody="$(_d "등록 ${_wr}개 모두 실행 중" "All ${_wr} registered workers running")"
    elif [[ "$_wrun" -gt 0 ]]; then
      _wdot="warn"
      _wbody="$(_d "등록 ${_wr}개 · 실행 ${_wrun}개" "${_wrun} of ${_wr} workers running")"
    else
      _wdot="warn"
      _wbody="$(_d "등록 ${_wr}개 · 모두 멈춤" "${_wr} registered · all stopped")"
    fi
    _wextra="$(_d "폴더마다 plist (재시작 시 전체 kickstart)" "One plist per folder · Restart kicks all")"
    _dashboard_card "$_wdot" "$(_d "Cursor 워커" "Cursor workers")" "$_wbody" "$_wextra"
  elif cursor_worker_process_running; then
    _dashboard_card "warn" "$(_d "Cursor 워커" "Cursor workers")" "$(_d "프로세스만 실행 중" "Process only")" "$(_d "LaunchAgent 없음" "No LaunchAgent")"
  else
    _dashboard_card "bad" "$(_d "Cursor 워커" "Cursor workers")" "$(_d "미등록" "Not registered")" "$(_d "프로젝트 카드에서 셋업" "Set up from a project card")"
  fi

  if [[ -f "$HOME/Library/LaunchAgents/com.cloudflared.tunnel.plist" ]]; then
    if launchagent_running "com.cloudflared.tunnel"; then
      _dashboard_card "ok" "$(_d "cloudflared 서비스" "cloudflared service")" "$(_d "Tunnel LaunchAgent 동작" "Tunnel LaunchAgent running")" ""
    else
      _dashboard_card "warn" "$(_d "cloudflared 서비스" "cloudflared service")" "$(_d "plist 등록 · 멈춤" "plist loaded · stopped")" ""
    fi
  elif cloudflared_process_running; then
    _dashboard_card "ok" "cloudflared" "$(_d "터널 프로세스 실행 중" "Tunnel process running")" ""
  else
    _dashboard_card "warn" "cloudflared" "$(_d "백그라운드 터널 없음" "No background tunnel")" ""
  fi
}

dashboard_workspace_rows_html() {
  local ws name origin br line worker_detail
  while IFS= read -r ws || [[ -n "$ws" ]]; do
    [[ -z "$ws" ]] && continue
    name=$(basename "$ws")
    if [[ -d "$ws/.git" ]]; then
      origin=$(cd "$ws" && git remote get-url origin 2>/dev/null || echo "$(_d "origin 없음" "no origin")")
      br=$(cd "$ws" && git branch --show-current 2>/dev/null || echo "?")
      line=$(git_one_line_status "$ws")
    else
      origin="$(_d "(Git 아님)" "(Not Git)")"
      br="-"
      line="-"
    fi
    worker_detail=$(worker_status_detail_for_workspace "$ws")
    printf '    <div class="repo">\n'
    printf '      <div class="repo-top"><span class="repo-name">%s</span></div>\n' "$(html_escape "$name")"
    printf '      <div class="repo-path mono">%s</div>\n' "$(html_escape "$ws")"
    printf '      <div class="repo-meta"><span><strong>%s</strong> %s</span></div>\n' "$(_d "브랜치" "Branch")" "$(html_escape "$br")"
    printf '      <div class="repo-meta mono">%s</div>\n' "$(html_escape "$origin")"
    printf '      <div class="repo-git mono">%s</div>\n' "$(html_escape "$line")"
    printf '      <div class="repo-worker">%s %s</div>\n' "$(_d "워커:" "Worker:")" "$(html_escape "$worker_detail")"
    printf '    </div>\n'
  done <<<"$(discover_workspace_paths)"
}

# 대시보드 서버용: 미완료 힌트 + 터미널로 이어가기 버튼
workspace_gap_hint_for_path() {
  local ws="$1"
  local hints="" sep=""
  if [[ ! -d "$ws" ]]; then
    printf '%s\n' "$(_d "폴더 없음" "Missing folder")"
    return 0
  fi
  if [[ ! -d "$ws/.git" ]]; then
    hints="$(_d "Git 초기화" "Git init")"
    sep=" · "
  fi
  if [[ -d "$ws/.git" ]] && ! (cd "$ws" && git remote get-url origin >/dev/null 2>&1); then
    hints="${hints}${sep}$(_d "GitHub 원격" "GitHub remote")"
    sep=" · "
  fi
  if ! github_cli_logged_in; then
    hints="${hints}${sep}$(_d "gh 로그인" "gh sign-in")"
    sep=" · "
  fi
  local pf lb
  if pf=$(cursor_agent_worker_plist_path_for_workspace "$ws" 2>/dev/null); then
    lb=$(plutil_string "$pf" Label)
    if ! launchagent_running "$lb"; then
      hints="${hints}${sep}$(_d "워커 기동" "Start worker")"
      sep=" · "
    fi
  else
    hints="${hints}${sep}$(_d "워커 등록" "Register worker")"
    sep=" · "
  fi
  if [[ -z "$hints" ]]; then
    printf '%s\n' "OK"
  else
    printf '%s\n' "${hints}"
  fi
}

dashboard_global_actions_html() {
  printf '    <div class="section-title section-muted">%s</div>\n' "$(_d "고급" "More")"
  printf '    <div class="action-row">\n'
  printf '      <form method="post" action="/tunnel"><button type="submit" class="btn btn-secondary">Tunnel</button></form>\n'
  printf '    </div>\n'
}

# 접힌 요약 줄: 항목마다 동그라미+라벨 (CURSOR_DASH_LANG 한 벌만)
dashboard_quick_check_summary_html() {
  local d_cf d_gh d_ag d_wk lb_cf lb_gh lb_ag lb_wk
  if cloudflare_looks_connected; then d_cf=ok; else d_cf=bad; fi
  if github_cli_logged_in; then d_gh=ok; else d_gh=bad; fi
  if [[ -x "$HOME/.local/bin/agent" ]]; then
    if cursor_agent_state_file_present; then d_ag=ok; else d_ag=warn; fi
  else
    d_ag=bad
  fi
  local _wreg _wrun
  _wreg=$(cursor_agent_worker_registered_count)
  _wrun=$(cursor_agent_worker_running_count)
  if [[ "$_wreg" -gt 0 ]]; then
    if [[ "$_wrun" -eq "$_wreg" ]]; then d_wk=ok; elif [[ "$_wrun" -gt 0 ]]; then d_wk=warn; else d_wk=warn; fi
  elif cursor_worker_process_running; then
    d_wk=warn
  else
    d_wk=bad
  fi
  lb_cf="$(_d "터널" "Tunnel")"
  lb_gh="GitHub"
  lb_ag="$(_d "Agent CLI" "Agent CLI")"
  lb_wk="$(_d "워커" "Worker")"
  printf '      <span class="qc-title">%s</span>\n' "$(_d "빠른 점검" "Quick check")"
  printf '      <span class="qc-pairs" role="list">\n'
  printf '        <span class="qc-pair" role="listitem"><span class="dot %s"></span><span class="qc-lbl">%s</span></span>\n' "$d_cf" "$(html_escape "$lb_cf")"
  printf '        <span class="qc-pair" role="listitem"><span class="dot %s"></span><span class="qc-lbl">%s</span></span>\n' "$d_gh" "$(html_escape "$lb_gh")"
  printf '        <span class="qc-pair" role="listitem"><span class="dot %s"></span><span class="qc-lbl">%s</span></span>\n' "$d_ag" "$(html_escape "$lb_ag")"
  printf '        <span class="qc-pair" role="listitem"><span class="dot %s"></span><span class="qc-lbl">%s</span></span>\n' "$d_wk" "$(html_escape "$lb_wk")"
  printf '      </span>\n'
  printf '      <span class="qc-chev" aria-hidden="true">▸</span>\n'
}

# $1 출력 파일 — KO/EN 각각 한 벌 (hidden 은 [data-dash-locale][hidden] 로만 숨김; flex 클래스가 hidden 을 덮어쓰지 않게 .qc-lang-block 사용)
_dashboard_quick_check_summary_write_file() {
  local dest="${1:?}"
  {
    printf '<div class="qc-lang-block" data-dash-locale="ko"'
    is_dash_en && printf ' hidden'
    printf '>\n'
    CURSOR_DASH_LANG=ko dashboard_quick_check_summary_html
    printf '</div>\n'
    printf '<div class="qc-lang-block" data-dash-locale="en"'
    is_dash_en || printf ' hidden'
    printf '>\n'
    CURSOR_DASH_LANG=en dashboard_quick_check_summary_html
    printf '</div>\n'
  } > "$dest"
}

# $1 setup 실행 파일 경로, $2 대시보드 포트(없으면 서버 끄기 단계 생략)
# CURSOR_DASH_LANG 에 따라 문구 선택
_dashboard_sidebar_locale_body_html() {
  local setup_ex="$1"
  local dash_port="${2:-}"
  local _sn=1 _setup_bn _db
  _setup_bn=$(basename "$setup_ex")
  _db="${CURSOR_DASH_BRAND:-$(_d "Cursor 셋업" "Cursor Setup")}"
  printf '<div class="brand">%s</div>\n' "$(html_escape "$_db")"
  printf '<p class="sidebar-tag">%s</p>\n' "$(_d "위에서 아래로 순서대로 하세요." "Follow the steps from top to bottom.")"
  printf '<div class="sidebar-steps">\n'
  printf '      <div class="step-card">\n'
  printf '        <div class="step-label"><span class="step-num">%s</span>%s</div>\n' "$_sn" "$(_d "개발·프로젝트 폴더" "Dev & project folders")"
  printf '        <p class="step-desc">%s</p>\n' "$(_d "Finder에서 작업할 폴더를 추가하세요." "Add the folders you work in via Finder.")"
  printf '        <form method="post" action="/workspace-add-folder" class="choice-form"><button type="submit" class="btn-choice"><span class="btn-choice-main"><span>%s</span><span class="btn-choice-sub">%s</span></span><span class="chev">›</span></button></form>\n' "$(_d "Finder에서 폴더 추가" "Add folder in Finder")" ""
  printf '        <details class="step-advanced">\n'
  printf '          <summary>%s</summary>\n' "$(_d "고급: 파일로 편집" "Advanced: edit config files")"
  printf '        <form method="post" action="/action/open-user-workspaces" class="choice-form"><button type="submit" class="btn-choice"><span class="btn-choice-main"><span>%s</span><span class="btn-choice-sub">%s</span></span><span class="chev">›</span></button></form>\n' "$(_d "폴더 목록 편집" "Edit folder list")" ""
  printf '        <form method="post" action="/action/open-user-services-jsonl" class="choice-form"><button type="submit" class="btn-choice"><span class="btn-choice-main"><span>%s</span><span class="btn-choice-sub">workspace-services.jsonl</span></span><span class="chev">›</span></button></form>\n' "$(_d "실행·포트" "Run / port")"
  printf '        <form method="post" action="/action/open-cloudflared-config" class="choice-form"><button type="submit" class="btn-choice"><span class="btn-choice-main"><span>%s</span><span class="btn-choice-sub">~/.cloudflared/config.yml</span></span><span class="chev">›</span></button></form>\n' "$(_d "Tunnel 설정" "Tunnel config")"
  printf '        </details>\n'
  printf '      </div>\n'
  _sn=$((_sn + 1))
  printf '      <div class="step-card">\n'
  printf '        <div class="step-label"><span class="step-num">%s</span>%s</div>\n' "$_sn" "$(_d "터널·GitHub·Agent" "Tunnel, GitHub, Agent")"
  printf '        <p class="step-desc">%s</p>\n' "$(_d "설치 마법사를 실행합니다. 이미 끝냈으면 건너뛰어도 됩니다." "Run the setup wizard. Skip if you already finished.")"
  printf '        <form method="post" action="/launch-setup" class="choice-form"><button type="submit" class="btn-choice"><span class="btn-choice-main"><span>%s</span><span class="btn-choice-sub mono">%s</span></span><span class="chev">›</span></button></form>\n' "$(_d "셋업 스크립트 실행" "Run setup script")" "$(html_escape "$_setup_bn")"
  printf '      </div>\n'
  _sn=$((_sn + 1))
  if [[ -n "$dash_port" ]]; then
    printf '      <div class="step-card">\n'
    printf '        <div class="step-label"><span class="step-num">%s</span>%s</div>\n' "$_sn" "$(_d "이 대시보드" "This dashboard")"
    printf '        <p class="step-desc">%s</p>\n' "$(_d "같은 주소로 다시 열 수 있습니다. 끝나면 서버를 꺼도 됩니다." "You can reopen this address anytime. Stop the server when you are done.")"
    printf '        <p style="margin:0 0 8px;font-size:12px"><a class="side-dash-url mono" href="http://127.0.0.1:%s/">127.0.0.1:%s</a></p>\n' "$(html_escape "$dash_port")" "$(html_escape "$dash_port")"
    if [[ "${CURSOR_DASH_HOST:-127.0.0.1}" == "0.0.0.0" || "${CURSOR_DASH_HOST:-}" == "::" ]]; then
      local _lip
      _lip="$(dashboard_primary_ipv4)"
      if [[ -n "$_lip" ]]; then
        printf '        <p style="margin:0 0 8px;font-size:12px"><a class="side-dash-url mono" href="http://%s:%s/">%s:%s</a> <span class="small">%s</span></p>\n' \
          "$(html_escape "$_lip")" "$(html_escape "$dash_port")" "$(html_escape "$_lip")" "$(html_escape "$dash_port")" \
          "$(_d "(LAN · 이 맥 IPv4)" "(LAN · this Mac IPv4)")"
      fi
    fi
    printf '        <form method="post" action="/dashboard-stop" class="choice-form"><button type="submit" class="btn-choice"><span class="btn-choice-main"><span>%s</span><span class="btn-choice-sub">%s</span></span><span class="chev">›</span></button></form>\n' "$(_d "대시보드 서버 끄기" "Stop dashboard server")" ""
    printf '      </div>\n'
  fi
  printf '</div>\n'
}

# 로컬 서버 대시보드: 카드마다 눌러서 터미널에서 이어가기
dashboard_global_cards_html_interactive() {
  local cf_line tid host svc cf_body gh_user agent_bin cf_dot h s ingress_data
  if cloudflare_looks_connected; then cf_dot="ok"; else cf_dot="bad"; fi
  printf '      <div class="card card-setup">\n'
  printf '        <div class="card-h"><span class="dot %s"></span>%s</div>\n' "$cf_dot" "$(_d "Cloudflare" "Cloudflare")"
  printf '        <p class="cf-hint-line">%s</p>\n' "$(_d "도메인·포트는 <strong>프로젝트</strong> 카드에서" "Match domain ↔ port in each <strong>project</strong> card")"
  if cloudflare_looks_connected; then
    if cloudflare_tunnel_running; then
      cf_body="$(_d "터널 동작 중" "Tunnel running")"
    else
      cf_body="$(_d "설정됨 · 터널 대기" "Ready · tunnel idle")"
    fi
    printf '        <p class="card-lead ok">%s</p>\n' "$(html_escape "$cf_body")"
    ingress_data=$(cloudflare_config_ingress_pairs)
    printf '        <ul class="cf-routes mono">\n'
    if [[ -z "$ingress_data" ]]; then
      if cf_line=$(parse_cf_config_summary 2>/dev/null); then
        IFS=$'\t' read -r tid host svc <<<"$cf_line"
        if [[ -n "$host" && "$host" != "?" ]]; then
          printf '            <li>%s → %s</li>\n' "$(html_escape "$host")" "$(html_escape "${svc:-?}")"
        else
          printf '            <li>—</li>\n'
        fi
      else
        printf '            <li>—</li>\n'
      fi
    else
      while IFS=$'\t' read -r h s || [[ -n "$h" ]]; do
        [[ -z "$h" ]] && continue
        [[ "$h" == \[* ]] && continue
        printf '            <li>%s → %s</li>\n' "$(html_escape "$h")" "$(html_escape "$s")"
      done <<<"$ingress_data"
    fi
    printf '        </ul>\n'
    printf '        <div class="card-actions">\n'
    printf '          <form method="post" action="/tunnel"><button type="submit" class="btn btn-secondary btn-small btn-pill">%s</button></form>\n' "$(_d "Tunnel 마법사" "Tunnel setup")"
    printf '        </div>\n'
  else
    printf '        <p class="card-lead bad">%s</p>\n' "$(_d "미설정" "Not set")"
    printf '        <form method="post" action="/tunnel"><button type="submit" class="btn btn-pill">%s</button></form>\n' "$(_d "Tunnel 마법사" "Tunnel setup")"
  fi
  printf '      </div>\n'

  printf '      <div class="card card-setup">\n'
  if github_cli_logged_in; then
    gh_user="$(gh api user -q .login 2>/dev/null || true)"
    printf '        <div class="card-h"><span class="dot ok"></span>GitHub</div>\n'
    printf '        <p class="card-lead ok">%s</p>\n' "$(html_escape "${gh_user:-$(_d "로그인됨" "Signed in")}")"
    printf '        <div class="card-actions card-actions-chips">\n'
    printf '          <form method="post" action="/action/open-github"><button type="submit" class="btn btn-secondary btn-small btn-pill">%s</button></form>\n' "$(_d "웹 열기" "Open web")"
    printf '          <form method="post" action="/action/gh-login"><button type="submit" class="btn btn-secondary btn-small btn-pill">%s</button></form>\n' "$(_d "다시 로그인" "Sign in again")"
    printf '        </div>\n'
  else
    printf '        <div class="card-h"><span class="dot bad"></span>GitHub</div>\n'
    printf '        <p class="card-lead bad">%s</p>\n' "$(_d "로그인 필요" "Sign in required")"
    printf '        <form method="post" action="/action/gh-login"><button type="submit" class="btn btn-pill">%s</button></form>\n' "$(_d "로그인" "Sign in")"
  fi
  printf '      </div>\n'

  agent_bin="$HOME/.local/bin/agent"
  printf '      <div class="card card-setup">\n'
  if [[ -x "$agent_bin" ]]; then
    if cursor_agent_state_file_present; then
      printf '        <div class="card-h"><span class="dot ok"></span>Agent CLI</div>\n'
      printf '        <p class="card-lead ok">%s</p>\n' "$(_d "설치됨" "Installed")"
      printf '        <div class="card-actions card-actions-chips">\n'
      printf '          <form method="post" action="/action/agent-login"><button type="submit" class="btn btn-secondary btn-small btn-pill">%s</button></form>\n' "$(_d "로그인" "Sign in")"
      printf '          <form method="post" action="/action/open-cursor-docs"><button type="submit" class="btn btn-secondary btn-small btn-pill">%s</button></form>\n' "$(_d "문서" "Docs")"
      printf '        </div>\n'
    else
      printf '        <div class="card-h"><span class="dot warn"></span>Agent CLI</div>\n'
      printf '        <p class="card-lead bad">%s</p>\n' "$(_d "로그인 필요" "Sign in required")"
      printf '        <form method="post" action="/action/agent-login"><button type="submit" class="btn btn-pill">%s</button></form>\n' "$(_d "로그인" "Sign in")"
    fi
  else
    printf '        <div class="card-h"><span class="dot bad"></span>Agent CLI</div>\n'
    printf '        <p class="card-lead bad">%s</p>\n' "$(_d "미설치" "Not installed")"
    printf '        <form method="post" action="/action/agent-install"><button type="submit" class="btn btn-pill">%s</button></form>\n' "$(_d "설치" "Install")"
  fi
  printf '      </div>\n'

  printf '      <div class="card card-setup">\n'
  local _wr _wrun _wdot
  _wr=$(cursor_agent_worker_registered_count)
  _wrun=$(cursor_agent_worker_running_count)
  if [[ "$_wr" -gt 0 ]]; then
    if [[ "$_wrun" -eq "$_wr" ]]; then _wdot="ok"; else _wdot="warn"; fi
    printf '        <div class="card-h"><span class="dot %s"></span>%s</div>\n' "$_wdot" "$(_d "워커" "Workers")"
    if [[ "$_wrun" -eq "$_wr" ]]; then
      printf '        <p class="card-lead ok">%s</p>\n' "$(_d "등록 ${_wr}개 모두 실행 중" "All ${_wr} registered running")"
    elif [[ "$_wrun" -gt 0 ]]; then
      printf '        <p class="card-lead bad">%s</p>\n' "$(_d "실행 ${_wrun}/${_wr}" "${_wrun}/${_wr} running")"
    else
      printf '        <p class="card-lead bad">%s</p>\n' "$(_d "등록 ${_wr}개 · 모두 중지" "${_wr} registered · all stopped")"
    fi
    printf '        <p class="card-sub">%s</p>\n' "$(_d "프로젝트마다 셋업 시 이 Mac에 plist가 추가됩니다." "Each project setup adds a plist on this Mac.")"
    printf '        <div class="card-actions">\n'
    printf '          <form method="post" action="/action/worker-kickstart"><button type="submit" class="btn btn-secondary btn-small btn-pill">%s</button></form>\n' "$(_d "전체 재시작" "Restart all")"
    printf '        </div>\n'
  elif cursor_worker_process_running; then
    printf '        <div class="card-h"><span class="dot warn"></span>%s</div>\n' "$(_d "워커" "Workers")"
    printf '        <p class="card-lead bad">%s</p>\n' "$(_d "프로세스만 실행" "Process only")"
    printf '        <p class="card-sub">%s</p>\n' "$(_d "프로젝트 카드에서 등록" "Register from a project card")"
  else
    printf '        <div class="card-h"><span class="dot bad"></span>%s</div>\n' "$(_d "워커" "Workers")"
    printf '        <p class="card-lead bad">%s</p>\n' "$(_d "미등록" "Not registered")"
    printf '        <p class="card-sub">%s</p>\n' "$(_d "프로젝트 카드에서 설정" "Set up from a project card")"
  fi
  printf '      </div>\n'
}

dashboard_global_actions_html_interactive() {
  printf '\n'
}

dashboard_workspace_rows_html_interactive() {
  local ws name origin br line worker_detail gap cur_gh suggest_gh _rnid
  local other_worker_path other_worker_bn _nreg
  _rnid=0
  while IFS= read -r ws || [[ -n "$ws" ]]; do
    [[ -z "$ws" ]] && continue
    name=$(basename "$ws")
    cur_gh=""
    suggest_gh=""
    if [[ -d "$ws/.git" ]]; then
      origin=$(cd "$ws" && git remote get-url origin 2>/dev/null || echo "$(_d "origin 없음" "no origin")")
      br=$(cd "$ws" && git branch --show-current 2>/dev/null || echo "?")
      line=$(git_one_line_status "$ws")
      cur_gh="$(github_repo_name_from_remote_url "$origin" 2>/dev/null)" || true
      suggest_gh="$(github_sanitize_repo_basename "$name")"
    else
      origin="$(_d "(Git 아님)" "(Not Git)")"
      br="-"
      line="-"
    fi
    worker_detail=$(worker_status_detail_for_workspace "$ws")
    gap=$(workspace_gap_hint_for_path "$ws")
    other_worker_path=""
    other_worker_bn=""
    if ! cursor_agent_worker_plist_path_for_workspace "$ws" >/dev/null 2>&1; then
      _nreg=$(cursor_agent_worker_registered_count)
      if [[ "$_nreg" -gt 0 ]]; then
        other_worker_path="$(_d "이 폴더 미등록" "No worker for this folder")"
        other_worker_bn="$(_d "다른 경로 ${_nreg}개에 워커 있음" "${_nreg} on other paths")"
      fi
    fi
    local svc_shell svc_port svc_on svc_disp svc_exec_path disabled_attr stop_disabled stop_title _wsvc_json port_inp_extra
    local auto_csv primary_auto stop_port running_ports_label open_disabled open_title
    local cf_show_ports _rest _tp _hn _anyh _pp _cf_hn_list _cf_ing_ports
    local stop_forms_ports _spf_rest _spf
    svc_shell=""
    svc_port=""
    svc_disp=""
    svc_exec_path=""
    svc_on=0
    port_inp_extra=""
    auto_csv=""
    primary_auto=""
    stop_port=""
    running_ports_label=""
    if declare -F workspace_service_config_line >/dev/null 2>&1; then
      _wsvc_json=$(workspace_service_config_line "$ws")
      if [[ -n "$_wsvc_json" ]]; then
        eval "$(printf '%s' "$_wsvc_json" | python3 -c "
import json, sys, shlex
d = json.load(sys.stdin)
print('svc_shell=' + shlex.quote(d.get('shell') or ''))
print('svc_port=' + shlex.quote(d.get('port') or ''))
print('svc_disp=' + shlex.quote(d.get('disp') or ''))
print('svc_exec_path=' + shlex.quote(d.get('exec') or ''))
")"
      fi
      [[ -n "$svc_exec_path" ]] && svc_exec_path="${svc_exec_path%/}"
      [[ -z "$svc_disp" && -n "$svc_shell" ]] && svc_disp="$svc_shell"
      [[ -z "$svc_disp" && -n "$svc_exec_path" ]] && svc_disp="$(basename "$svc_exec_path")"
    fi
    if declare -F workspace_listen_ports_csv >/dev/null 2>&1; then
      auto_csv=$(workspace_listen_ports_csv "$ws")
    fi
    [[ -n "$auto_csv" ]] && primary_auto="${auto_csv%%,*}"
    if [[ -n "$svc_port" ]] && workspace_service_port_listening "$svc_port"; then
      svc_on=1
    fi
    if [[ "$svc_on" -eq 0 && -n "$auto_csv" ]]; then
      svc_on=1
    fi
    if [[ -n "$svc_port" ]]; then
      port_inp_extra=" value=\"$(html_escape "$svc_port")\""
    elif [[ -n "$primary_auto" ]]; then
      port_inp_extra=" value=\"$(html_escape "$primary_auto")\""
    fi
    stop_port="$svc_port"
    [[ -z "$stop_port" && -n "$primary_auto" ]] && stop_port="$primary_auto"
    open_disabled=""
    open_title=""
    if [[ -z "$stop_port" ]]; then
      open_disabled=" disabled"
      open_title=" title=\"$(_d "열 포트 없음" "No port")\""
    fi
    if [[ "$svc_on" -eq 1 ]]; then
      if [[ -n "$auto_csv" ]]; then
        running_ports_label="${auto_csv//,/ · }"
      elif [[ -n "$svc_port" ]]; then
        running_ports_label="$svc_port"
      elif [[ -n "$stop_port" ]]; then
        running_ports_label="$stop_port"
      fi
    fi
    cf_show_ports=""
    [[ -n "$svc_port" ]] && cf_show_ports="$svc_port"
    if [[ -n "$auto_csv" ]]; then
      _rest="$auto_csv,"
      while [[ -n "$_rest" ]]; do
        _pp="${_rest%%,*}"
        _rest="${_rest#*,}"
        _pp="${_pp// /}"
        [[ "$_pp" =~ ^[0-9]+$ ]] || continue
        if [[ -z "$cf_show_ports" ]]; then
          cf_show_ports="$_pp"
        elif [[ ",$cf_show_ports," != *",$_pp,"* ]]; then
          cf_show_ports="$cf_show_ports,$_pp"
        fi
      done
    fi
    [[ -z "$cf_show_ports" && -n "$stop_port" ]] && cf_show_ports="$stop_port"
    local fold_stat_class fold_stat_text
    fold_stat_class="repo-fold-stat"
    if [[ -n "$svc_shell" ]]; then
      if [[ "$svc_on" -eq 1 && -n "$running_ports_label" ]]; then
        fold_stat_class="repo-fold-stat ok"
        fold_stat_text="$(_d "실행 중" "Running") · ${running_ports_label}"
      elif [[ "$svc_on" -eq 1 ]]; then
        fold_stat_class="repo-fold-stat ok"
        fold_stat_text="$(_d "실행 중" "Running")"
      elif [[ -n "$svc_port" ]]; then
        fold_stat_class="repo-fold-stat warn"
        fold_stat_text="$(_d "포트" "Port") ${svc_port} · $(_d "대기" "idle")"
      else
        fold_stat_class="repo-fold-stat warn"
        fold_stat_text="$(_d "LISTEN 없음" "No listener")"
      fi
    else
      if [[ "$svc_on" -eq 1 && -n "$running_ports_label" ]]; then
        fold_stat_class="repo-fold-stat ok"
        fold_stat_text="$(_d "실행 중" "Running") · ${running_ports_label} · $(_d "자동" "auto")"
      elif [[ "$svc_on" -eq 1 ]]; then
        fold_stat_class="repo-fold-stat ok"
        fold_stat_text="$(_d "실행 중" "Running") · $(_d "자동" "auto")"
      else
        fold_stat_class="repo-fold-stat bad"
        fold_stat_text="$(_d "실행 파일 없음" "No start file")"
      fi
    fi
    printf '    <div class="repo" data-ws-path="%s">\n' "$(html_escape "$ws")"
    printf '      <details class="repo-fold">\n'
    printf '        <summary class="repo-fold-summary" title="%s">\n' "$(_d "펼쳐서 설정" "Expand to configure")"
    printf '          <span class="repo-fold-sum-inner">\n'
    printf '            <span class="repo-fold-actions">\n'
    printf '              <button type="button" class="ws-star-btn ws-star-ghost" title="%s" aria-label="%s" aria-pressed="false" onclick="event.stopPropagation()">☆</button>\n' "$(_d "즐겨찾기" "Favorite")" "$(_d "즐겨찾기" "Favorite")"
    printf '              <span class="ws-order-pair" role="group" aria-label="%s">\n' "$(_d "순서" "Reorder")"
    printf '                <button type="button" class="ws-order-btn ws-order-up" title="%s" aria-label="%s" onclick="event.stopPropagation()">↑</button><button type="button" class="ws-order-btn ws-order-down" title="%s" aria-label="%s" onclick="event.stopPropagation()">↓</button>\n' "$(_d "위로" "Up")" "$(_d "위로" "Up")" "$(_d "아래로" "Down")" "$(_d "아래로" "Down")"
    printf '              </span>\n'
    printf '            </span>\n'
    if [[ "$gap" != "OK" ]]; then
      printf '            <span class="repo-fold-title"><span class="dot warn repo-fold-dot" title="%s"></span><span class="repo-name">%s</span></span>\n' "$(_d "설정 필요" "Setup needed")" "$(html_escape "$name")"
    else
      printf '            <span class="repo-fold-title"><span class="repo-name">%s</span></span>\n' "$(html_escape "$name")"
    fi
    printf '            <span class="%s" title="%s">%s</span>\n' "$fold_stat_class" "$(html_escape "$fold_stat_text")" "$(html_escape "$fold_stat_text")"
    printf '            <span class="repo-fold-chev" aria-hidden="true">▸</span>\n'
    printf '          </span>\n'
    printf '        </summary>\n'
    printf '        <div class="repo-fold-body">\n'
    if [[ "$gap" != "OK" ]]; then
      printf '      <div class="repo-action-needed">\n'
      printf '        <span class="repo-action-needed-text">%s</span>\n' "$(html_escape "$gap")"
      printf '        <form class="repo-form repo-form-inline" method="post" action="/configure">\n'
      printf '          <input type="hidden" name="path" value="%s" />\n' "$(html_escape "$ws")"
      printf '          <button type="submit" class="btn btn-small">%s</button>\n' "$(_d "이 폴더 설정" "Set up this folder")"
      printf '        </form>\n'
      printf '      </div>\n'
    fi
    printf '      <div class="ws-svc ws-svc-primary">\n'
    printf '        <div class="ws-svc-head"><span class="ws-svc-title">%s</span>' "$(_d "실행" "Run")"
    if [[ -n "$svc_shell" ]]; then
      if [[ -n "$svc_disp" ]]; then
        printf ' <span class="ws-svc-disp mono">%s</span>' "$(html_escape "$svc_disp")"
      fi
      if [[ "$svc_on" -eq 1 && -n "$running_ports_label" ]]; then
        printf ' <span class="ws-svc-state"><span class="dot ok"></span>%s · %s</span>\n' "$(_d "실행 중" "Running")" "$(html_escape "$running_ports_label")"
      elif [[ "$svc_on" -eq 1 ]]; then
        printf ' <span class="ws-svc-state"><span class="dot ok"></span>%s</span>\n' "$(_d "실행 중" "Running")"
      elif [[ -n "$svc_port" ]]; then
        printf ' <span class="ws-svc-state"><span class="dot bad"></span>%s %s %s</span>\n' "$(_d "포트" "Port")" "$(html_escape "$svc_port")" "$(_d "대기" "idle")"
      else
        printf ' <span class="ws-svc-state"><span class="dot bad"></span>%s</span>\n' "$(_d "LISTEN 없음" "No listener")"
      fi
    else
      if [[ "$svc_on" -eq 1 && -n "$running_ports_label" ]]; then
        printf ' <span class="ws-svc-state"><span class="dot ok"></span>%s · %s</span><span class="ws-svc-note">%s</span>\n' "$(_d "실행 중" "Running")" "$(html_escape "$running_ports_label")" "$(_d "자동" "auto")"
      else
        printf ' <span class="ws-svc-state"><span class="dot bad"></span>%s</span>\n' "$(_d "실행 파일 없음" "No start file")"
      fi
    fi
    printf '        </div>\n'
    printf '        <div class="ws-svc-actions">\n'
    disabled_attr=""
    if [[ -z "$svc_shell" ]]; then
      disabled_attr=" disabled title=\"$(_d "jsonl에 exec 또는 shell 필요" "Need exec or shell in jsonl")\""
    elif [[ "$svc_on" -eq 1 ]]; then
      disabled_attr=" disabled title=\"$(_d "이미 이 포트에서 실행 중" "Already running on this port")\""
    fi
    printf '          <form method="post" action="/workspace-service-start"><input type="hidden" name="path" value="%s" /><button type="submit" class="btn btn-secondary btn-small"%s>%s</button></form>\n' "$(html_escape "$ws")" "$disabled_attr" "$(_d "실행" "Start")"
    stop_forms_ports="${cf_show_ports}"
    [[ -z "$stop_forms_ports" && -n "$stop_port" ]] && stop_forms_ports="$stop_port"
    if [[ -z "$stop_forms_ports" ]]; then
      stop_disabled=" disabled"
      stop_title=" title=\"$(_d "포트 필요" "Port required")\""
      printf '          <form method="post" action="/workspace-service-stop"><input type="hidden" name="path" value="%s" />' "$(html_escape "$ws")"
      printf '<button type="submit" class="btn btn-secondary btn-small"%s%s>%s</button></form>\n' "$stop_disabled" "$stop_title" "$(_d "포트 끄기" "Stop port")"
      printf '          <form method="post" action="/workspace-service-open"><input type="hidden" name="path" value="%s" />' "$(html_escape "$ws")"
      printf '<button type="submit" class="btn btn-secondary btn-small"%s%s>%s</button></form>\n' "$open_disabled" "$open_title" "$(_d "열기" "Open")"
      printf '          <form method="post" action="/workspace-service-open"><input type="hidden" name="path" value="%s" /><input type="hidden" name="network" value="1" />' "$(html_escape "$ws")"
      printf '<button type="submit" class="btn btn-secondary btn-small"%s%s>%s</button></form>\n' "$open_disabled" "$open_title" "$(_d "LAN 열기" "Open on LAN")"
    else
      _spf_rest="${stop_forms_ports},"
      while [[ -n "$_spf_rest" ]]; do
        _spf="${_spf_rest%%,*}"
        _spf_rest="${_spf_rest#*,}"
        _spf="${_spf// /}"
        [[ "$_spf" =~ ^[0-9]+$ ]] || continue
        printf '          <span class="ws-svc-per-port" role="group" aria-label="%s %s">\n' "$(_d "포트" "Port")" "$(html_escape "$_spf")"
        printf '            <form method="post" action="/workspace-service-stop"><input type="hidden" name="path" value="%s" /><input type="hidden" name="port" value="%s" />' "$(html_escape "$ws")" "$(html_escape "$_spf")"
        printf '<button type="submit" class="btn btn-secondary btn-small">%s %s</button></form>\n' "$(_d "포트 끄기" "Stop")" "$(html_escape "$_spf")"
        printf '            <form method="post" action="/workspace-service-open"><input type="hidden" name="path" value="%s" /><input type="hidden" name="port" value="%s" />' "$(html_escape "$ws")" "$(html_escape "$_spf")"
        printf '<button type="submit" class="btn btn-secondary btn-small"%s%s>%s %s</button></form>\n' "$open_disabled" "$open_title" "$(_d "열기" "Open")" "$(html_escape "$_spf")"
        printf '            <form method="post" action="/workspace-service-open"><input type="hidden" name="path" value="%s" /><input type="hidden" name="network" value="1" /><input type="hidden" name="port" value="%s" />' "$(html_escape "$ws")" "$(html_escape "$_spf")"
        printf '<button type="submit" class="btn btn-secondary btn-small"%s%s>%s %s</button></form>\n' "$open_disabled" "$open_title" "$(_d "LAN 열기" "Open on LAN")" "$(html_escape "$_spf")"
        printf '          </span>\n'
      done
    fi
    printf '        </div>\n'
    if [[ -n "$svc_shell" ]]; then
      printf '        <details class="ws-exec-more">\n'
      printf '          <summary class="ws-exec-more-summary">%s</summary>\n' "$(_d "실행 파일 바꾸기" "Change start file")"
      if [[ -n "$svc_exec_path" ]]; then
        printf '        <div class="ws-svc-exec-path mono">%s</div>\n' "$(html_escape "$svc_exec_path")"
      else
        printf '        <div class="ws-svc-cmd mono">%s</div>\n' "$(html_escape "$svc_disp")"
      fi
    else
      printf '        <details class="ws-exec-more">\n'
      printf '          <summary class="ws-exec-more-summary">%s</summary>\n' "$(_d "실행 파일 등록" "Register start file")"
      printf '        <p class="ws-svc-hint">%s</p>\n' "$(_d ".command · .sh 를 드래그하거나 선택" "Drag or pick a .command / .sh file")"
    fi
    printf '          <div class="ws-exec-register" data-ws-path="%s">\n' "$(html_escape "$ws")"
    printf '            <div class="ws-exec-drop-zone" tabindex="0" role="region" aria-label="%s">%s <strong>%s</strong></div>\n' "$(_d "실행 파일 드래그" "Drag start file")" "$(_d "Finder에서" "In Finder,")" "$(_d "끌어다 놓기" "drop here")"
    printf '            <div class="ws-exec-pick-row">\n'
    printf '              <button type="button" class="btn btn-secondary btn-small ws-exec-finder">%s</button>\n' "$(_d "Finder에서 선택" "Choose in Finder")"
    printf '              <button type="button" class="btn btn-secondary btn-small ws-exec-browse">%s</button>\n' "$(_d "찾아보기…" "Browse…")"
    printf '              <input type="file" class="ws-exec-file-input" hidden />\n'
    printf '              <label class="ws-exec-port-label">%s <input type="number" class="ws-exec-port-input" min="1" max="65535" placeholder="%s" title="%s" %s /></label>\n' "$(_d "포트" "Port")" "$(_d "자동" "auto")" "$(_d "저장 시 jsonl에 반영" "Saved to jsonl")" "$port_inp_extra"
    printf '            </div>\n'
    printf '          </div>\n'
    printf '        </details>\n'
    printf '      </div>\n'
    printf '      <div class="ws-tunnel">\n'
    printf '        <div class="ws-svc-head"><span class="ws-svc-title">%s</span><span class="ws-svc-note">%s</span></div>\n' "$(_d "공개 주소" "Public URL")" "$(_d "Tunnel ↔ 포트" "Tunnel ↔ port")"
    if [[ -z "$cf_show_ports" ]]; then
      printf '        <p class="ws-tunnel-hint">%s</p>\n' "$(_d "포트가 있으면 config.yml 과 대조해 도메인을 표시합니다." "Set a port to see matching domains from config.yml.")"
    else
      _rest="$cf_show_ports,"
      while [[ -n "$_rest" ]]; do
        _tp="${_rest%%,*}"
        _rest="${_rest#*,}"
        _tp="${_tp// /}"
        [[ "$_tp" =~ ^[0-9]+$ ]] || continue
        _cf_hn_list=()
        while IFS= read -r _hn || [[ -n "$_hn" ]]; do
          [[ -z "$_hn" ]] && continue
          _cf_hn_list+=("$_hn")
        done < <(cloudflare_hostnames_for_port "$_tp")
        _anyh=${#_cf_hn_list[@]}
        if [[ "$_anyh" -gt 0 ]]; then
          printf '        <div class="ws-tunnel-row ws-tunnel-row--matched"><span class="mono">%s %s</span> · ' "$(_d "포트" "Port")" "$(html_escape "$_tp")"
          for _hn in "${_cf_hn_list[@]}"; do
            printf '<a class="ws-tunnel-link" href="https://%s/" target="_blank" rel="noopener noreferrer">%s</a> ' "$(html_escape "$_hn")" "$(html_escape "$_hn")"
          done
          printf '<span class="ws-tunnel-ok">%s</span>' "$(_d "터널과 포트 일치" "Tunnel matches this port")"
        else
          printf '        <div class="ws-tunnel-row"><span class="mono">%s %s</span> · ' "$(_d "포트" "Port")" "$(html_escape "$_tp")"
          printf '<span class="ws-tunnel-miss">%s</span>' "$(_d "연결된 도메인 없음" "No domain for this port")"
          if cloudflare_looks_connected; then
            _cf_ing_ports="$(cloudflare_config_ingress_local_ports_unique_csv)"
            if [[ -n "$_cf_ing_ports" ]]; then
              printf ' <span class="ws-tunnel-miss-hint">%s <span class="mono">%s</span></span>' "$(_d "config ingress 포트:" "config ingress ports:")" "$(html_escape "$_cf_ing_ports")"
            fi
          fi
        fi
        printf '</div>\n'
      done
    fi
    printf '        <div class="ws-svc-actions" style="margin-top:8px">\n'
    printf '          <form method="post" action="/tunnel-workspace"><input type="hidden" name="path" value="%s" /><button type="submit" class="btn btn-secondary btn-small btn-pill">%s</button></form>\n' "$(html_escape "$ws")" "$(_d "Tunnel 맞추기" "Match tunnel")"
    printf '        </div>\n'
    printf '      </div>\n'
    printf '      <details class="repo-more">\n'
    printf '        <summary class="repo-more-summary">%s</summary>\n' "$(_d "저장소 · 경로 · 워커" "Repo · path · worker")"
    printf '        <div class="repo-more-body">\n'
    printf '          <div class="repo-path mono">%s</div>\n' "$(html_escape "$ws")"
    printf '          <div class="repo-meta"><span><strong>%s</strong> %s</span></div>\n' "$(_d "브랜치" "Branch")" "$(html_escape "$br")"
    printf '          <div class="repo-meta mono">%s</div>\n' "$(html_escape "$origin")"
    printf '          <div class="repo-git mono">%s</div>\n' "$(html_escape "$line")"
    if [[ -n "$cur_gh" ]]; then
      _rnid=$((_rnid + 1))
      printf '          <div class="repo-gh-row">GitHub <span class="mono">%s</span>\n' "$(html_escape "$cur_gh")"
      if [[ "$cur_gh" == "$suggest_gh" ]]; then
        printf '            <button type="button" class="btn btn-secondary btn-small" disabled title="%s">%s</button>\n' "$(_d "이미 제안과 같음" "Already matches")" "$(_d "이름 정리" "Rename")"
      else
        printf '            <form class="inline-form" method="post" action="/rename-repo">\n'
        printf '              <input type="hidden" name="path" value="%s" />\n' "$(html_escape "$ws")"
        printf '              <input type="hidden" name="new_name" value="%s" />\n' "$(html_escape "$suggest_gh")"
        printf '              <button type="submit" class="btn btn-secondary btn-small">%s</button>\n' "$(_d "이름 정리" "Rename")"
        printf '            </form>\n'
      fi
      printf '            <details class="repo-rename-details"><summary>%s</summary>\n' "$(_d "다른 이름" "Other name")"
      printf '            <form method="post" action="/rename-repo">\n'
      printf '              <input type="hidden" name="path" value="%s" />\n' "$(html_escape "$ws")"
      printf '              <input class="repo-rename-input" type="text" name="new_name" maxlength="100" pattern="[a-zA-Z0-9._-]+" required placeholder="%s" autocomplete="off" spellcheck="false" />\n' "$(_d "새 저장소 이름" "new-repo-name")"
      printf '              <button type="submit" class="btn btn-secondary btn-small">%s</button>\n' "$(_d "적용" "Apply")"
      printf '            </form></details>\n'
      printf '          </div>\n'
    fi
    printf '          <div class="repo-worker">%s</div>\n' "$(html_escape "$worker_detail")"
    if [[ -n "$other_worker_bn" ]]; then
      printf '          <p class="repo-worker-remote">%s <span class="mono" title="%s">%s</span> %s</p>\n' "$(_d "워커:" "Worker:")" "$(html_escape "$other_worker_path")" "$(html_escape "$other_worker_bn")" "$(_d "「이 폴더 설정」으로 이 경로에 워커 plist를 추가할 수 있습니다." "Use Set up this folder to add a worker plist for this path.")"
    fi
    if [[ "$gap" == "OK" ]]; then
      if [[ -n "$other_worker_bn" ]]; then
        printf '          <p class="repo-detail-ok">%s</p>\n' "$(_d "필수 항목 정리됨 (워커는 위 안내 참고)" "Basics done (see worker note above)")"
      else
        printf '          <p class="repo-detail-ok">%s</p>\n' "$(_d "이 폴더 설정 완료" "This folder is set up")"
      fi
      printf '          <form class="repo-form" method="post" action="/configure">\n'
      printf '            <input type="hidden" name="path" value="%s" />\n' "$(html_escape "$ws")"
      printf '            <button type="submit" class="btn btn-secondary btn-small">%s</button>\n' "$(_d "설정 다시" "Setup again")"
      printf '          </form>\n'
    else
      printf '          <p class="repo-detail-hint">%s</p>\n' "$(_d "위 안내를 마치면 정리됩니다." "Finish the items above to clear this.")"
    fi
    printf '        </div>\n'
    printf '      </details>\n'
    printf '          </div>\n'
    printf '        </details>\n'
    printf '    </div>\n'
  done <<<"$(discover_workspace_paths)"
}

dashboard_emit_html_template() {
  cat <<'DASH_TMPL'
<!DOCTYPE html>
<html lang="__HTML_LANG__">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__DASH_BRAND__</title>
<style>
  :root { --bg:#0d1117; --surface:#161b22; --border:#30363d; --text:#e6edf3; --muted:#8b949e; --accent:#2f81f7; --ok:#3fb950; --warn:#d29922; --bad:#f85149; }
  * { box-sizing: border-box; }
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif; background:var(--bg); color:var(--text); font-size:14px; line-height:1.45; }
  .app { display:grid; grid-template-columns:minmax(252px,300px) 1fr; min-height:100vh; }
  @media (max-width:720px){ .app{ grid-template-columns:1fr;} .sidebar{ border-right:none; border-bottom:1px solid var(--border);} }
  .sidebar { background:#010409; border-right:1px solid var(--border); padding:18px 14px 28px; }
  .sidebar h1 { font-size:11px; font-weight:600; margin:0 0 6px; color:var(--muted); text-transform:uppercase; letter-spacing:.06em; }
  .brand { font-size:17px; font-weight:700; margin-bottom:6px; line-height:1.25; }
  .sidebar p { font-size:12px; color:var(--muted); margin:0 0 12px; }
  .sidebar-tag { font-size:11px; color:var(--muted); margin:0 0 14px !important; line-height:1.4; }
  .main { padding:22px 24px 40px; max-width:1040px; margin:0 auto; width:100%; }
  .section-title { font-size:11px; font-weight:600; color:var(--muted); text-transform:uppercase; margin:0 0 10px; letter-spacing:.06em; }
  .grid { display:grid; gap:14px; margin-bottom:24px; }
  .grid-setup { grid-template-columns:repeat(2, minmax(0,1fr)); align-items:stretch; }
  @media (max-width:640px){ .grid-setup { grid-template-columns:1fr; } }
  .card { background:var(--surface); border:1px solid var(--border); border-radius:8px; padding:14px; }
  .card-setup { display:flex; flex-direction:column; align-items:flex-start; gap:8px; min-height:0; }
  .card-h { font-weight:600; font-size:13px; display:flex; align-items:center; gap:8px; margin-bottom:4px; }
  .card-lead { font-size:13px; margin:0; font-weight:600; line-height:1.35; }
  .card-lead.ok { color:var(--ok); }
  .card-lead.bad { color:var(--bad); }
  .card-sub { font-size:12px; color:var(--muted); margin:0; line-height:1.4; max-width:100%; }
  .card-actions { display:flex; flex-wrap:wrap; gap:8px; margin-top:6px; }
  .btn-small { font-size:12px; padding:6px 10px; }
  .section-muted { opacity:.95; margin-top:4px !important; }
  .side-dash { margin-top:4px; padding-top:12px; border-top:1px solid var(--border); }
  .side-dash-tag { font-size:10px; font-weight:600; color:var(--muted); text-transform:uppercase; letter-spacing:.04em; margin:0 0 6px; }
  .side-dash-url { margin:0 0 10px; font-size:12px; }
  .side-dash-url a { color:var(--accent); text-decoration:none; }
  .side-dash-url a:hover { text-decoration:underline; }
  .side-dash-actions { margin:0 0 10px; }
  .side-dash-actions form { margin:0; }
  .side-dash-exec-label { font-size:10px; font-weight:600; color:var(--muted); text-transform:uppercase; margin:12px 0 6px; letter-spacing:.04em; }
  .side-exec { font-size:11px; color:var(--muted); line-height:1.4; word-break:break-all; margin-bottom:8px; }
  .side-note { font-size:10px; color:var(--muted); margin:8px 0 0; line-height:1.35; }
  .side-note kbd { background:#21262d; padding:2px 6px; border-radius:4px; font-size:10px; }
  .card-b { font-size:12px; color:var(--muted); }
  .card-b .small { margin-top:6px; font-size:11px; }
  .dot { width:8px; height:8px; border-radius:50%; flex-shrink:0; }
  .dot.ok { background:var(--ok); box-shadow:0 0 8px rgba(63,185,80,.35); }
  .dot.warn { background:var(--warn); }
  .dot.bad { background:var(--bad); }
  .mono { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:11px; word-break:break-all; }
  .repo:not([data-ws-path]) { background:var(--surface); border:1px solid var(--border); border-radius:10px; padding:16px 18px; margin-bottom:14px; }
  .repo[data-ws-path] { margin:0 0 10px; padding:0; background:transparent; border:none; }
  .repo-name { font-size:16px; font-weight:600; }
  .repo-path { color:var(--muted); font-size:11px; margin:6px 0 10px; }
  .repo-meta { font-size:12px; color:var(--muted); margin-bottom:6px; }
  .repo-git { font-size:12px; margin-bottom:8px; }
  .repo-worker { font-size:12px; color:var(--muted); padding-top:10px; margin-top:8px; border-top:1px solid var(--border); }
  .repo-worker-remote { font-size:11px; color:var(--muted); line-height:1.45; margin:10px 0 0; padding-top:8px; border-top:1px dashed var(--border); }
  .gap-hint { font-size:12px; color:var(--muted); margin:10px 0 8px; line-height:1.4; }
  .repo-action-needed { display:flex; flex-wrap:wrap; align-items:center; gap:10px; margin:10px 0 12px; padding:10px 12px; background:#0d1117; border:1px solid var(--border); border-radius:8px; }
  .repo-action-needed-text { font-size:12px; color:var(--warn); flex:1; min-width:160px; line-height:1.4; }
  .repo-form-inline { margin:0; }
  .repo-more { margin-top:12px; font-size:12px; }
  .repo-more-summary { cursor:pointer; color:var(--accent); font-weight:600; list-style:none; user-select:none; padding:4px 0; }
  .repo-more-summary::-webkit-details-marker { display:none; }
  .repo-more-summary::marker { content:none; }
  .repo-more-body { margin-top:10px; padding-top:10px; border-top:1px dashed var(--border); }
  .repo-more-body .repo-path { margin-top:0; }
  .repo-detail-ok { font-size:11px; color:var(--muted); margin:12px 0 8px; }
  .repo-detail-hint { font-size:11px; color:var(--muted); margin:12px 0 0; line-height:1.4; }
  .ws-svc-primary { margin-top:0; }
  .ws-svc-disp { font-size:11px; color:var(--muted); font-weight:400; }
  .repo-more-body .repo-gh-row { display:flex; flex-wrap:wrap; align-items:center; gap:8px; margin:10px 0 6px; font-size:12px; color:var(--muted); }
  .inline-form { display:inline; margin:0; }
  .repo-rename-details { width:100%; margin-top:4px; font-size:11px; color:var(--muted); }
  .repo-rename-details summary { cursor:pointer; color:var(--accent); user-select:none; }
  .repo-rename-details form { margin-top:8px; display:flex; flex-wrap:wrap; gap:8px; align-items:center; }
  .repo-rename-input { flex:1; min-width:140px; max-width:260px; padding:8px 10px; border-radius:6px; border:1px solid var(--border); background:var(--surface); color:var(--text); font-size:13px; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; }
  .ws-svc { margin:10px 0 12px; padding:12px 14px; background:#0d1117; border:1px solid var(--border); border-radius:8px; }
  .ws-svc-head { display:flex; flex-wrap:wrap; align-items:center; gap:8px; margin-bottom:8px; font-size:12px; }
  .ws-svc-title { font-weight:600; color:var(--muted); text-transform:uppercase; font-size:10px; letter-spacing:.04em; }
  .ws-svc-state { display:inline-flex; align-items:center; gap:6px; color:var(--text); font-size:12px; font-weight:600; flex-wrap:wrap; }
  .ws-svc-note { font-size:10px; color:var(--muted); font-weight:400; margin-left:4px; }
  .ws-svc-cmd { font-size:11px; color:var(--muted); margin-bottom:6px; line-height:1.4; word-break:break-word; }
  .ws-svc-exec-path { font-size:10px; color:var(--muted); margin-bottom:10px; line-height:1.35; word-break:break-all; }
  .ws-svc-actions { display:flex; flex-wrap:wrap; gap:8px; align-items:center; }
  .ws-svc-actions form { margin:0; }
  .ws-svc-per-port { display:inline-flex; flex-wrap:wrap; gap:6px; align-items:center; padding:4px 6px; border-radius:8px; border:1px solid var(--border); margin:0 4px 4px 0; }
  .ws-svc-hint { font-size:11px; color:var(--muted); margin-bottom:10px; line-height:1.45; word-break:break-word; }
  .ws-svc .btn:disabled { opacity:0.45; cursor:not-allowed; }
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
  .ws-list-in-fold { margin-bottom:4px; }
  .ws-section-fold { margin-bottom:18px; border:1px solid var(--border); border-radius:10px; background:var(--surface); overflow:hidden; }
  .ws-section-fold-sum { list-style:none; cursor:pointer; display:flex; align-items:center; justify-content:space-between; gap:12px; padding:12px 14px; user-select:none; font-size:11px; font-weight:600; color:var(--muted); text-transform:uppercase; letter-spacing:.06em; }
  .ws-section-fold-sum::-webkit-details-marker { display:none; }
  .ws-section-fold-sum::marker { content:none; }
  .ws-section-fold-title { font-size:11px; font-weight:600; color:var(--muted); text-transform:uppercase; letter-spacing:.06em; }
  .ws-section-fold-chev { color:var(--muted); font-size:12px; transition:transform .15s ease; flex-shrink:0; }
  .ws-section-fold[open] > .ws-section-fold-sum .ws-section-fold-chev { transform:rotate(90deg); }
  .ws-section-fold > .ws-list-in-fold { padding:0 10px 12px; }
  .repo-top { display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
  .repo-fold { width:100%; border:1px solid var(--border); border-radius:10px; background:var(--surface); overflow:hidden; margin-bottom:10px; }
  .repo-fold-summary { list-style:none; cursor:pointer; user-select:none; padding:0; margin:0; }
  .repo-fold-summary::-webkit-details-marker { display:none; }
  .repo-fold-summary::marker { content:none; }
  .repo-fold-sum-inner { display:flex; align-items:center; gap:10px; width:100%; padding:11px 12px; min-height:44px; box-sizing:border-box; }
  .repo-fold-actions { display:flex; align-items:center; gap:2px; flex-shrink:0; }
  .ws-star-ghost { width:34px; height:34px; border:none; border-radius:8px; background:transparent; color:var(--muted); font-size:17px; line-height:1; cursor:pointer; padding:0; display:inline-flex; align-items:center; justify-content:center; transition:color .12s, background .12s; }
  .ws-star-ghost:hover { color:var(--warn); background:rgba(210,153,34,.1); }
  .ws-star-ghost.active { color:var(--warn); }
  .ws-order-pair { display:inline-flex; align-items:stretch; border-radius:8px; border:1px solid var(--border); overflow:hidden; background:#0d1117; }
  .ws-order-pair .ws-order-btn { width:30px; height:30px; border:none; border-radius:0; border-right:1px solid var(--border); background:transparent; color:var(--muted); font-size:12px; cursor:pointer; padding:0; }
  .ws-order-pair .ws-order-down { border-right:none; }
  .ws-order-pair .ws-order-btn:hover { background:#21262d; color:var(--text); }
  .repo-fold-title { display:flex; align-items:center; gap:8px; flex:1; min-width:0; }
  .repo-fold-title .repo-name { font-size:15px; font-weight:600; color:var(--text); text-transform:none; letter-spacing:normal; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .repo-fold-dot { flex-shrink:0; }
  .repo-fold-stat { font-size:11px; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; color:var(--muted); flex-shrink:0; max-width:min(220px,42vw); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; text-align:right; }
  .repo-fold-stat.ok { color:var(--ok); }
  .repo-fold-stat.warn { color:var(--warn); }
  .repo-fold-stat.bad { color:var(--bad); }
  .repo-fold-chev { color:var(--muted); font-size:11px; transition:transform .15s ease; flex-shrink:0; margin-left:4px; }
  .repo-fold[open] > .repo-fold-summary .repo-fold-chev { transform:rotate(90deg); }
  .repo-fold-body { padding:0 12px 14px; border-top:1px dashed var(--border); }
  .repo-fold-body > .repo-action-needed { margin-top:12px; }
  .repo-fold-body > .ws-svc-primary { margin-top:10px; }
  .ws-order-btns { display:inline-flex; gap:4px; }
  .ws-order-btn:disabled { opacity:0.45; cursor:not-allowed; }
  .ws-star-btn { cursor:pointer; }
  .ws-exec-more { margin-top:10px; }
  .ws-exec-more-summary { cursor:pointer; font-size:12px; font-weight:600; color:var(--accent); list-style:none; user-select:none; padding:6px 0; }
  .ws-exec-more-summary::-webkit-details-marker { display:none; }
  .ws-exec-more-summary::marker { content:none; }
  .ws-exec-more[open] .ws-exec-more-summary { margin-bottom:4px; color:var(--muted); }
  .ws-exec-register { margin-top:10px; padding-top:12px; border-top:1px dashed var(--border); }
  .ws-exec-more[open] .ws-exec-register { margin-top:0; }
  .ws-exec-drop-zone { border:2px dashed var(--border); border-radius:8px; padding:14px 12px; text-align:center; font-size:12px; color:var(--muted); margin-bottom:10px; transition:background .15s,border-color .15s; cursor:default; }
  .ws-exec-drop-zone:hover, .ws-exec-drop-zone:focus { outline:none; border-color:var(--accent); color:var(--text); }
  .ws-exec-drop-zone.ws-exec-dropping { background:#161b22; border-color:var(--accent); color:var(--text); }
  .ws-exec-pick-row { display:flex; flex-wrap:wrap; gap:8px; align-items:center; }
  .ws-exec-port-label { font-size:11px; color:var(--muted); display:inline-flex; align-items:center; gap:6px; margin-left:4px; }
  .ws-exec-port-input { width:92px; padding:6px 8px; border-radius:6px; border:1px solid var(--border); background:#0d1117; color:var(--text); font-size:12px; }
  .cf-routes { margin:2px 0 0; padding-left:14px; font-size:11px; line-height:1.4; color:var(--text); max-height:72px; overflow-y:auto; }
  .cf-routes li { margin:3px 0; word-break:break-word; }
  .cf-hint-line { font-size:11px; color:var(--muted); margin:0; line-height:1.35; }
  .path-chip { display:inline-block; padding:3px 8px; border-radius:999px; background:#21262d; border:1px solid var(--border); font-size:11px; max-width:100%; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; vertical-align:middle; }
  .btn-pill { border-radius:999px !important; }
  .card-actions-chips { gap:6px !important; }
  .action-row-chips { gap:8px !important; }
  .ws-tunnel { margin:10px 0 12px; padding:12px 14px; background:#0c1629; border:1px solid var(--border); border-radius:8px; }
  .ws-tunnel-hint { font-size:11px; color:var(--muted); margin:0; line-height:1.45; }
  .ws-tunnel-row { font-size:12px; margin:6px 0; line-height:1.45; display:flex; flex-wrap:wrap; align-items:center; gap:6px; }
  .ws-tunnel-row--matched { border-left:3px solid var(--ok); padding-left:10px; margin-left:-2px; border-radius:2px; }
  .ws-tunnel-miss { color:var(--warn); font-size:11px; }
  .ws-tunnel-miss-hint { color:var(--muted); font-size:10px; }
  .ws-tunnel-ok { color:var(--ok); font-size:11px; font-weight:600; }
  .ws-tunnel-link { color:var(--accent); text-decoration:none; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:11px; }
  .ws-tunnel-link:hover { text-decoration:underline; }
  .side-dash-actions-wrap { display:flex; flex-direction:column; gap:6px; margin-top:4px; }
  .side-dash-actions-wrap form { margin:0; }
  .sidebar-steps { display:flex; flex-direction:column; gap:10px; margin-top:4px; }
  .step-card { background:#0d1117; border:1px solid var(--border); border-radius:10px; padding:10px 10px 12px; }
  .step-label { display:flex; align-items:center; gap:8px; margin:0 0 8px; font-size:11px; font-weight:700; color:var(--text); letter-spacing:.02em; }
  .step-num { flex-shrink:0; width:24px; height:24px; border-radius:8px; background:var(--accent); color:#fff; font-size:12px; font-weight:800; display:inline-flex; align-items:center; justify-content:center; line-height:1; }
  .step-desc { font-size:10px; color:var(--muted); margin:-4px 0 8px 32px; line-height:1.35; }
  .btn-choice { width:100%; box-sizing:border-box; display:flex; align-items:center; justify-content:space-between; gap:10px; padding:10px 12px; border-radius:8px; border:1px solid var(--border); background:#161b22; color:var(--text); font-size:12px; font-weight:600; cursor:pointer; text-align:left; transition:border-color .12s, background .12s; font-family:inherit; }
  .btn-choice:hover { border-color:var(--accent); background:#1c2128; }
  .btn-choice:active { filter:brightness(0.95); }
  .btn-choice .btn-choice-sub { font-size:10px; font-weight:500; color:var(--muted); margin-top:2px; }
  .btn-choice .btn-choice-sub:empty { display:none; margin:0; padding:0; }
  .btn-choice .btn-choice-main { display:flex; flex-direction:column; align-items:flex-start; gap:0; }
  .btn-choice .chev { color:var(--muted); font-size:14px; flex-shrink:0; }
  form.choice-form { margin:0 0 6px; }
  form.choice-form:last-child { margin-bottom:0; }
  .step-card .choice-form:last-of-type { margin-bottom:0; }
  .sidebar-brand-row { display:flex; align-items:center; justify-content:space-between; gap:10px; margin-bottom:8px; }
  .sidebar-cursor-label { font-size:11px; font-weight:600; color:var(--muted); text-transform:uppercase; letter-spacing:.06em; }
  .lang-switch { display:inline-flex; gap:4px; flex-shrink:0; }
  .lang-pill { font-size:11px; font-weight:700; padding:4px 10px; border-radius:999px; border:1px solid var(--border); background:#161b22; color:var(--muted); text-decoration:none; display:inline-block; }
  .lang-switch a.lang-pill, .lang-switch button.lang-pill { color:var(--muted); }
  .lang-switch button.lang-pill { cursor:pointer; font-family:inherit; }
  .lang-pill:hover { color:var(--text); border-color:var(--accent); }
  .lang-pill-active { background:var(--accent); border-color:var(--accent); color:#fff !important; }
  details.quick-check { margin-bottom:20px; border:1px solid var(--border); border-radius:10px; background:var(--surface); overflow:hidden; }
  details.quick-check summary { list-style:none; cursor:pointer; padding:12px 14px; display:flex; flex-wrap:wrap; align-items:center; gap:10px 14px; user-select:none; }
  details.quick-check summary::-webkit-details-marker { display:none; }
  details.quick-check summary::marker { content:none; }
  .qc-title { font-size:13px; font-weight:700; color:var(--text); flex-shrink:0; }
  .qc-pairs { display:flex; flex-wrap:wrap; align-items:center; gap:6px 14px; flex:1; min-width:0; }
  .qc-pair { display:inline-flex; align-items:center; gap:7px; font-size:11px; color:var(--muted); font-weight:500; }
  .qc-pair .dot { width:9px; height:9px; flex-shrink:0; }
  .qc-lbl { line-height:1.25; white-space:nowrap; }
  .qc-chev { margin-left:auto; flex-shrink:0; color:var(--muted); font-size:12px; transition:transform .15s ease; }
  [data-dash-locale][hidden] { display:none !important; }
  details.quick-check[open] summary .qc-chev { transform:rotate(90deg); }
  .qc-lang-block { display:flex; flex-wrap:wrap; align-items:center; gap:10px 14px; flex:1; min-width:0; }
  .quick-check-grid { margin:0 14px 14px; }
  details.step-advanced { margin-top:8px; border-top:1px dashed var(--border); padding-top:8px; }
  details.step-advanced summary { font-size:10px; color:var(--muted); cursor:pointer; list-style:none; user-select:none; padding:4px 0; }
  details.step-advanced summary::-webkit-details-marker { display:none; }
</style>
</head>
<body>
<div class="app">
  <aside class="sidebar">
    __SIDEBAR_EXEC__
  </aside>
  <main class="main">
    <details class="quick-check">
      <summary class="quick-check-sum">
__QUICK_SUMMARY__
      </summary>
      <div class="grid grid-setup quick-check-grid">
__GLOBAL_CARDS__
      </div>
    </details>
__GLOBAL_ACTIONS__
    <div class="section-title"><span class="dash-locale" data-dash-locale="ko"__DL_HID_KO__>__H_S2_KO__</span><span class="dash-locale" data-dash-locale="en"__DL_HID_EN__>__H_S2_EN__</span></div>
    <div class="ws-toolbar">
      <label for="ws-search"><span class="dash-locale" data-dash-locale="ko"__DL_HID_KO__>__LBL_SEARCH_KO__</span><span class="dash-locale" data-dash-locale="en"__DL_HID_EN__>__LBL_SEARCH_EN__</span></label>
      <input type="search" id="ws-search" class="ws-search-input" placeholder="__PH_SEARCH_INIT__" data-placeholder-ko="__PH_SEARCH_KO__" data-placeholder-en="__PH_SEARCH_EN__" autocomplete="off" enterkeyhint="search" />
    </div>
    <div id="ws-favorites-block" class="ws-favorites-block" hidden>
      <div class="section-title ws-sub"><span class="dash-locale" data-dash-locale="ko"__DL_HID_KO__>__LBL_FAV_KO__</span><span class="dash-locale" data-dash-locale="en"__DL_HID_EN__>__LBL_FAV_EN__</span></div>
      <div id="ws-favorites-list" class="ws-list"></div>
    </div>
    <details class="ws-section-fold" id="ws-all-fold">
      <summary class="ws-section-fold-sum">
        <span class="ws-section-fold-title"><span class="dash-locale" id="ws-all-heading-ko" data-dash-locale="ko"__DL_HID_KO__>__LBL_PROJECTS_KO__</span><span class="dash-locale" id="ws-all-heading-en" data-dash-locale="en"__DL_HID_EN__>__LBL_PROJECTS_EN__</span></span>
        <span class="ws-section-fold-chev" aria-hidden="true">▸</span>
      </summary>
      <div id="ws-all-list" class="ws-list ws-list-in-fold">
__WORKSPACES__
      </div>
    </details>
    <footer>__GENERATED_AT__<span class="dash-locale" data-dash-locale="ko"__DL_HID_KO__>__FN_KO__</span><span class="dash-locale" data-dash-locale="en"__DL_HID_EN__>__FN_EN__</span></footer>
  </main>
</div>
<script type="application/json" id="dash-fav-boot">__FAV_BOOT_JSON__</script>
<script type="application/json" id="dash-order-boot">__ORDER_BOOT_JSON__</script>
__DASH_STAY_SCRIPT__
</body>
</html>
DASH_TMPL
}

# stdout: 생성된 HTML 경로
status_dashboard_write_html() {
  local out="${1:-}"
  [[ -n "$out" ]] || out="$(mktemp /tmp/cursor-dash.XXXXXX).html"
  local gfile gafile wfile tfile sfile gen qcfile
  local HTML_LANG HS1 HS2 DL_HID_KO DL_HID_EN PH_SEARCH_INIT
  local HS2_KO HS2_EN LBL_SEARCH_KO LBL_SEARCH_EN PH_SEARCH_KO PH_SEARCH_EN
  local LBL_FAV_KO LBL_FAV_EN LBL_PROJECTS_KO LBL_PROJECTS_EN
  gfile=$(mktemp)
  gafile=$(mktemp)
  wfile=$(mktemp)
  tfile=$(mktemp)
  sfile=$(mktemp)
  qcfile=$(mktemp)
  if is_dash_en; then
    HTML_LANG="en"
    HS1="Quick check"
    HS2="Projects"
    DL_HID_KO=" hidden"
    DL_HID_EN=""
    PH_SEARCH_INIT="Filter by name or path…"
  else
    HTML_LANG="ko"
    HS1="빠른 점검"
    HS2="프로젝트"
    DL_HID_KO=""
    DL_HID_EN=" hidden"
    PH_SEARCH_INIT="이름·경로로 찾기…"
  fi
  HS2_KO="프로젝트"
  HS2_EN="Projects"
  LBL_SEARCH_KO="검색"
  LBL_SEARCH_EN="Search"
  PH_SEARCH_KO="이름·경로로 찾기…"
  PH_SEARCH_EN="Filter by name or path…"
  LBL_FAV_KO="즐겨찾기"
  LBL_FAV_EN="Favorites"
  LBL_PROJECTS_KO="프로젝트"
  LBL_PROJECTS_EN="Projects"
  _dashboard_quick_check_summary_write_file "$qcfile"
  dashboard_global_cards_html > "$gfile"
  printf '\n' > "$gafile"
  printf '%s\n' "<p class=\"side-note\">$(_d "로컬 서버:" "Local server:") <code>./setup</code></p>" > "$sfile"
  if ! discover_workspace_paths | grep -q .; then
    printf '    <div class="repo"><div class="repo-name">%s</div><div class="repo-path mono">%s</div></div>\n' "$(_d "폴더 없음" "No folders")" "$(_d "추가한 폴더·~/Dev 등에서 찾습니다" "From added folders and e.g. ~/Dev")" > "$wfile"
  else
    dashboard_workspace_rows_html > "$wfile"
  fi
  dashboard_emit_html_template > "$tfile"
  gen=$(date '+%Y-%m-%d %H:%M:%S')
  FN_KO=""
  FN_EN=""
  if command_exists python3; then
    DBR="${CURSOR_DASH_BRAND:-$(_d "Cursor 셋업" "Cursor Setup")}" TPL="$tfile" G="$gfile" GA="$gafile" W="$wfile" SB="$sfile" QC="$qcfile" O="$out" GEN="$gen" FN_KO="$FN_KO" FN_EN="$FN_EN" HS1="$HS1" HS2="$HS2" HS2_KO="$HS2_KO" HS2_EN="$HS2_EN" HTML_LANG="$HTML_LANG" LBL_SEARCH_KO="$LBL_SEARCH_KO" LBL_SEARCH_EN="$LBL_SEARCH_EN" PH_SEARCH_KO="$PH_SEARCH_KO" PH_SEARCH_EN="$PH_SEARCH_EN" PH_SEARCH_INIT="$PH_SEARCH_INIT" LBL_FAV_KO="$LBL_FAV_KO" LBL_FAV_EN="$LBL_FAV_EN" LBL_PROJECTS_KO="$LBL_PROJECTS_KO" LBL_PROJECTS_EN="$LBL_PROJECTS_EN" DL_HID_KO="$DL_HID_KO" DL_HID_EN="$DL_HID_EN" python3 <<'PY'
import json, pathlib, os
t = pathlib.Path(os.environ["TPL"]).read_text(encoding="utf-8")
g = pathlib.Path(os.environ["G"]).read_text(encoding="utf-8")
ga = pathlib.Path(os.environ["GA"]).read_text(encoding="utf-8")
w = pathlib.Path(os.environ["W"]).read_text(encoding="utf-8")
sb = pathlib.Path(os.environ["SB"]).read_text(encoding="utf-8")
qc_path = os.environ.get("QC", "")
qc = pathlib.Path(qc_path).read_text(encoding="utf-8") if qc_path and pathlib.Path(qc_path).is_file() else ""
dbrand = os.environ.get("DBR") or "Cursor Setup"
html_lang = os.environ.get("HTML_LANG", "ko")
boot_path = pathlib.Path.home() / ".cursor-setup" / "dashboard-favorites.json"
boot = []
if boot_path.is_file():
    try:
        boot = json.loads(boot_path.read_text(encoding="utf-8"))
    except Exception:
        boot = []
if not isinstance(boot, list):
    boot = []
boot = [str(x).strip() for x in boot if isinstance(x, str) and str(x).strip()]
fav_json = json.dumps(boot, ensure_ascii=False)
order_path = pathlib.Path.home() / ".cursor-setup" / "dashboard-workspace-order.json"
order_boot = []
if order_path.is_file():
    try:
        order_boot = json.loads(order_path.read_text(encoding="utf-8"))
    except Exception:
        order_boot = []
if not isinstance(order_boot, list):
    order_boot = []
order_boot = [str(x).strip() for x in order_boot if isinstance(x, str) and str(x).strip()]
order_json = json.dumps(order_boot, ensure_ascii=False)
pathlib.Path(os.environ["O"]).write_text(
    t.replace("__GLOBAL_CARDS__", g)
    .replace("__GLOBAL_ACTIONS__", ga)
    .replace("__WORKSPACES__", w)
    .replace("__GENERATED_AT__", os.environ["GEN"])
    .replace("__FN_KO__", os.environ.get("FN_KO", ""))
    .replace("__FN_EN__", os.environ.get("FN_EN", ""))
    .replace("__SIDEBAR_EXEC__", sb)
    .replace("__QUICK_SUMMARY__", qc)
    .replace("__HTML_LANG__", html_lang)
    .replace("__H_S1__", os.environ["HS1"])
    .replace("__H_S2_KO__", os.environ.get("HS2_KO", os.environ.get("HS2", "")))
    .replace("__H_S2_EN__", os.environ.get("HS2_EN", os.environ.get("HS2", "")))
    .replace("__LBL_SEARCH_KO__", os.environ.get("LBL_SEARCH_KO", ""))
    .replace("__LBL_SEARCH_EN__", os.environ.get("LBL_SEARCH_EN", ""))
    .replace("__PH_SEARCH_KO__", os.environ.get("PH_SEARCH_KO", ""))
    .replace("__PH_SEARCH_EN__", os.environ.get("PH_SEARCH_EN", ""))
    .replace("__PH_SEARCH_INIT__", os.environ.get("PH_SEARCH_INIT", os.environ.get("PH_SEARCH_KO", "")))
    .replace("__LBL_FAV_KO__", os.environ.get("LBL_FAV_KO", ""))
    .replace("__LBL_FAV_EN__", os.environ.get("LBL_FAV_EN", ""))
    .replace("__LBL_PROJECTS_KO__", os.environ.get("LBL_PROJECTS_KO", ""))
    .replace("__LBL_PROJECTS_EN__", os.environ.get("LBL_PROJECTS_EN", ""))
    .replace("__DL_HID_KO__", os.environ.get("DL_HID_KO", ""))
    .replace("__DL_HID_EN__", os.environ.get("DL_HID_EN", ""))
    .replace("__FAV_BOOT_JSON__", fav_json)
    .replace("__ORDER_BOOT_JSON__", order_json)
    .replace("__DASH_STAY_SCRIPT__", "")
    .replace("__DASH_BRAND__", dbrand),
    encoding="utf-8",
)
PY
  else
    log_err "python3 가 필요합니다 (HTML 대시보드)"
    rm -f "$gfile" "$gafile" "$wfile" "$tfile" "$sfile" "$qcfile"
    return 1
  fi
  rm -f "$gfile" "$gafile" "$wfile" "$tfile" "$sfile" "$qcfile"
  [[ "${CURSOR_SETUP_HTML_QUIET:-0}" == "1" ]] || printf '%s\n' "$out"
}

_dashboard_stay_script_fragment() {
  cat <<'JSEOF'
<div id="dash-toast" class="dash-toast" role="status" aria-live="polite"></div>
<script>
(function () {
  function dashToastStrings() {
    var en = (document.documentElement.lang || '').toLowerCase().indexOf('en') === 0;
    return en ? {
    checkTerminal: 'Check Terminal…',
    denylist: 'Not allowed — refresh below and retry',
    errStatus: 'Error ',
    errHint: ' · ./setup --workspace …',
    reloadSoon: 'Reloading soon…',
    reloadWhenDone: 'Reload when finished…',
    configureHint: 'Continue in Terminal · refresh when done',
    stopping: 'Stopping server…',
    setupOpened: 'Setup file opened',
    svcStart: 'Started · refresh to update port status',
    svcStop: 'Stop requested · reloading soon',
    openPort: 'Opening port in browser',
    browserOk: 'Check your browser',
    done: 'Done · refresh if needed',
    connFail: 'Connection failed · is this the 127.0.0.1 dashboard?'
  } : {
    checkTerminal: '터미널 확인…',
    denylist: '허용 목록 없음 → 아래 새로고침 후 다시',
    errStatus: '오류 ',
    errHint: ' · ./setup --workspace …',
    reloadSoon: '잠시 후 새로고침…',
    reloadWhenDone: '끝나면 새로고침…',
    configureHint: '터미널에서 진행 · 끝나면 새로고침',
    stopping: '서버 종료 중…',
    setupOpened: '셋업 파일을 열었습니다',
    svcStart: '실행 파일 실행 · 새로고침하면 포트 상태 갱신',
    svcStop: '포트 종료 요청 · 잠시 후 새로고침',
    openPort: '브라우저에서 포트를 엽니다',
    browserOk: '브라우저 확인',
    done: '완료 · 필요 시 새로고침',
    connFail: '연결 실패 · 127.0.0.1 대시보드인지 확인'
  };
  }
  document.addEventListener('submit', function (e) {
    var L = dashToastStrings();
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
      bar.textContent = L.checkTerminal;
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
          if (bar) bar.textContent = L.denylist;
          return;
        }
        if (!res.ok) {
          if (bar) bar.textContent = L.errStatus + res.status + L.errHint;
          return;
        }
        var reloadQuick = ['/action/gh-login', '/action/agent-login', '/action/worker-kickstart'];
        var reloadSlow = ['/action/agent-install', '/tunnel', '/tunnel-workspace', '/rename-repo', '/workspace-add-folder'];
        if (reloadQuick.indexOf(act) !== -1) {
          if (bar) bar.textContent = L.reloadSoon;
          setTimeout(function () { window.location.reload(); }, 2200);
        } else if (reloadSlow.indexOf(act) !== -1) {
          if (bar) bar.textContent = L.reloadWhenDone;
          var delay = act === '/action/agent-install' ? 9000 : act === '/rename-repo' ? 4500 : act === '/workspace-add-folder' ? 4500 : 5000;
          setTimeout(function () { window.location.reload(); }, delay);
        } else if (act === '/configure') {
          if (bar) bar.textContent = L.configureHint;
        } else if (act === '/dashboard-stop') {
          if (bar) bar.textContent = L.stopping;
        } else if (act === '/launch-setup') {
          if (bar) bar.textContent = L.setupOpened;
        } else if (act === '/workspace-service-start') {
          if (bar) bar.textContent = L.svcStart;
          setTimeout(function () { window.location.reload(); }, 1800);
        } else if (act === '/workspace-service-stop') {
          if (bar) bar.textContent = L.svcStop;
          setTimeout(function () { window.location.reload(); }, 1600);
        } else if (act === '/workspace-service-open') {
          if (bar) bar.textContent = L.openPort;
        } else if (act === '/action/open-github' || act === '/action/open-cursor-docs') {
          if (bar) bar.textContent = L.browserOk;
        } else {
          if (bar) bar.textContent = L.done;
        }
      })
      .catch(function () {
        if (bar) bar.textContent = L.connFail;
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
  /* 즐겨찾기: ~/.cursor-setup/dashboard-favorites.json 이 본문(대시보드 포트와 무관). localStorage 는 같은 포트에서만 쓰이므로 매번 서버에서 불러옵니다. */
  var LS_KEY = 'cursorSetupWorkspaceFavorites_v1';
  var ORDER_LS_KEY = 'cursorSetupWorkspaceOrder_v1';
  var favsActive = [];
  var orderActive = [];
  var embedFallback = [];
  var orderEmbedFallback = [];
  try {
    var bel = document.getElementById('dash-fav-boot');
    if (bel && bel.textContent) {
      var pr = JSON.parse(bel.textContent.trim());
      embedFallback = Array.isArray(pr) ? pr : [];
    }
  } catch (e0) { embedFallback = []; }
  try {
    var oel = document.getElementById('dash-order-boot');
    if (oel && oel.textContent) {
      var oraw = JSON.parse(oel.textContent.trim());
      orderEmbedFallback = Array.isArray(oraw) ? oraw : [];
    }
  } catch (e0b) { orderEmbedFallback = []; }
  function normPathKey(p) {
    if (!p) return '';
    var s = String(p).trim();
    if (s.length > 1) s = s.replace(/\/+$/, '');
    return s;
  }
  function indexOfFav(list, p) {
    var k = normPathKey(p);
    for (var i = 0; i < list.length; i++) {
      if (normPathKey(list[i]) === k) return i;
    }
    return -1;
  }
  function getFavs() {
    return favsActive;
  }
  function getOrder() {
    return orderActive;
  }
  var _favSaveT = null;
  var _orderSaveT = null;
  function persistFavsMirror() {
    try {
      localStorage.setItem(LS_KEY, JSON.stringify(favsActive));
    } catch (e1) {}
  }
  function persistOrderMirror() {
    try {
      localStorage.setItem(ORDER_LS_KEY, JSON.stringify(orderActive));
    } catch (e2) {}
  }
  function applyFavsFromServer(arr) {
    favsActive = Array.isArray(arr) ? arr.slice() : [];
    persistFavsMirror();
    layoutWorkspaces();
  }
  function setFavs(arr) {
    favsActive = Array.isArray(arr) ? arr.slice() : [];
    persistFavsMirror();
    if (_favSaveT) clearTimeout(_favSaveT);
    _favSaveT = setTimeout(function () {
      _favSaveT = null;
      var body = JSON.stringify(favsActive);
      fetch('/favorite-save', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: body, credentials: 'same-origin' })
        .catch(function () {});
    }, 450);
  }
  function sanitizeOrder(arr) {
    if (!Array.isArray(arr)) return [];
    var out = [];
    arr.forEach(function (x) {
      var p = normPathKey(x);
      if (!p) return;
      if (indexOfFav(out, p) !== -1) return;
      out.push(p);
    });
    return out;
  }
  function applyOrderFromServer(arr) {
    orderActive = sanitizeOrder(arr);
    persistOrderMirror();
    layoutWorkspaces();
  }
  function setOrder(arr) {
    orderActive = sanitizeOrder(arr);
    persistOrderMirror();
    if (_orderSaveT) clearTimeout(_orderSaveT);
    _orderSaveT = setTimeout(function () {
      _orderSaveT = null;
      var body = JSON.stringify(orderActive);
      fetch('/workspace-order-save', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: body, credentials: 'same-origin' })
        .catch(function () {});
    }, 450);
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
  function refreshOrderButtons() {
    ['ws-favorites-list', 'ws-all-list'].forEach(function (id) {
      var list = document.getElementById(id);
      if (!list) return;
      var cards = Array.prototype.slice.call(list.querySelectorAll('.repo[data-ws-path]'));
      cards.forEach(function (card, idx) {
        var up = card.querySelector('.ws-order-up');
        var down = card.querySelector('.ws-order-down');
        if (up) up.disabled = idx === 0;
        if (down) down.disabled = idx === cards.length - 1;
      });
    });
  }
  function persistOrderFromDom() {
    var out = [];
    ['ws-favorites-list', 'ws-all-list'].forEach(function (id) {
      var list = document.getElementById(id);
      if (!list) return;
      list.querySelectorAll('.repo[data-ws-path]').forEach(function (card) {
        var p = normPathKey(card.getAttribute('data-ws-path'));
        if (!p) return;
        if (indexOfFav(out, p) !== -1) return;
        out.push(p);
      });
    });
    setOrder(out);
    refreshOrderButtons();
  }
  function moveCard(card, dir) {
    if (!card || !dir) return;
    var list = card.parentElement;
    if (!list) return;
    var cards = Array.prototype.slice.call(list.querySelectorAll('.repo[data-ws-path]'));
    var idx = cards.indexOf(card);
    if (idx === -1) return;
    var nextIdx = idx + dir;
    if (nextIdx < 0 || nextIdx >= cards.length) return;
    if (dir < 0) list.insertBefore(card, cards[nextIdx]);
    else list.insertBefore(cards[nextIdx], card);
    persistOrderFromDom();
    applyWorkspaceSearch();
  }
  function layoutWorkspaces() {
    var allList = document.getElementById('ws-all-list');
    var favList = document.getElementById('ws-favorites-list');
    if (!allList || !favList) return;
    var favs = getFavs();
    var cards = collectCards();
    var order = getOrder();
    if (order.length > 0) {
      cards.sort(function (a, b) {
        var pa = normPathKey(a.getAttribute('data-ws-path'));
        var pb = normPathKey(b.getAttribute('data-ws-path'));
        var ia = indexOfFav(order, pa);
        var ib = indexOfFav(order, pb);
        if (ia === -1 && ib === -1) return 0;
        if (ia === -1) return 1;
        if (ib === -1) return -1;
        return ia - ib;
      });
    }
    cards.forEach(function (card) {
      var p = card.getAttribute('data-ws-path');
      if (!p) return;
      var on = indexOfFav(favs, p) !== -1;
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
    refreshOrderButtons();
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
    var hko = document.getElementById('ws-all-heading-ko');
    var hen = document.getElementById('ws-all-heading-en');
    if (hko) {
      hko.textContent = getFavs().length > 0 ? '나머지 프로젝트' : '프로젝트';
    }
    if (hen) {
      hen.textContent = getFavs().length > 0 ? 'Other projects' : 'Projects';
    }
    var allFold = document.getElementById('ws-all-fold');
    if (allFold && q) allFold.open = true;
  }
  document.addEventListener('DOMContentLoaded', function () {
    document.body.addEventListener('click', function (e) {
      var up = e.target && e.target.closest ? e.target.closest('.ws-order-up') : null;
      if (up) {
        e.preventDefault();
        e.stopPropagation();
        moveCard(up.closest('.repo'), -1);
        return;
      }
      var down = e.target && e.target.closest ? e.target.closest('.ws-order-down') : null;
      if (down) {
        e.preventDefault();
        e.stopPropagation();
        moveCard(down.closest('.repo'), 1);
        return;
      }
      var t = e.target && e.target.closest ? e.target.closest('.ws-star-btn') : null;
      if (!t) return;
      e.preventDefault();
      e.stopPropagation();
      var card = t.closest('.repo');
      if (!card) return;
      var p = card.getAttribute('data-ws-path');
      if (!p) return;
      var favs = getFavs().slice();
      var i = indexOfFav(favs, p);
      if (i === -1) favs.push(p);
      else favs.splice(i, 1);
      setFavs(favs);
      layoutWorkspaces();
      persistOrderFromDom();
    });
    var search = document.getElementById('ws-search');
    if (search) {
      search.addEventListener('input', applyWorkspaceSearch);
      search.addEventListener('search', applyWorkspaceSearch);
    }
    applyOrderFromServer(orderEmbedFallback);
    fetch('/workspace-order-list', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(new Error('bad')); })
      .then(function (data) { applyOrderFromServer(data); })
      .catch(function () {});
    fetch('/favorite-list', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : Promise.reject(new Error('bad')); })
      .then(function (data) { applyFavsFromServer(data); })
      .catch(function () { applyFavsFromServer(embedFallback); });
  });
})();
</script>
WSEOF
}

_dashboard_workspace_exec_script_fragment() {
  cat <<'EXEOF'
<script>
(function () {
  function pageEn() {
    return (document.documentElement.lang || '').toLowerCase().indexOf('en') === 0;
  }
  var LXen = {
    pickInFinder: 'Pick a file in the Finder window…',
    savedReload: 'Saved · reloading',
    unknown: 'Unknown response',
    errRetry: 'Error · refresh and retry',
    uploading: 'Uploading…',
    uploadFail: 'Upload failed',
    connFail: 'Connection failed',
    dropFile: 'Drop a file here'
  };
  var LXko = {
    pickInFinder: 'Finder 창에서 실행 파일을 고르세요…',
    savedReload: '등록됨 · 새로고침합니다',
    unknown: '알 수 없는 응답',
    errRetry: '오류 · 새로고침 후 다시',
    uploading: '업로드 중…',
    uploadFail: '업로드 실패',
    connFail: '연결 실패',
    dropFile: '파일을 놓아 주세요'
  };
  function lx() { return pageEn() ? LXen : LXko; }
  function toast(msg) {
    var bar = document.getElementById('dash-toast');
    if (!bar) return;
    bar.textContent = msg;
    bar.classList.add('visible');
    setTimeout(function () { bar.classList.remove('visible'); }, 4200);
  }
  function portFromRegister(reg) {
    var inp = reg.querySelector('.ws-exec-port-input');
    if (!inp || !inp.value) return '';
    var n = parseInt(inp.value, 10);
    if (!n || n < 1 || n > 65535) return '';
    return String(n);
  }
  function postChoose(wsPath, portStr) {
    var body = new URLSearchParams();
    body.set('path', wsPath);
    if (portStr) body.set('port', portStr);
    toast(lx().pickInFinder);
    fetch('/workspace-exec-choose', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' },
      body: body,
      credentials: 'same-origin'
    })
      .then(function (r) {
        return r.text().then(function (txt) {
          var j = {};
          try { j = JSON.parse(txt); } catch (e1) {}
          return { ok: r.ok, j: j };
        });
      })
      .then(function (x) {
        if (x.j && x.j.ok) {
          toast(lx().savedReload);
          setTimeout(function () { window.location.reload(); }, 600);
        } else {
          toast((x.j && x.j.err) ? x.j.err : (x.ok ? lx().unknown : lx().errRetry));
        }
      })
      .catch(function () { toast(lx().connFail); });
  }
  function postUpload(wsPath, file, portStr) {
    if (!file) return;
    var fd = new FormData();
    fd.append('path', wsPath);
    fd.append('file', file, file.name);
    if (portStr) fd.append('port', portStr);
    toast(lx().uploading);
    fetch('/workspace-exec-upload', { method: 'POST', body: fd, credentials: 'same-origin' })
      .then(function (r) {
        return r.text().then(function (txt) {
          var j = {};
          try { j = JSON.parse(txt); } catch (e1) {}
          return { ok: r.ok, j: j };
        });
      })
      .then(function (x) {
        if (x.j && x.j.ok) {
          toast(lx().savedReload);
          setTimeout(function () { window.location.reload(); }, 600);
        } else {
          toast((x.j && x.j.err) ? x.j.err : (x.ok ? lx().unknown : lx().uploadFail));
        }
      })
      .catch(function () { toast(lx().connFail); });
  }
  document.addEventListener('DOMContentLoaded', function () {
    document.body.addEventListener('click', function (e) {
      var reg = e.target && e.target.closest ? e.target.closest('.ws-exec-register') : null;
      if (!reg) return;
      var wsPath = reg.getAttribute('data-ws-path');
      if (!wsPath) return;
      if (e.target.classList && e.target.classList.contains('ws-exec-finder')) {
        e.preventDefault();
        postChoose(wsPath, portFromRegister(reg));
        return;
      }
      if (e.target.classList && e.target.classList.contains('ws-exec-browse')) {
        e.preventDefault();
        var finp = reg.querySelector('.ws-exec-file-input');
        if (finp) finp.click();
      }
    });
    document.body.addEventListener('change', function (e) {
      var t = e.target;
      if (!t || !t.classList || !t.classList.contains('ws-exec-file-input')) return;
      var reg = t.closest('.ws-exec-register');
      if (!reg) return;
      var wsPath = reg.getAttribute('data-ws-path');
      if (!wsPath || !t.files || !t.files[0]) return;
      postUpload(wsPath, t.files[0], portFromRegister(reg));
      t.value = '';
    });
    ['dragenter', 'dragover'].forEach(function (ev) {
      document.body.addEventListener(ev, function (e) {
        var z = e.target && e.target.closest ? e.target.closest('.ws-exec-drop-zone') : null;
        if (!z) return;
        e.preventDefault();
        e.stopPropagation();
        z.classList.add('ws-exec-dropping');
      });
    });
    document.body.addEventListener('dragleave', function (e) {
      var z = e.target && e.target.closest ? e.target.closest('.ws-exec-drop-zone') : null;
      if (!z) return;
      var rt = e.relatedTarget;
      try {
        if (rt && z.contains(rt)) return;
      } catch (e2) {}
      z.classList.remove('ws-exec-dropping');
    });
    document.body.addEventListener('drop', function (e) {
      var z = e.target && e.target.closest ? e.target.closest('.ws-exec-drop-zone') : null;
      if (!z) return;
      e.preventDefault();
      e.stopPropagation();
      z.classList.remove('ws-exec-dropping');
      var reg = z.closest('.ws-exec-register');
      if (!reg) return;
      var wsPath = reg.getAttribute('data-ws-path');
      if (!wsPath) return;
      var f = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
      if (f) postUpload(wsPath, f, portFromRegister(reg));
      else toast(lx().dropFile);
    });
  });
})();
</script>
EXEOF
}

_dashboard_lang_toggle_script_fragment() {
  cat <<'LANGJS'
<script>
(function () {
  function dashPageIsEn() {
    return (document.documentElement.lang || '').toLowerCase().indexOf('en') === 0;
  }
  function setDashLang(lang, persist) {
    var isEn = lang === 'en';
    document.documentElement.lang = isEn ? 'en' : 'ko';
    document.querySelectorAll('[data-dash-locale="ko"]').forEach(function (el) {
      if (isEn) el.setAttribute('hidden', '');
      else el.removeAttribute('hidden');
    });
    document.querySelectorAll('[data-dash-locale="en"]').forEach(function (el) {
      if (isEn) el.removeAttribute('hidden');
      else el.setAttribute('hidden', '');
    });
    document.querySelectorAll('[data-dash-set-lang]').forEach(function (btn) {
      var l = btn.getAttribute('data-dash-set-lang');
      var on = (l === 'en') === isEn;
      btn.classList.toggle('lang-pill-active', on);
      btn.setAttribute('aria-pressed', on ? 'true' : 'false');
    });
    var inp = document.getElementById('ws-search');
    if (inp) {
      var pk = inp.getAttribute('data-placeholder-ko') || '';
      var pe = inp.getAttribute('data-placeholder-en') || '';
      inp.setAttribute('placeholder', isEn ? pe : pk);
    }
    if (typeof applyWorkspaceSearch === 'function') applyWorkspaceSearch();
    if (persist) {
      fetch('/set-lang', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' },
        body: 'lang=' + encodeURIComponent(lang),
        credentials: 'same-origin'
      }).catch(function () {});
    }
  }
  document.addEventListener('DOMContentLoaded', function () {
    document.querySelectorAll('[data-dash-set-lang]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var lang = btn.getAttribute('data-dash-set-lang') || 'ko';
        setDashLang(lang, true);
      });
    });
    setDashLang(dashPageIsEn() ? 'en' : 'ko', false);
  });
})();
</script>
LANGJS
}

# 로컬 대시보드 서버용 (버튼·새로고침 링크 포함)
status_dashboard_write_html_interactive() {
  local out="${1:-}"
  [[ -n "$out" ]] || out="$(mktemp /tmp/cursor-dash.XXXXXX).html"
  local gfile gafile wfile tfile sfile gen setup_ex qcfile
  local HTML_LANG HS1 HS2 DL_HID_KO DL_HID_EN PH_SEARCH_INIT
  local HS2_KO HS2_EN LBL_SEARCH_KO LBL_SEARCH_EN PH_SEARCH_KO PH_SEARCH_EN
  local LBL_FAV_KO LBL_FAV_EN LBL_PROJECTS_KO LBL_PROJECTS_EN
  gfile=$(mktemp)
  gafile=$(mktemp)
  wfile=$(mktemp)
  tfile=$(mktemp)
  sfile=$(mktemp)
  qcfile=$(mktemp)
  if is_dash_en; then
    HTML_LANG="en"
    HS1="Quick check"
    HS2="Projects"
    DL_HID_KO=" hidden"
    DL_HID_EN=""
    PH_SEARCH_INIT="Filter by name or path…"
  else
    HTML_LANG="ko"
    HS1="빠른 점검"
    HS2="프로젝트"
    DL_HID_KO=""
    DL_HID_EN=" hidden"
    PH_SEARCH_INIT="이름·경로로 찾기…"
  fi
  HS2_KO="프로젝트"
  HS2_EN="Projects"
  LBL_SEARCH_KO="검색"
  LBL_SEARCH_EN="Search"
  PH_SEARCH_KO="이름·경로로 찾기…"
  PH_SEARCH_EN="Filter by name or path…"
  LBL_FAV_KO="즐겨찾기"
  LBL_FAV_EN="Favorites"
  LBL_PROJECTS_KO="프로젝트"
  LBL_PROJECTS_EN="Projects"
  _dashboard_quick_check_summary_write_file "$qcfile"
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
    printf '<div class="sidebar-brand-row">\n'
    printf '  <span class="sidebar-cursor-label">Cursor</span>\n'
    printf '  <div class="lang-switch" role="group" aria-label="Language / 언어">\n'
    if is_dash_en; then
      printf '    <button type="button" class="lang-pill" data-dash-set-lang="ko" aria-pressed="false">KO</button>\n'
      printf '    <button type="button" class="lang-pill lang-pill-active" data-dash-set-lang="en" aria-pressed="true">EN</button>\n'
    else
      printf '    <button type="button" class="lang-pill lang-pill-active" data-dash-set-lang="ko" aria-pressed="true">KO</button>\n'
      printf '    <button type="button" class="lang-pill" data-dash-set-lang="en" aria-pressed="false">EN</button>\n'
    fi
    printf '  </div>\n'
    printf '</div>\n'
    printf '<div class="dash-locale sidebar-locale-wrap"'
    is_dash_en && printf ' hidden'
    printf ' data-dash-locale="ko">\n'
    CURSOR_DASH_LANG=ko _dashboard_sidebar_locale_body_html "$setup_ex" "${CURSOR_DASH_PORT:-}"
    printf '</div>\n'
    printf '<div class="dash-locale sidebar-locale-wrap"'
    is_dash_en || printf ' hidden'
    printf ' data-dash-locale="en">\n'
    CURSOR_DASH_LANG=en _dashboard_sidebar_locale_body_html "$setup_ex" "${CURSOR_DASH_PORT:-}"
    printf '</div>\n'
  } > "$sfile"
  dashboard_global_cards_html_interactive > "$gfile"
  dashboard_global_actions_html_interactive > "$gafile"
  if ! discover_workspace_paths | grep -q .; then
    {
      printf '    <div class="repo">\n'
      printf '      <div class="repo-name">%s</div>\n' "$(_d "프로젝트 폴더가 없습니다" "No project folders yet")"
      printf '      <div class="repo-path mono">%s <a href="/refresh">%s</a></div>\n' "$(_d "왼쪽에서 폴더를 추가한 뒤 새로고침하세요." "Add folders on the left, then refresh.")" "$(_d "새로고침" "Refresh")"
      printf '      <form method="post" action="/workspace-add-folder" class="choice-form" style="margin-top:10px"><button type="submit" class="btn-choice"><span class="btn-choice-main"><span>%s</span><span class="btn-choice-sub">%s</span></span><span class="chev">›</span></button></form>\n' "$(_d "Finder에서 폴더 추가" "Add folder in Finder")" ""
      printf '    </div>\n'
    } > "$wfile"
  else
    listen_json=""
    if declare -F workspace_listen_map_build >/dev/null 2>&1; then
      listen_json=$(mktemp)
      discover_workspace_paths | workspace_listen_map_build "$listen_json"
      export CURSOR_DASH_LISTEN_MAP="$listen_json"
    fi
    dashboard_workspace_rows_html_interactive > "$wfile"
    unset CURSOR_DASH_LISTEN_MAP
    [[ -n "${listen_json:-}" ]] && rm -f "$listen_json"
  fi
  dashboard_emit_html_template > "$tfile"
  local jfile
  jfile=$(mktemp)
  {
    _dashboard_stay_script_fragment
    _dashboard_ws_search_fav_script_fragment
    _dashboard_workspace_exec_script_fragment
    _dashboard_lang_toggle_script_fragment
  } > "$jfile"
  gen=$(date '+%Y-%m-%d %H:%M:%S')
  FN_KO=" · <a href=\"/refresh\">새로고침</a>"
  FN_EN=" · <a href=\"/refresh\">Refresh</a>"
  if command_exists python3; then
    DBR="${CURSOR_DASH_BRAND:-$(_d "Cursor 셋업" "Cursor Setup")}" TPL="$tfile" G="$gfile" GA="$gafile" W="$wfile" SB="$sfile" QC="$qcfile" JF="$jfile" O="$out" GEN="$gen" FN_KO="$FN_KO" FN_EN="$FN_EN" HS1="$HS1" HS2="$HS2" HS2_KO="$HS2_KO" HS2_EN="$HS2_EN" HTML_LANG="$HTML_LANG" LBL_SEARCH_KO="$LBL_SEARCH_KO" LBL_SEARCH_EN="$LBL_SEARCH_EN" PH_SEARCH_KO="$PH_SEARCH_KO" PH_SEARCH_EN="$PH_SEARCH_EN" PH_SEARCH_INIT="$PH_SEARCH_INIT" LBL_FAV_KO="$LBL_FAV_KO" LBL_FAV_EN="$LBL_FAV_EN" LBL_PROJECTS_KO="$LBL_PROJECTS_KO" LBL_PROJECTS_EN="$LBL_PROJECTS_EN" DL_HID_KO="$DL_HID_KO" DL_HID_EN="$DL_HID_EN" python3 <<'PY'
import json, pathlib, os
t = pathlib.Path(os.environ["TPL"]).read_text(encoding="utf-8")
g = pathlib.Path(os.environ["G"]).read_text(encoding="utf-8")
ga = pathlib.Path(os.environ["GA"]).read_text(encoding="utf-8")
w = pathlib.Path(os.environ["W"]).read_text(encoding="utf-8")
sb = pathlib.Path(os.environ["SB"]).read_text(encoding="utf-8")
js = pathlib.Path(os.environ["JF"]).read_text(encoding="utf-8")
qc_path = os.environ.get("QC", "")
qc = pathlib.Path(qc_path).read_text(encoding="utf-8") if qc_path and pathlib.Path(qc_path).is_file() else ""
dbrand = os.environ.get("DBR") or "Cursor Setup"
html_lang = os.environ.get("HTML_LANG", "ko")
boot_path = pathlib.Path.home() / ".cursor-setup" / "dashboard-favorites.json"
boot = []
if boot_path.is_file():
    try:
        boot = json.loads(boot_path.read_text(encoding="utf-8"))
    except Exception:
        boot = []
if not isinstance(boot, list):
    boot = []
boot = [str(x).strip() for x in boot if isinstance(x, str) and str(x).strip()]
fav_json = json.dumps(boot, ensure_ascii=False)
order_path = pathlib.Path.home() / ".cursor-setup" / "dashboard-workspace-order.json"
order_boot = []
if order_path.is_file():
    try:
        order_boot = json.loads(order_path.read_text(encoding="utf-8"))
    except Exception:
        order_boot = []
if not isinstance(order_boot, list):
    order_boot = []
order_boot = [str(x).strip() for x in order_boot if isinstance(x, str) and str(x).strip()]
order_json = json.dumps(order_boot, ensure_ascii=False)
pathlib.Path(os.environ["O"]).write_text(
    t.replace("__GLOBAL_CARDS__", g)
    .replace("__GLOBAL_ACTIONS__", ga)
    .replace("__WORKSPACES__", w)
    .replace("__GENERATED_AT__", os.environ["GEN"])
    .replace("__FN_KO__", os.environ.get("FN_KO", ""))
    .replace("__FN_EN__", os.environ.get("FN_EN", ""))
    .replace("__SIDEBAR_EXEC__", sb)
    .replace("__QUICK_SUMMARY__", qc)
    .replace("__HTML_LANG__", html_lang)
    .replace("__H_S1__", os.environ["HS1"])
    .replace("__H_S2_KO__", os.environ.get("HS2_KO", os.environ.get("HS2", "")))
    .replace("__H_S2_EN__", os.environ.get("HS2_EN", os.environ.get("HS2", "")))
    .replace("__LBL_SEARCH_KO__", os.environ.get("LBL_SEARCH_KO", ""))
    .replace("__LBL_SEARCH_EN__", os.environ.get("LBL_SEARCH_EN", ""))
    .replace("__PH_SEARCH_KO__", os.environ.get("PH_SEARCH_KO", ""))
    .replace("__PH_SEARCH_EN__", os.environ.get("PH_SEARCH_EN", ""))
    .replace("__PH_SEARCH_INIT__", os.environ.get("PH_SEARCH_INIT", os.environ.get("PH_SEARCH_KO", "")))
    .replace("__LBL_FAV_KO__", os.environ.get("LBL_FAV_KO", ""))
    .replace("__LBL_FAV_EN__", os.environ.get("LBL_FAV_EN", ""))
    .replace("__LBL_PROJECTS_KO__", os.environ.get("LBL_PROJECTS_KO", ""))
    .replace("__LBL_PROJECTS_EN__", os.environ.get("LBL_PROJECTS_EN", ""))
    .replace("__DL_HID_KO__", os.environ.get("DL_HID_KO", ""))
    .replace("__DL_HID_EN__", os.environ.get("DL_HID_EN", ""))
    .replace("__FAV_BOOT_JSON__", fav_json)
    .replace("__ORDER_BOOT_JSON__", order_json)
    .replace("__DASH_STAY_SCRIPT__", js)
    .replace("__DASH_BRAND__", dbrand),
    encoding="utf-8",
)
PY
  else
    log_err "python3 가 필요합니다 (HTML 대시보드)"
    rm -f "$gfile" "$gafile" "$wfile" "$tfile" "$sfile" "$qcfile" "$jfile"
    return 1
  fi
  rm -f "$gfile" "$gafile" "$wfile" "$tfile" "$sfile" "$qcfile" "$jfile"
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
# 브라우저 대시보드(기본 127.0.0.1 바인딩) — 클릭 시 터미널에서 이어 실행

dashboard_write_allowlist_file() {
  local dest="$1"
  discover_workspace_paths > "$dest"
}

# 127.0.0.1:port LISTEN 프로세스 종료 (터미널만 닫고 남은 이전 대시보드 정리)
dashboard_free_listen_port() {
  local port="$1"
  local pids pid
  command_exists lsof || return 0
  pids=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null) || true
  [[ -z "$pids" ]] && return 0
  log_warn "포트 ${port} 사용 중 — 이전 프로세스를 종료합니다."
  for pid in $(printf '%s\n' "$pids" | sort -u); do
    [[ -z "$pid" ]] && continue
    kill "$pid" 2>/dev/null || true
  done
  sleep 0.45
  pids=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null) || true
  if [[ -n "$pids" ]]; then
    for pid in $(printf '%s\n' "$pids" | sort -u); do
      [[ -z "$pid" ]] && continue
      kill -9 "$pid" 2>/dev/null || true
    done
    sleep 0.25
  fi
}

# 임시 파일에 내장 Python 대시보드 서버 기록 후 경로 출력
_dashboard_server_write_py() {
  local out="$1"
  python3 <<'PY' > "$out"
import textwrap, sys
code = r'''
import os, re, secrets, subprocess, sys, threading, time, urllib.parse, json, pathlib
from http.server import HTTPServer, BaseHTTPRequestHandler
import shlex


def _dash_server_binds_all_interfaces():
    b = (os.environ.get("CURSOR_DASH_HOST") or "127.0.0.1").strip()
    return b in ("0.0.0.0", "::")


def _client_ip_trusted_without_origin(ip: str) -> bool:
    """Origin/Referer 가 없을 때: localhost 또는(서버가 0.0.0.0 이면) 사설망 클라이언트만 POST 허용."""
    if not ip:
        return False
    ip = ip.strip().lower()
    if ip in ("127.0.0.1", "::1", "::ffff:127.0.0.1"):
        return True
    if not _dash_server_binds_all_interfaces():
        return False
    if ip.startswith("::ffff:"):
        ip = ip[7:]
    parts = ip.split(".")
    if len(parts) != 4:
        return False
    try:
        a, b, _, _ = (int(x) for x in parts)
    except ValueError:
        return False
    if a == 10:
        return True
    if a == 172 and 16 <= b <= 31:
        return True
    if a == 192 and b == 168:
        return True
    if a == 127:
        return True
    if a == 169 and b == 254:
        return True
    return False


def _coerce_port(pv):
    if pv is None or isinstance(pv, bool):
        return None
    if isinstance(pv, (int, float)):
        try:
            n = int(pv)
        except (TypeError, ValueError):
            return None
        if isinstance(pv, float) and float(pv) != float(int(pv)):
            return None
        return n if 1 <= n <= 65535 else None
    s = str(pv).strip()
    if not s:
        return None
    try:
        n = int(float(s))
    except (ValueError, OverflowError):
        return None
    return n if 1 <= n <= 65535 else None


def _port_from_obj(o):
    if not isinstance(o, dict):
        return None
    for key in ("port", "devPort", "listen", "listenPort"):
        if key not in o:
            continue
        pn = _coerce_port(o.get(key))
        if pn is not None:
            return pn
    return None


def _effective_shell_from_obj(o):
    sh = (o.get("shell") or "").strip().replace("\r", "").replace("\n", " ")
    ex = (o.get("exec") or "").strip().replace("\r", "")
    if ex:
        ep = pathlib.Path(ex).expanduser()
        try:
            try:
                ep = ep.resolve(strict=False)
            except TypeError:
                ep = ep.resolve()
        except OSError:
            try:
                ep = pathlib.Path(os.path.realpath(ex))
            except OSError:
                ep = pathlib.Path(ex)
        return "bash " + shlex.quote(str(ep))
    return sh or None


def _workspace_service_read(path_abs):
    p = pathlib.Path(path_abs).resolve()
    f = pathlib.Path.home() / ".cursor-setup" / "workspace-services.jsonl"
    if not f.is_file():
        return None, None
    try:
        text = f.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None, None

    def _match(ap, target):
        if ap == target:
            return True
        try:
            if ap.exists() and target.exists() and os.path.samefile(ap, target):
                return True
        except OSError:
            pass
        return os.path.normcase(str(ap)) == os.path.normcase(str(target))

    last = None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            continue
        rawp = (o.get("path") or "").replace("\r", "").strip()
        ap = pathlib.Path(rawp).expanduser()
        try:
            try:
                ap = ap.resolve(strict=False)
            except TypeError:
                ap = ap.resolve()
        except OSError:
            ap = pathlib.Path(os.path.realpath(str(rawp)))
        if not _match(ap, p):
            continue
        last = o
    if last is None:
        return None, None
    eff = _effective_shell_from_obj(last)
    po = _port_from_obj(last)
    return (eff, po)


def _bash_invocation_script_path(sh_cmd):
    """'bash /abs/script' 한 줄이면 그 스크립트 실경로, 아니면 None."""
    s = (sh_cmd or "").strip()
    if not s.startswith("bash "):
        return None
    rest = s[5:].strip()
    try:
        parts = shlex.split(rest)
    except ValueError:
        return None
    if not parts:
        return None
    cand = parts[0]
    if cand.startswith("-"):
        cand = None
        for p in parts[1:]:
            if not p.startswith("-"):
                cand = p
                break
        if not cand:
            return None
    exp = os.path.expanduser(cand)
    if not exp.startswith("/"):
        return None
    ep = os.path.realpath(exp)
    if os.path.isfile(ep):
        return ep
    return None


def _path_is_cursor_setup_entrypoint(path):
    """workspace-services 의 exec 가 CursorMobileS setup(또는 스태시 복사본)인지."""
    path = os.path.realpath(path)
    base = os.path.basename(path).lower()
    if base == "setup":
        return True
    stash_dir = os.path.realpath(
        str(pathlib.Path.home() / ".cursor-setup" / "workspace-exec-stash")
    )
    if path.startswith(stash_dir + os.sep) and ("setup" in base or base.endswith("_setup")):
        return True
    return False


def _workspace_setup_script_path(ws_rp):
    """프로젝트 루트의 ./setup 또는 대시보드가 쓰는 CURSOR_SETUP_SCRIPT."""
    ws_rp = os.path.realpath(ws_rp)
    cand = os.path.join(ws_rp, "setup")
    if os.path.isfile(cand):
        return cand
    envp = (os.environ.get("CURSOR_SETUP_SCRIPT") or "").strip()
    if envp and os.path.isfile(envp):
        return os.path.realpath(envp)
    return None


def _lan_ipv4():
    # macOS 기준: 우선순위 인터페이스에서 LAN IPv4 탐색
    for ifn in ("en0", "en1", "en2"):
        try:
            r = subprocess.run(
                ["ipconfig", "getifaddr", ifn],
                capture_output=True,
                text=True,
                timeout=2,
            )
        except Exception:
            continue
        ip = (r.stdout or "").strip()
        if r.returncode == 0 and ip:
            return ip
    return None


def _favorite_paths_filtered():
    dest = pathlib.Path.home() / ".cursor-setup" / "dashboard-favorites.json"
    raw = []
    if dest.is_file():
        try:
            data = json.loads(dest.read_text(encoding="utf-8"))
            if isinstance(data, list):
                raw = [str(x).strip() for x in data if isinstance(x, str) and str(x).strip()]
        except Exception:
            pass
    al = os.environ.get("CURSOR_DASH_ALLOWLIST", "")
    allowed = set()
    if al and os.path.isfile(al):
        with open(al, encoding="utf-8", errors="replace") as fp:
            for line in fp:
                line = line.strip()
                if not line:
                    continue
                try:
                    allowed.add(os.path.realpath(line))
                except OSError:
                    continue
    use_allowlist = len(allowed) > 0
    out = []
    for x in raw:
        try:
            rp = os.path.realpath(x)
        except OSError:
            continue
        if use_allowlist:
            if rp in allowed:
                out.append(rp)
        elif os.path.isdir(rp):
            out.append(rp)
    return out


def _workspace_order_paths_filtered():
    dest = pathlib.Path.home() / ".cursor-setup" / "dashboard-workspace-order.json"
    raw = []
    if dest.is_file():
        try:
            data = json.loads(dest.read_text(encoding="utf-8"))
            if isinstance(data, list):
                raw = [str(x).strip() for x in data if isinstance(x, str) and str(x).strip()]
        except Exception:
            pass
    al = os.environ.get("CURSOR_DASH_ALLOWLIST", "")
    allowed = set()
    if al and os.path.isfile(al):
        with open(al, encoding="utf-8", errors="replace") as fp:
            for line in fp:
                line = line.strip()
                if not line:
                    continue
                try:
                    allowed.add(os.path.realpath(line))
                except OSError:
                    continue
    use_allowlist = len(allowed) > 0
    out = []
    for x in raw:
        try:
            rp = os.path.realpath(x)
        except OSError:
            continue
        if use_allowlist:
            if rp in allowed:
                out.append(rp)
        elif os.path.isdir(rp):
            out.append(rp)
    return out


def _send_json(handler, obj, status=200):
    b = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("Content-Length", str(len(b)))
    handler.end_headers()
    handler.wfile.write(b)


def _ws_path_match_entry_path(rawp, target_resolved):
    rawp = (rawp or "").replace("\r", "").strip()
    ap = pathlib.Path(rawp).expanduser()
    try:
        try:
            ap = ap.resolve(strict=False)
        except TypeError:
            ap = ap.resolve()
    except OSError:
        try:
            ap = pathlib.Path(os.path.realpath(str(rawp)))
        except OSError:
            return False
    if ap == target_resolved:
        return True
    try:
        if ap.exists() and target_resolved.exists() and os.path.samefile(ap, target_resolved):
            return True
    except OSError:
        pass
    return os.path.normcase(str(ap)) == os.path.normcase(str(target_resolved))


def _workspace_services_jsonl_path():
    return pathlib.Path.home() / ".cursor-setup" / "workspace-services.jsonl"


def _workspace_services_upsert_exec(ws_real, exec_abs, port_opt=None):
    f = _workspace_services_jsonl_path()
    f.parent.mkdir(parents=True, exist_ok=True)
    tgt = pathlib.Path(ws_real).resolve()
    lines_kept = []
    last_match = None
    text = f.read_text(encoding="utf-8", errors="replace") if f.is_file() else ""
    for line in text.splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#"):
            lines_kept.append(line)
            continue
        try:
            o = json.loads(raw)
        except json.JSONDecodeError:
            lines_kept.append(line)
            continue
        rp = o.get("path") or ""
        if _ws_path_match_entry_path(rp, tgt):
            last_match = o
            continue
        lines_kept.append(line)
    merged = dict(last_match) if last_match else {}
    merged["path"] = str(tgt)
    merged["exec"] = exec_abs
    if "shell" in merged:
        del merged["shell"]
    if port_opt is not None:
        merged["port"] = int(port_opt)
    lines_kept.append(json.dumps(merged, ensure_ascii=False))
    nf = f.with_name(f.name + ".tmp")
    nf.write_text("\n".join(lines_kept) + "\n", encoding="utf-8")
    nf.replace(f)


def _safe_filename(name):
    name = os.path.basename(name or "")
    name = re.sub(r"[^\w.\- ]+", "_", name).strip("._")[:120]
    return name or "exec-file"


def _stash_exec_file(ws_real, filename, raw):
    ws_path = pathlib.Path(ws_real).resolve()
    try:
        cand = ws_path / pathlib.Path(filename).name
        if cand.is_file() and cand.read_bytes() == raw:
            try:
                suf = cand.suffix.lower()
                if suf in (".command", ".sh", ".tool") or cand.name.endswith(".command"):
                    os.chmod(cand, 0o755)
            except OSError:
                pass
            return str(cand.resolve())
    except OSError:
        pass
    stash = pathlib.Path.home() / ".cursor-setup" / "workspace-exec-stash"
    stash.mkdir(parents=True, exist_ok=True)
    base = _safe_filename(filename)
    ws_tag = _safe_filename(os.path.basename(ws_real))[:40]
    dest = stash / (ws_tag + "_" + base)
    n = 0
    while dest.exists():
        n += 1
        dest = stash / (ws_tag + "_" + str(n) + "_" + base)
    dest.write_bytes(raw)
    try:
        suf = dest.suffix.lower()
        if suf in (".command", ".sh", ".tool") or dest.name.endswith(".command"):
            os.chmod(dest, 0o755)
    except OSError:
        pass
    return str(dest.resolve())


def _multipart_parse(ct, rawb):
    try:
        from io import BytesIO
        from cgi import FieldStorage

        env = {
            "REQUEST_METHOD": "POST",
            "CONTENT_TYPE": ct,
            "CONTENT_LENGTH": str(len(rawb)),
        }
        fs = FieldStorage(fp=BytesIO(rawb), environ=env, keep_blank_values=True)
        fields = {}
        files = {}
        if "path" in fs:
            fields["path"] = fs.getfirst("path") or ""
        if "port" in fs:
            fields["port"] = fs.getfirst("port") or ""
        if "_csrf" in fs:
            fields["_csrf"] = fs.getfirst("_csrf") or ""
        if "file" in fs:
            item = fs["file"]
            if isinstance(item, list):
                item = item[0] if item else None
            if item is not None:
                fn = getattr(item, "filename", None) or ""
                fobj = getattr(item, "file", None)
                blob = fobj.read() if fobj is not None else b""
                if fn or blob:
                    files["file"] = (fn or "upload.bin", blob)
        return fields, files
    except Exception:
        pass
    return _multipart_parse_manual(ct, rawb)


def _multipart_parse_manual(content_type, data):
    fields = {}
    files = {}
    if "multipart/form-data" not in content_type or "boundary=" not in content_type:
        return fields, files
    bd = content_type.split("boundary=", 1)[1].strip()
    if bd.startswith('"') and bd.endswith('"'):
        bd = bd[1:-1]
    bdelim = b"--" + bd.encode("ascii", errors="ignore")
    for part in data.split(bdelim):
        part = part.strip(b"\r\n")
        if not part or part == b"--":
            continue
        if b"\r\n\r\n" not in part:
            continue
        head, body = part.split(b"\r\n\r\n", 1)
        if body.endswith(b"\r\n"):
            body = body[:-2]
        htext = head.decode("latin1", errors="replace")
        name = None
        filename = None
        for hl in htext.split("\r\n"):
            if hl.lower().startswith("content-disposition:"):
                m = re.search(r'name="([^"]+)"', hl)
                if m:
                    name = m.group(1)
                m2 = re.search(r'filename="([^"]*)"', hl)
                if m2:
                    filename = m2.group(1)
        if not name:
            continue
        if filename is not None:
            files[name] = (filename, body)
        else:
            fields[name] = body.decode("utf-8", errors="replace")
    return fields, files


def _mac_choose_file_posix():
    scr = 'POSIX path of (choose file with prompt "실행 파일 선택")'
    try:
        r = subprocess.run(
            ["osascript", "-e", scr],
            capture_output=True,
            text=True,
            timeout=600,
        )
    except subprocess.TimeoutExpired:
        return None
    if r.returncode != 0:
        return None
    p = (r.stdout or "").strip().rstrip("\n")
    return p or None


class DashServer(HTTPServer):
    def __init__(self, server_address, RequestHandlerClass):
        super().__init__(server_address, RequestHandlerClass)
        self.csrf_token = secrets.token_urlsafe(32)


class H(BaseHTTPRequestHandler):
    server_version = "CursorSetupDash/1.0"
    # 부모 프로세스가 이미 HTML 을 썼을 때 첫 GET 에서 중복 --_cursor-setup-write-dash 를 피함
    _regen_cooldown_sec = 2.5
    _last_regen_time = 0.0

    def log_message(self, fmt, *args):
        pass

    def end_headers(self):
        # 로컬 대시보드라도 브라우저 기본 보호 헤더를 넣어 임의 임베드/스니핑을 줄인다.
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; "
            "script-src 'self' 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
        )
        super().end_headers()

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            # 브라우저가 응답 도중 연결을 끊는 경우(새로고침/탭 닫기)는 정상 동작으로 본다.
            return

    def _run_term(self, script_body, auto_close=False):
        if auto_close:
            script_body = script_body + "; exit"
        wrapped = "bash -lc " + shlex.quote(script_body)

        def aq(s):
            return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

        # 앞으로 가져오기 — 대시보드 버튼 후 터미널이 뒤에만 뜨는 문제 완화
        subprocess.run(
            ["osascript", "-e", 'tell application "Terminal" to activate'],
            check=False,
        )
        scpt = "tell application \"Terminal\" to do script " + aq(wrapped)
        subprocess.run(["osascript", "-e", scpt], check=False)

    def _dash_lang_from_headers(self):
        c = self.headers.get("Cookie", "") or ""
        for part in c.split(";"):
            part = part.strip()
            if part.lower().startswith("cursor_dash_lang="):
                v = part.split("=", 1)[1].strip().lower()
                if v == "en":
                    return "en"
        return "ko"

    def _regen(self):
        setup = os.environ["CURSOR_SETUP_SCRIPT"]
        htm = os.environ["CURSOR_DASH_HTML"]
        env = os.environ.copy()
        env["CURSOR_DASH_LANG"] = self._dash_lang_from_headers()
        subprocess.run([setup, "--_cursor-setup-write-dash", htm], env=env, check=False)

    def _request_forces_regen(self):
        """브라우저 강력 새로고침 등 — 쿨다운 무시"""
        cc = (self.headers.get("Cache-Control") or "").lower()
        if "no-cache" in cc or "max-age=0" in cc:
            return True
        pragma = (self.headers.get("Pragma") or "").lower()
        if "no-cache" in pragma:
            return True
        return False

    def _maybe_regen_dashboard(self):
        now = time.time()
        force = self._request_forces_regen()
        if (
            force
            or (now - H._last_regen_time) >= H._regen_cooldown_sec
        ):
            self._regen()
            H._last_regen_time = time.time()

    def _allow_ok(self, path):
        path = os.path.realpath(path)
        if not path or not os.path.isdir(path):
            return False
        al = os.environ.get("CURSOR_DASH_ALLOWLIST", "")
        if not al or not os.path.isfile(al):
            return True
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

    def _post_same_origin_ok(self):
        host = (self.headers.get("Host", "") or "").strip().lower()
        if not host:
            return False
        for hname in ("Origin", "Referer"):
            raw = (self.headers.get(hname, "") or "").strip()
            if not raw:
                continue
            try:
                p = urllib.parse.urlsplit(raw)
            except Exception:
                continue
            if p.scheme not in ("http", "https"):
                continue
            src = (p.netloc or "").strip().lower()
            if src and src == host:
                return True
        # 일부 클라이언트(특히 모바일)는 Origin/Referer 를 안 보냄. LAN 바인딩(0.0.0.0)일 때는 사설망 IP 도 허용.
        ra = ""
        try:
            ra = (self.client_address[0] or "").strip().lower()
        except Exception:
            pass
        return _client_ip_trusted_without_origin(ra)

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

    def _html_origin_denied(self):
        b = (
            "<!DOCTYPE html><html lang=\"ko\"><meta charset=\"utf-8\">"
            "<body style=\"font-family:system-ui;background:#0d1117;color:#e6edf3;padding:24px\">"
            "<p>요청 출처를 확인할 수 없어 거부했습니다. 대시보드 페이지에서 다시 시도해 주세요.</p>"
            "<p><a href=\"/\" style=\"color:#2f81f7\">대시보드로</a></p></body></html>"
        )
        return b.encode("utf-8")

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        p = parsed.path
        if p == "/refresh":
            self._regen()
            H._last_regen_time = time.time()
            self.send_response(302)
            self.send_header("Location", "/")
            self.end_headers()
            return
        if p in ("/", "/index.html"):
            q = urllib.parse.parse_qs(parsed.query or "")
            if "lang" in q and q["lang"]:
                v = (q["lang"][0] or "").lower()
                if v in ("en", "ko"):
                    self.send_response(302)
                    # 쿠키 반영 HTML 이 필요하므로 /refresh 로 한 번 갱신 후 홈으로
                    self.send_header("Location", "/refresh")
                    self.send_header(
                        "Set-Cookie",
                        "cursor_dash_lang=" + v + "; Path=/; Max-Age=31536000; SameSite=Lax; HttpOnly",
                    )
                    self.end_headers()
                    return
            # 직전에 부모가 HTML 을 썼으면 쿨다운 동안 스킵(시작 직후 이중 실행 방지).
            # 오래 지난 뒤·강력 새로고침·footer 의 /refresh 는 최신 상태로 다시 그림.
            self._maybe_regen_dashboard()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            with open(os.environ["CURSOR_DASH_HTML"], "rb") as fp:
                self.wfile.write(fp.read())
            return
        if p == "/favorite-list":
            data = _favorite_paths_filtered()
            body = json.dumps(data, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if p == "/workspace-order-list":
            data = _workspace_order_paths_filtered()
            body = json.dumps(data, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def do_POST(self):
        root = os.environ["CURSOR_SETUP_ROOT"]
        setup = os.environ["CURSOR_SETUP_SCRIPT"]
        p = self.path.split("?", 1)[0]
        if not self._post_same_origin_ok():
            self.send_response(403)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_origin_denied())
            return
        if p == "/set-lang":
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8", errors="replace") if length else ""
            q = urllib.parse.parse_qs(body)
            raw = (q.get("lang") or [""])[0].strip().lower()
            if raw not in ("ko", "en"):
                raw = "ko"
            self.send_response(204)
            self.send_header(
                "Set-Cookie",
                "cursor_dash_lang=" + raw + "; Path=/; Max-Age=31536000; SameSite=Lax; HttpOnly",
            )
            self.end_headers()
            return
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
        if p == "/tunnel-workspace":
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
            rp = os.path.realpath(raw)
            inner = "export CURSOR_SETUP_TUNNEL_WORKSPACE={}; export CURSOR_SETUP_CF_FORCE=1; cd {} && /bin/bash {} --tunnel-only".format(
                shlex.quote(rp),
                shlex.quote(root),
                shlex.quote(setup),
            )
            self._run_term(inner, auto_close=False)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            return
        if p == "/rename-repo":
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
            newn = (q.get("new_name") or [""])[0].strip()
            if not self._allow_ok(raw) or not newn:
                self.send_response(403)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(self._html_denied())
                return
            inner = "/bin/bash {} --rename-repo {} {}".format(
                shlex.quote(setup),
                shlex.quote(raw),
                shlex.quote(newn),
            )
            self._run_term(inner, auto_close=True)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            return
        if p == "/workspace-service-start":
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
            rp = os.path.realpath(raw)
            sh, _po = _workspace_service_read(rp)
            if not sh:
                self.send_response(404)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(
                    (
                        "<!DOCTYPE html><html lang=ko><meta charset=utf-8>"
                        "<body style=background:#0d1117;color:#e6edf3;padding:24px>"
                        "<p>이 폴더에 exec(실행 파일) 또는 shell 이 workspace-services.jsonl 에 없습니다.</p>"
                        "<p><a href=/ style=color:#2f81f7>대시보드</a></p></body></html>"
                    ).encode("utf-8")
                )
                return
            # exec 가 setup(또는 스태시 복사본)만 가리키면 인자 없이 또 HTTP 대시보드를 띄워 포트가 충돌함 → 터미널 --workspace 만 연다.
            invoked = _bash_invocation_script_path(sh)
            if invoked and _path_is_cursor_setup_entrypoint(invoked):
                real_setup = _workspace_setup_script_path(rp)
                if real_setup:
                    sh = "bash " + shlex.quote(real_setup) + " --workspace " + shlex.quote(rp)
                    inner = "cd {} && export CURSOR_SETUP_ROOT={} && {}".format(
                        shlex.quote(rp),
                        shlex.quote(rp),
                        sh,
                    )
                else:
                    inner = (
                        "cd {} && "
                        "export CURSOR_SETUP_ROOT={} HOST=0.0.0.0 VITE_HOST=0.0.0.0 BIND=0.0.0.0 BIND_ADDR=0.0.0.0 "
                        "npm_config_host=0.0.0.0 && {}"
                    ).format(shlex.quote(rp), shlex.quote(rp), sh)
            else:
                # dev server 가 LAN(동일 네트워크)에서도 접근 가능하도록 host 관련 env를 기본 주입
                inner = (
                    "cd {} && "
                    "export CURSOR_SETUP_ROOT={} HOST=0.0.0.0 VITE_HOST=0.0.0.0 BIND=0.0.0.0 BIND_ADDR=0.0.0.0 "
                    "npm_config_host=0.0.0.0 && {}"
                ).format(shlex.quote(rp), shlex.quote(rp), sh)
            self._run_term(inner, auto_close=False)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            return
        if p == "/workspace-service-open":
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
            rp = os.path.realpath(raw)
            _sh, po = _workspace_service_read(rp)
            ov = (q.get("port") or [""])[0].strip()
            if ov.isdigit():
                pn = int(ov)
                if 1 <= pn <= 65535:
                    po = pn
            if not po:
                self.send_response(400)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(
                    (
                        "<!DOCTYPE html><html lang=ko><meta charset=utf-8>"
                        "<body style=background:#0d1117;color:#e6edf3;padding:24px>"
                        "<p>열 포트가 없습니다.</p>"
                        "<p><a href=/ style=color:#2f81f7>대시보드</a></p></body></html>"
                    ).encode("utf-8")
                )
                return
            nw = (q.get("network") or [""])[0].strip() in ("1", "true", "yes", "on")
            host = "127.0.0.1"
            if nw:
                lan = _lan_ipv4()
                if lan:
                    host = lan
            subprocess.Popen(
                ["open", "http://{}:{}/".format(host, int(po))],
                env=os.environ,
                close_fds=True,
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            return
        if p == "/workspace-service-stop":
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
            rp = os.path.realpath(raw)
            _sh, po = _workspace_service_read(rp)
            ov = (q.get("port") or [""])[0].strip()
            if ov.isdigit():
                pn = int(ov)
                if 1 <= pn <= 65535:
                    po = pn
            if not po:
                self.send_response(400)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(
                    (
                        "<!DOCTYPE html><html lang=ko><meta charset=utf-8>"
                        "<body style=background:#0d1117;color:#e6edf3;padding:24px>"
                        "<p>끌 포트가 없습니다. 폼에서 포트를 보내거나 jsonl 에 port 를 적어 주세요.</p>"
                        "<p><a href=/ style=color:#2f81f7>대시보드</a></p></body></html>"
                    ).encode("utf-8")
                )
                return
            inner = (
                "p=$(lsof -nP -tiTCP:%d -sTCP:LISTEN 2>/dev/null); "
                '[[ -n "$p" ]] && kill $p 2>/dev/null; sleep 0.4; '
                "p=$(lsof -nP -tiTCP:%d -sTCP:LISTEN 2>/dev/null); "
                '[[ -n "$p" ]] && kill -9 $p 2>/dev/null; true'
            ) % (po, po)
            self._run_term(inner, auto_close=True)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            return
        if p == "/workspace-exec-choose":
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
                _send_json(self, {"ok": False, "err": "허용되지 않은 폴더"}, 403)
                return
            if sys.platform != "darwin":
                _send_json(
                    self,
                    {"ok": False, "err": "Finder 선택은 macOS 전용입니다 · 찾아보기로 올리세요"},
                    400,
                )
                return
            rp = os.path.realpath(raw)
            pv = (q.get("port") or [""])[0].strip()
            po = int(pv) if pv.isdigit() and 1 <= int(pv) <= 65535 else None
            chosen = _mac_choose_file_posix()
            if not chosen:
                _send_json(self, {"ok": False, "err": "취소됨"}, 200)
                return
            try:
                cpath = os.path.realpath(chosen)
            except OSError:
                _send_json(self, {"ok": False, "err": "경로 오류"}, 400)
                return
            if not os.path.isfile(cpath):
                _send_json(self, {"ok": False, "err": "파일이 아닙니다"}, 400)
                return
            try:
                _workspace_services_upsert_exec(rp, cpath, po)
            except OSError as ex:
                _send_json(self, {"ok": False, "err": str(ex)}, 500)
                return
            _send_json(self, {"ok": True, "exec": cpath}, 200)
            return
        if p == "/workspace-exec-upload":
            allow_path = os.environ.get("CURSOR_DASH_ALLOWLIST", "")
            if allow_path:
                subprocess.run(
                    [setup, "--_cursor-setup-write-allowlist", allow_path],
                    check=False,
                )
            ct = self.headers.get("Content-Type", "")
            if "multipart/form-data" not in ct:
                _send_json(self, {"ok": False, "err": "multipart/form-data 가 필요합니다"}, 400)
                return
            length = int(self.headers.get("Content-Length", "0"))
            rawb = self.rfile.read(length)
            fields, files = _multipart_parse(ct, rawb)
            raw = (fields.get("path") or "").strip()
            if not self._allow_ok(raw):
                _send_json(self, {"ok": False, "err": "허용되지 않은 폴더"}, 403)
                return
            rp = os.path.realpath(raw)
            fl = files.get("file")
            if not fl:
                _send_json(self, {"ok": False, "err": "파일이 없습니다"}, 400)
                return
            fname, fbody = fl
            if len(fbody) > 12 * 1024 * 1024:
                _send_json(self, {"ok": False, "err": "12MB 이하만 가능합니다"}, 400)
                return
            pv = (fields.get("port") or "").strip()
            po = int(pv) if pv.isdigit() and 1 <= int(pv) <= 65535 else None
            try:
                dest = _stash_exec_file(rp, fname, fbody)
                _workspace_services_upsert_exec(rp, dest, po)
            except OSError as ex:
                _send_json(self, {"ok": False, "err": str(ex)}, 500)
                return
            _send_json(self, {"ok": True, "exec": dest}, 200)
            return
        if p == "/favorite-save":
            al = os.environ.get("CURSOR_DASH_ALLOWLIST", "")
            allowed = set()
            if al and os.path.isfile(al):
                with open(al, encoding="utf-8", errors="replace") as fp:
                    for line in fp:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            allowed.add(os.path.realpath(line))
                        except OSError:
                            continue
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8", errors="replace")
            try:
                arr = json.loads(body)
            except json.JSONDecodeError:
                self.send_response(400)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                return
            if not isinstance(arr, list):
                self.send_response(400)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                return
            use_allowlist = len(allowed) > 0
            clean = []
            for x in arr:
                if not isinstance(x, str):
                    continue
                try:
                    rp = os.path.realpath(x.strip())
                except OSError:
                    continue
                if use_allowlist:
                    if rp in allowed:
                        clean.append(rp)
                elif os.path.isdir(rp):
                    clean.append(rp)
            dest = pathlib.Path.home() / ".cursor-setup" / "dashboard-favorites.json"
            try:
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text(json.dumps(clean, ensure_ascii=False), encoding="utf-8")
            except OSError:
                self.send_response(500)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                return
            self.send_response(204)
            self.end_headers()
            return
        if p == "/workspace-order-save":
            al = os.environ.get("CURSOR_DASH_ALLOWLIST", "")
            allowed = set()
            if al and os.path.isfile(al):
                with open(al, encoding="utf-8", errors="replace") as fp:
                    for line in fp:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            allowed.add(os.path.realpath(line))
                        except OSError:
                            continue
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8", errors="replace")
            try:
                arr = json.loads(body)
            except json.JSONDecodeError:
                self.send_response(400)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                return
            if not isinstance(arr, list):
                self.send_response(400)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                return
            use_allowlist = len(allowed) > 0
            clean = []
            seen = set()
            for x in arr:
                if not isinstance(x, str):
                    continue
                try:
                    rp = os.path.realpath(x.strip())
                except OSError:
                    continue
                if rp in seen:
                    continue
                if use_allowlist:
                    if rp in allowed:
                        clean.append(rp)
                        seen.add(rp)
                elif os.path.isdir(rp):
                    clean.append(rp)
                    seen.add(rp)
            dest = pathlib.Path.home() / ".cursor-setup" / "dashboard-workspace-order.json"
            try:
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text(json.dumps(clean, ensure_ascii=False), encoding="utf-8")
            except OSError:
                self.send_response(500)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                return
            self.send_response(204)
            self.end_headers()
            return
        if p == "/dashboard-stop":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())

            def _stop():
                time.sleep(0.2)
                self.server.shutdown()

            threading.Thread(target=_stop, daemon=True).start()
            return
        if p == "/launch-setup":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            inner = "cd {} && /bin/bash {} --full-wizard".format(
                shlex.quote(root),
                shlex.quote(setup),
            )
            self._run_term(inner, auto_close=False)
            return
        if p == "/workspace-add-folder":
            ck = (self.headers.get("Cookie", "") or "").replace(" ", "")
            pr_en = "cursor_dash_lang=en" in ck
            pr = (
                "Choose a project folder to add to the list"
                if pr_en
                else "추가할 프로젝트 폴더를 선택하세요"
            )
            scr = 'POSIX path of (choose folder with prompt "' + pr.replace("\\", "\\\\").replace('"', '\\"') + '")'
            inner = (
                "mkdir -p \"$HOME/.cursor-setup\" && f=\"$HOME/.cursor-setup/workspaces.txt\" && touch \"$f\" && "
                "p=$(osascript -e "
                + shlex.quote(scr)
                + " 2>/dev/null) && "
                "if [[ -n \"$p\" ]]; then r=$(cd \"$p\" 2>/dev/null && pwd -P); "
                "[[ -n \"$r\" ]] && (grep -Fxq \"$r\" \"$f\" 2>/dev/null || echo \"$r\" >> \"$f\"); fi"
            )
            self._run_term(inner, auto_close=True)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            return
        if p.startswith("/action/"):
            uid = os.getuid()
            ag = os.path.expanduser("~/.local/bin/agent")
            agq = shlex.quote(ag)
            if p == "/action/open-user-workspaces":
                ws = pathlib.Path.home() / ".cursor-setup" / "workspaces.txt"
                try:
                    ws.parent.mkdir(parents=True, exist_ok=True)
                    ws.touch(exist_ok=True)
                except OSError:
                    pass
                inner = "open -e " + shlex.quote(str(ws))
                self._run_term(inner, auto_close=True)
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(self._html_ok())
                return
            if p == "/action/open-user-services-jsonl":
                jf = pathlib.Path.home() / ".cursor-setup" / "workspace-services.jsonl"
                try:
                    jf.parent.mkdir(parents=True, exist_ok=True)
                    jf.touch(exist_ok=True)
                except OSError:
                    pass
                inner = "open -e " + shlex.quote(str(jf))
                self._run_term(inner, auto_close=True)
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(self._html_ok())
                return
            if p == "/action/open-cloudflared-config":
                cf = pathlib.Path.home() / ".cloudflared" / "config.yml"
                try:
                    cf.parent.mkdir(parents=True, exist_ok=True)
                    cf.touch(exist_ok=True)
                except OSError:
                    pass
                inner = "open -e " + shlex.quote(str(cf))
                self._run_term(inner, auto_close=True)
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(self._html_ok())
                return
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
                "/action/worker-kickstart": (
                    "echo '=== Cursor agent workers ==='; echo ''; "
                    "uid=$(id -u); n=0; "
                    "shopt -s nullglob; "
                    "for p in \"$HOME/Library/LaunchAgents\"/com.cursor.agent.worker.plist "
                    "\"$HOME/Library/LaunchAgents\"/com.cursor.agent.worker.*.plist; do "
                    '[[ -f "$p" ]] || continue; '
                    'lb=$(plutil -extract Label raw "$p" 2>/dev/null) || continue; '
                    'echo "-- $lb"; '
                    'if launchctl kickstart -k "gui/$uid/$lb" 2>&1; then echo "   OK"; else echo "   FAILED"; fi; '
                    "n=$((n+1)); done; shopt -u nullglob; "
                    "if [[ \"$n\" -eq 0 ]]; then echo '(No worker plists — run Set up this folder on each project.)'; fi; "
                    "echo ''; echo 'Closing in 4 seconds...'; sleep 4"
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
    host = os.environ.get("CURSOR_DASH_HOST", "127.0.0.1")
    try:
        H._regen_cooldown_sec = float(os.environ.get("CURSOR_DASH_REGEN_COOLDOWN_SEC", "2.5"))
    except (TypeError, ValueError):
        H._regen_cooldown_sec = 2.5
    if H._regen_cooldown_sec < 0:
        H._regen_cooldown_sec = 0.0
    H._last_regen_time = time.time()
    httpd = DashServer((host, port), H)
    shown_host = host
    if host in ("0.0.0.0", "::"):
        shown_host = "127.0.0.1"
    print("[정보] 대시보드 http://{}:{}/ (종료: Ctrl+C)".format(shown_host, port), flush=True)
    if host in ("0.0.0.0", "::"):
        lip = _lan_ipv4()
        if lip:
            print("[정보] LAN 접근 주소: http://{}:{}/".format(lip, port), flush=True)
    httpd.serve_forever()

if __name__ == "__main__":
    main()
'''
sys.stdout.write(textwrap.dedent(code))
PY
}

dashboard_server_main_blocking() {
  local root="${CURSOR_SETUP_ROOT:-$ROOT}"
  local port html allow py preferred bind_host
  if ! command_exists python3; then
    log_err "대시보드 서버에 python3 가 필요합니다."
    return 1
  fi
  # ~/.cursor-setup/dashboard-bind-lan 파일이 있으면 매번 LAN 바인딩(0.0.0.0) — CURSOR_DASH_HOST 가 없을 때만
  if [[ -z "${CURSOR_DASH_HOST:-}" && "${CURSOR_DASH_LAN:-0}" != "1" && -f "${HOME}/.cursor-setup/dashboard-bind-lan" ]]; then
    CURSOR_DASH_LAN=1
  fi
  preferred="${CURSOR_DASH_PORT:-58741}"
  if [[ -n "${CURSOR_DASH_HOST:-}" ]]; then
    bind_host="$CURSOR_DASH_HOST"
  elif [[ "${CURSOR_DASH_LAN:-0}" == "1" ]]; then
    bind_host="0.0.0.0"
  else
    bind_host="127.0.0.1"
  fi
  dashboard_free_listen_port "$preferred"
  if python3 -c "import socket; s=socket.socket(); s.bind(('$bind_host', int('$preferred'))); s.close()" 2>/dev/null; then
    port="$preferred"
  else
    port="$(python3 -c "import socket; s=socket.socket(); s.bind(('$bind_host',0)); print(s.getsockname()[1]); s.close()")"
    log_info "포트 ${preferred} 을(를) 비울 수 없어 임시 포트 ${port} 로 뜹니다."
    log_info "접속 주소는 아래 http://…:${port}/ 만 쓰면 됩니다. ${preferred} 는 이전 대시보드 등이 붙잡고 있을 수 있습니다."
  fi
  html="$(mktemp).html"
  allow="$(mktemp)"
  py="$(mktemp).py"
  dashboard_write_allowlist_file "$allow"
  local setup_cmd="$root/setup"
  [[ -f "$setup_cmd" ]] || setup_cmd="$root/MacMini-Cursor-Setup.command"
  export CURSOR_SETUP_EXEC_HINT="$setup_cmd"
  # HTML 생성 시 사이드바에 LAN 링크·바인드 정보를 쓰려면 이 시점에 포트·호스트가 있어야 함
  export CURSOR_DASH_PORT="$port"
  export CURSOR_DASH_HOST="$bind_host"
  "$setup_cmd" --_cursor-setup-write-dash "$html" || {
    log_err "대시보드 HTML 생성 실패"
    rm -f "$allow" "$py"
    return 1
  }
  _dashboard_server_write_py "$py"
  chmod +x "$py" 2>/dev/null || true

  export CURSOR_DASH_HTML="$html"
  export CURSOR_DASH_ALLOWLIST="$allow"
  export CURSOR_SETUP_SCRIPT="$setup_cmd"
  export CURSOR_SETUP_ROOT="$root"

  _dashboard_cleanup() {
    rm -f "$html" "$allow" "$py" 2>/dev/null || true
  }
  trap '_dashboard_cleanup' EXIT INT TERM

  if [[ "${CURSOR_DASH_OPEN_BROWSER:-1}" != "0" ]]; then
    ( sleep 0.2 && open "http://127.0.0.1:${port}/" ) &
  fi
  if [[ "$bind_host" != "127.0.0.1" && "$bind_host" != "::1" && "$bind_host" != "localhost" ]]; then
    log_warn "대시보드가 LAN 에 노출됩니다 (${bind_host}:${port}). 신뢰 네트워크에서만 사용하세요."
  fi
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
  local wd="${1:-}"
  [[ -z "$wd" ]] && declare -F cursor_setup_default_workspace_dir >/dev/null 2>&1 && wd="$(cursor_setup_default_workspace_dir)"
  [[ -z "$wd" ]] && wd="$HOME"
  if declare -F status_dashboard_open_html >/dev/null 2>&1; then
    status_dashboard_open_html >/dev/null 2>&1 || log_warn "HTML 대시보드를 열지 못했어요 (python3 확인)."
  fi

  local gtitle="${CURSOR_DASH_BRAND:-Cursor 셋업}"
  local gt_esc
  gt_esc=$(printf '%s' "$gtitle" | sed 's/"/\\"/g')
  local out ec
  out=$(osascript -e "display dialog \"브라우저에 상태 대시보드를 열었어요. (저장소마다 카드가 나뉩니다)\" with title \"$gt_esc\" buttons {\"종료\", \"터미널 로그\", \"설정\"} default button \"설정\" with icon note" 2>/dev/null) || true
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
  local gtitle="${CURSOR_DASH_BRAND:-Cursor 셋업}"
  local gt_esc
  gt_esc=$(printf '%s' "$gtitle" | sed 's/"/\\"/g')
  out=$(osascript -e "display dialog \"$b\" with title \"$gt_esc\" buttons {\"글자만\", \"그림(창)\"} default button \"그림(창)\" with icon note" 2>/dev/null) || true
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

# 작업 폴더 basename → gh repo create 기본값 (GitHub Desktop 등이 붙인 접두·중복 제거)
github_sanitize_repo_basename() {
  local b="$1"
  [[ -z "$b" || "$b" == "." || "$b" == ".." ]] && {
    printf '%s\n' "repo"
    return
  }

  b=$(printf '%s' "$b" | sed -e 's/^[-_.[:space:]]\{1,\}//' -e 's/[-_.[:space:]]\{1,\}$//' -e 's/-\{2,\}/-/g')
  b=$(printf '%s' "$b" | tr '[:space:]' '-')

  local pl
  pl=$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')
  # GitHub Desktop 등: "GitHub-foo-bar…" 만 접두 제거 (github-io 같은 한 덩어리는 유지)
  if [[ "$pl" == github-*-* ]]; then
    b="${b:7}"
    b=$(printf '%s' "$b" | sed -e 's/^[-_.[:space:]]\{1,\}//')
  fi

  # bash 3.2 는 [[ =~ ]] 역참조 미지원 → 토큰으로 중복 축약 (foo-bar-bar → foo-bar, X-X → X)
  while [[ "$b" == *-* ]]; do
    local r p pr
    r="${b##*-}"
    p="${b%-*}"
    if [[ -n "$r" && "$p" == "$r" ]]; then
      b="$r"
      continue
    fi
    if [[ "$p" == *-* ]]; then
      pr="${p##*-}"
      if [[ "$pr" == "$r" ]]; then
        b="$p"
        continue
      fi
    fi
    break
  done

  b=$(printf '%s' "$b" | sed -e 's/[^a-zA-Z0-9._-]/-/g' -e 's/-\{2,\}/-/g' -e 's/^[-]*//' -e 's/[-]*$//')

  [[ -z "$b" ]] && b="repo"
  if [[ ${#b} -gt 100 ]]; then
    b="${b:0:100}"
    b="${b%-}"
  fi
  printf '%s\n' "$b"
}

# GitHub API/원격에 쓸 저장소 이름 (영숫자 . - _)
github_validate_repo_name() {
  local n="$1"
  [[ ${#n} -ge 1 && ${#n} -le 100 ]] || return 1
  [[ "$n" =~ ^[a-zA-Z0-9._-]+$ ]] || return 1
  return 0
}

# origin URL → 레포 이름만 (github.com HTTPS/SSH). 실패 시 비어 있고 exit 1
github_repo_name_from_remote_url() {
  local u="$1"
  [[ -z "$u" || "$u" == "origin 없음" ]] && return 1
  u="${u%%\?*}"
  u="${u%%\#*}"
  u="${u//https:\/\/www\./https://}"
  u="${u%.git}"
  u="${u%.GIT}"
  if [[ "$u" =~ github\.com[/:]([^/]+)/([^/?#]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

github_main() {
  log_info "[2/5] Git · GitHub"

  local default_work="${CURSOR_SETUP_DEFAULT_WORKSPACE:-}"
  [[ -z "$default_work" ]] && default_work="${CURSOR_SETUP_ROOT:-$HOME}"
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

  local raw_base default_repo
  raw_base="$(basename "$CURSOR_SETUP_WORK_DIR")"
  default_repo="$(github_sanitize_repo_basename "$raw_base")"
  if [[ "$default_repo" != "$raw_base" ]]; then
    log_info "저장소 이름 기본값 정리: $default_repo (폴더: $raw_base)"
  fi
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

# --- scripts/lib/cloudflare_tunnel.sh.sh ---
# Cloudflare Tunnel (선택)

# 번들(.command)에서는 앞선 청크에 정의됨. 저장소에서 --tunnel-only 만 쓸 때만 소스.
cloudflare_tunnel_ensure_workspace_helpers() {
  declare -F workspace_service_config_line >/dev/null 2>&1 && return 0
  local r="${CURSOR_SETUP_ROOT:-}"
  if [[ -z "$r" && -n "${BASH_SOURCE[0]:-}" ]]; then
    r="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd 2>/dev/null)" || r=""
  fi
  [[ -n "$r" && -f "$r/scripts/lib/workspace_services.sh" ]] || return 0
  # shellcheck disable=SC1091
  source "$r/scripts/lib/workspace_services.sh"
}

cloudflare_tunnel_port_from_workspace_json() {
  local wd="${1:-}"
  [[ -n "$wd" ]] || return 1
  cloudflare_tunnel_ensure_workspace_helpers
  declare -F workspace_service_config_line >/dev/null 2>&1 || return 1
  local js
  js="$(workspace_service_config_line "$wd")"
  printf '%s\n' "$js" | python3 -c "import sys,json; d=json.load(sys.stdin); p=(d.get('port') or '').strip(); print(p, end='')"
}

# workspace-services → 기존 config.yml 첫 ingress → 8080
cloudflare_tunnel_default_local_port() {
  local wd="${1:-}"
  local from_ws from_cfg cf_line tid host svc
  from_ws="$(cloudflare_tunnel_port_from_workspace_json "$wd" 2>/dev/null || true)"
  [[ -n "$from_ws" ]] && {
    printf '%s\n' "$from_ws"
    return 0
  }
  if cf_line=$(parse_cf_config_summary 2>/dev/null); then
    IFS=$'\t' read -r tid host svc <<<"$cf_line"
    from_cfg="$(printf '%s' "$svc" | sed -nE 's|^[a-zA-Z]+://[^/:]+:([0-9]+).*|\1|p')"
  fi
  [[ -n "$from_cfg" ]] && {
    printf '%s\n' "$from_cfg"
    return 0
  }
  printf '%s\n' "8080"
}

cloudflare_tunnel_default_public_hostname() {
  local cf_line tid host svc
  cf_line=$(parse_cf_config_summary 2>/dev/null) || return 1
  IFS=$'\t' read -r tid host svc <<<"$cf_line"
  [[ -n "$host" && "$host" != "?" ]] && printf '%s\n' "$host"
}

cloudflare_tunnel_print_current_situation() {
  local wd="${1:-}"
  log_info "──────── Cloudflare Tunnel · 여기서는 앞단만: 공개 주소 → 맥의 로컬 포트 ────────"
  log_info "【지금 맥에 저장된 설정】 ~/.cloudflared/config.yml"
  if [[ -f "$HOME/.cloudflared/config.yml" ]]; then
    local any=0 h s
    while IFS=$'\t' read -r h s || [[ -n "$h" ]]; do
      [[ -z "$h" ]] && continue
      any=1
      log_info "  · 인터넷 주소  $h  →  맥  $s"
    done < <(cloudflare_config_ingress_pairs)
    if [[ "$any" == "0" ]]; then
      local cf_line tid host svc
      if cf_line=$(parse_cf_config_summary 2>/dev/null); then
        IFS=$'\t' read -r tid host svc <<<"$cf_line"
        log_info "  · 터널 ID: ${tid:-?}"
        log_info "  · 첫 라우트: ${host:-?} → ${svc:-?}"
      else
        log_info "  (파일은 있으나 ingress 를 파싱하지 못함)"
      fi
    fi
  else
    log_info "  없음 — 아직 config.yml 이 없습니다"
  fi

  log_info "【포트 기본값 출처】 workspace-services.jsonl (이 작업 폴더) → 없으면 위 config 의 로컬 포트 → 8080"
  cloudflare_tunnel_ensure_workspace_helpers
  local ph=""
  if declare -F workspace_service_config_line >/dev/null 2>&1; then
    ph="$(cloudflare_tunnel_port_from_workspace_json "$wd" 2>/dev/null || true)"
  fi
  if [[ -n "$ph" ]]; then
    log_info "  이 폴더에 등록된 포트: $ph (아래 질문의 기본값으로 넣습니다)"
  else
    log_info "  이 폴더에 등록된 포트 없음 — 아래에서 숫자로 지정"
  fi
}

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

  cloudflare_tunnel_print_current_situation "$work_dir"

  if [[ "${CURSOR_SETUP_CF_FORCE:-0}" != "1" ]] && cloudflared_cert_ok && [[ -f "$HOME/.cloudflared/config.yml" ]]; then
    log_info "위 설정을 그대로 둡니다 → Tunnel 단계 생략"
    log_info "다시 짜려면: CURSOR_SETUP_CF_FORCE=1 ./setup … 또는 --with-cloudflare 전에 FORCE=1"
    return 0
  fi

  log_info "【이번에 새로 적용할 내용】 Cloudflare 계정 로그인 후, 터널을 만들고 ‘바깥 주소 → 맥 포트’ 한 줄을 씁니다."
  log_warn "Tunnel ingress 의 service 는 항상 http://127.0.0.1:<포트> 만 씁니다. 공인 IP(예: 218.x)나 Zero Trust「Published application」에 공인 IP:포트를 넣는 방식은 이 흐름과 다르며, 맥 방화벽·공유기 없이는 외부에서 안 열립니다."
  log_warn "~/.cloudflared/*.json 과 config.yml 은 GitHub 에 올리지 마세요. (레포의 ./scripts/git-safe-verify.sh 로 추적 여부를 검사할 수 있습니다.)"

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
  tunnel_name="$(prompt_with_default "Cloudflare 터널 이름 (계정·목록에 보이는 이름)" "autocrf-mini")"

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

  log_info "【앞단 라우팅】 방문자가 볼 주소(호스트)와, 맥에서 이미 떠 있는 앱의 포트만 맞추면 됩니다."

  local def_host="app.example.com" h_try=""
  h_try="$(cloudflare_tunnel_default_public_hostname 2>/dev/null)" || true
  [[ -n "$h_try" ]] && def_host="$h_try"

  local hostname
  hostname="$(prompt_with_default "인터넷에서 열릴 호스트 (예: app.example.com)" "$def_host")"

  if prompt_yn "이 호스트를 터널에 DNS 로 자동 연결할까요? (도메인이 Cloudflare 에 있을 때)" "y"; then
    cloudflared tunnel route dns "$tunnel_name" "$hostname" || log_warn "route dns 실패 — 웹에서 수동 가능"
  fi

  local port_def
  port_def="$(cloudflare_tunnel_default_local_port "$work_dir")"
  local port
  port="$(prompt_with_default "맥 로컬 포트 (앱이 LISTEN 중인 포트 — 위에서 안내한 기본값)" "$port_def")"

  log_info "적용 예: https://${hostname}  →  http://127.0.0.1:${port}  (TLS·터널은 cloudflared 가 처리)"

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
  local wd="${CURSOR_SETUP_TUNNEL_WORKSPACE:-}"
  [[ -z "$wd" && -n "${1:-}" ]] && wd="$1"
  [[ -z "$wd" ]] && wd="${CURSOR_SETUP_DEFAULT_WORKSPACE:-}"
  [[ -z "$wd" ]] && declare -F cursor_setup_default_workspace_dir >/dev/null 2>&1 && wd="$(cursor_setup_default_workspace_dir)"
  [[ -z "$wd" ]] && wd="."
  wd="$(expand_tilde "$wd")"
  local wd_res
  wd_res="$(cd "$wd" 2>/dev/null && pwd -P)" || true
  [[ -n "$wd_res" ]] && wd="$wd_res"
  cloudflare_tunnel_main "$wd"
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
	<string>__LABEL__</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>__WRAP_SCRIPT__</string>
		<string>__WORK_DIR__</string>
		<string>__AGENT_BIN__</string>
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

cursor_agent_worker_entry_template() {
  cat <<'ENTRY_TMPL_EOF'
#!/bin/bash
# LaunchAgent 가 인자로 작업 폴더·agent 경로를 넘깁니다. 기동 전 원격과 맞춤(fetch + ff-only pull).
set -euo pipefail
WORK_DIR="${1:?}"
AGENT_BIN="${2:?}"
cd "$WORK_DIR" || exit 1
export PATH="$HOME/.local/bin:$PATH"
if [[ -d .git ]]; then
  git fetch origin 2>/dev/null || true
  cur=$(git branch --show-current 2>/dev/null || true)
  if [[ -n "$cur" ]]; then
    if git rev-parse '@{u}' >/dev/null 2>&1; then
      git pull --ff-only 2>/dev/null || true
    elif git rev-parse "refs/remotes/origin/$cur" >/dev/null 2>&1; then
      git pull --ff-only origin "$cur" 2>/dev/null || true
    fi
  fi
fi
exec "$AGENT_BIN" worker start
ENTRY_TMPL_EOF
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
  --status [폴더]     터미널에 상태만 (기본: CURSOR_SETUP_DEFAULT_WORKSPACE 또는 이 저장소 루트)
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
        _st_dir="${CURSOR_SETUP_DEFAULT_WORKSPACE:-$CURSOR_SETUP_ROOT}"
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
