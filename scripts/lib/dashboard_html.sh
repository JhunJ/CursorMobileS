#!/usr/bin/env bash
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

  if [[ -f "$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist" ]]; then
    local pwd pwdb
    pwd=$(plutil_string "$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist" WorkingDirectory)
    pwdb=$(basename "$(expand_tilde "$pwd")")
    if launchagent_running "com.cursor.agent.worker"; then
      _dashboard_card "ok" "$(_d "Cursor 워커 (전역)" "Cursor worker (global)")" "$(_d "LaunchAgent 동작 중" "LaunchAgent running")" "$(_d "폴더" "Folder") · $pwdb"
    else
      _dashboard_card "warn" "$(_d "Cursor 워커 (전역)" "Cursor worker (global)")" "$(_d "plist 있음 · 지금 멈춤" "plist present · stopped")" "$(_d "폴더" "Folder") · $pwdb"
    fi
  elif cursor_worker_process_running; then
    _dashboard_card "warn" "$(_d "Cursor 워커 (전역)" "Cursor worker (global)")" "$(_d "프로세스만 실행 중" "Process only")" "$(_d "LaunchAgent 없음" "No LaunchAgent")"
  else
    _dashboard_card "bad" "$(_d "Cursor 워커 (전역)" "Cursor worker (global)")" "$(_d "미등록" "Not registered")" ""
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
  local plist pw
  plist="$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist"
  if [[ -f "$plist" ]]; then
    pw=$(plutil_string "$plist" WorkingDirectory)
    if dirs_same "$pw" "$ws"; then
      if ! launchagent_running "com.cursor.agent.worker" && ! cursor_worker_process_running; then
        hints="${hints}${sep}$(_d "워커 기동" "Start worker")"
        sep=" · "
      fi
    else
      local _wres _wbn
      _wres=$(expand_tilde "$pw")
      _wres=$(cd "$_wres" 2>/dev/null && pwd -P || printf '%s' "$_wres")
      _wbn=$(basename "$_wres")
      # 워커가 이미 떠 있으면 «다른 폴더»는 정상(멀티 프로젝트)일 수 있음 → 상단 미완료 배너에 넣지 않음
      if launchagent_running "com.cursor.agent.worker" || cursor_worker_process_running; then
        :
      else
        hints="${hints}${sep}$(_d "워커가 「${_wbn}」를 가리킴 — 이 폴더로 설정" "Worker points at 「${_wbn}」 — configure for this folder")"
        sep=" · "
      fi
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

# 접힌 요약 줄: Tunnel · GitHub · Agent · 워커 네 가지 동그라미
dashboard_quick_check_summary_html() {
  local d_cf d_gh d_ag d_wk
  if cloudflare_looks_connected; then d_cf=ok; else d_cf=bad; fi
  if github_cli_logged_in; then d_gh=ok; else d_gh=bad; fi
  if [[ -x "$HOME/.local/bin/agent" ]]; then
    if cursor_agent_state_file_present; then d_ag=ok; else d_ag=warn; fi
  else
    d_ag=bad
  fi
  if [[ -f "$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist" ]]; then
    if launchagent_running "com.cursor.agent.worker"; then d_wk=ok; else d_wk=warn; fi
  elif cursor_worker_process_running; then
    d_wk=warn
  else
    d_wk=bad
  fi
  printf '      <span class="qc-mid">\n'
  printf '        <span class="qc-dots" role="presentation" aria-hidden="true">\n'
  printf '          <span class="dot %s" title="%s"></span>\n' "$d_cf" "$(_d "Tunnel" "Tunnel")"
  printf '          <span class="dot %s" title="%s"></span>\n' "$d_gh" "$(_d "GitHub" "GitHub")"
  printf '          <span class="dot %s" title="%s"></span>\n' "$d_ag" "$(_d "Agent CLI" "Agent CLI")"
  printf '          <span class="dot %s" title="%s"></span>\n' "$d_wk" "$(_d "워커" "Worker")"
  printf '        </span>\n'
  printf '        <span class="qc-legend" aria-hidden="true">%s · GitHub · %s · %s</span>\n' \
    "$(_d "터널" "Tunnel")" "$(_d "Agent CLI" "Agent CLI")" "$(_d "워커" "Worker")"
  printf '      </span>\n'
  printf '      <span class="qc-title">%s</span>\n' "$(_d "빠른 점검" "Quick check")"
  printf '      <span class="qc-chev" aria-hidden="true">▸</span>\n'
}

# $1 출력 파일 — 빠른 점검 요약을 KO/EN 두 벌 넣어 언어 전환 시 전체 HTML 재생성 없이 바꿀 수 있게 함
_dashboard_quick_check_dual_to_file() {
  local dest="${1:?}"
  {
    printf '<div class="dash-locale qc-summary-locale"'
    is_dash_en && printf ' hidden'
    printf ' data-dash-locale="ko">\n'
    CURSOR_DASH_LANG=ko dashboard_quick_check_summary_html
    printf '</div>\n'
    printf '<div class="dash-locale qc-summary-locale"'
    is_dash_en || printf ' hidden'
    printf ' data-dash-locale="en">\n'
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
  printf '<p class="sidebar-tag">%s</p>\n' "$(_d "위에서부터 순서대로 진행하세요." "Go through the steps from the top.")"
  printf '<div class="sidebar-steps">\n'
  printf '      <div class="step-card">\n'
  printf '        <div class="step-label"><span class="step-num">%s</span>%s</div>\n' "$_sn" "$(_d "개발·프로젝트 폴더" "Dev & project folders")"
  printf '        <p class="step-desc">%s</p>\n' "$(_d "Finder로 상위 폴더를 추가합니다. workspaces.txt에는 한 줄에 경로 하나 — 여러 상위 폴더를 쓰려면 줄을 더 적으면 됩니다." "Add parent folders in Finder. In workspaces.txt use one path per line — add more lines for multiple parent folders.")"
  printf '        <form method="post" action="/workspace-add-folder" class="choice-form"><button type="submit" class="btn-choice"><span class="btn-choice-main"><span>%s</span><span class="btn-choice-sub">%s</span></span><span class="chev">›</span></button></form>\n' "$(_d "Finder에서 폴더 추가" "Add folder in Finder")" "workspaces.txt"
  printf '        <details class="step-advanced">\n'
  printf '          <summary>%s</summary>\n' "$(_d "고급: 파일로 편집" "Advanced: edit config files")"
  printf '        <form method="post" action="/action/open-user-workspaces" class="choice-form"><button type="submit" class="btn-choice"><span class="btn-choice-main"><span>%s</span><span class="btn-choice-sub">workspaces.txt</span></span><span class="chev">›</span></button></form>\n' "$(_d "폴더 목록 편집" "Edit folder list")"
  printf '        <form method="post" action="/action/open-user-services-jsonl" class="choice-form"><button type="submit" class="btn-choice"><span class="btn-choice-main"><span>%s</span><span class="btn-choice-sub">workspace-services.jsonl</span></span><span class="chev">›</span></button></form>\n' "$(_d "실행·포트" "Run / port")"
  printf '        <form method="post" action="/action/open-cloudflared-config" class="choice-form"><button type="submit" class="btn-choice"><span class="btn-choice-main"><span>%s</span><span class="btn-choice-sub">~/.cloudflared/config.yml</span></span><span class="chev">›</span></button></form>\n' "$(_d "Tunnel 설정" "Tunnel config")"
  printf '        </details>\n'
  printf '      </div>\n'
  _sn=$((_sn + 1))
  printf '      <div class="step-card">\n'
  printf '        <div class="step-label"><span class="step-num">%s</span>%s</div>\n' "$_sn" "$(_d "터널·GitHub·Agent" "Tunnel, GitHub, Agent")"
  printf '        <p class="step-desc">%s</p>\n' "$(_d "전체 설치 마법사를 Finder에서 엽니다. 이미 끝났으면 건너뛰어도 됩니다." "Opens the full setup wizard in Finder. Skip if you already finished.")"
  printf '        <form method="post" action="/launch-setup" class="choice-form"><button type="submit" class="btn-choice"><span class="btn-choice-main"><span>%s</span><span class="btn-choice-sub mono">%s</span></span><span class="chev">›</span></button></form>\n' "$(_d "셋업 스크립트 실행" "Run setup script")" "$(html_escape "$_setup_bn")"
  printf '      </div>\n'
  _sn=$((_sn + 1))
  if [[ -n "$dash_port" ]]; then
    printf '      <div class="step-card">\n'
    printf '        <div class="step-label"><span class="step-num">%s</span>%s</div>\n' "$_sn" "$(_d "이 대시보드" "This dashboard")"
    printf '        <p class="step-desc">%s</p>\n' "$(_d "같은 주소로 다시 들어올 수 있습니다. 모두 끝났으면 로컬 서버를 꺼도 됩니다." "You can open this address again later. Stop the local server when you are done.")"
    printf '        <p style="margin:0 0 8px;font-size:12px"><a class="side-dash-url mono" href="http://127.0.0.1:%s/">127.0.0.1:%s</a></p>\n' "$(html_escape "$dash_port")" "$(html_escape "$dash_port")"
    printf '        <form method="post" action="/dashboard-stop" class="choice-form"><button type="submit" class="btn-choice"><span class="btn-choice-main"><span>%s</span><span class="btn-choice-sub">%s</span></span><span class="chev">›</span></button></form>\n' "$(_d "대시보드 서버 끄기" "Stop dashboard server")" "$(_d "탭은 그대로 둬도 됩니다" "This tab can stay open")"
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
  if [[ -f "$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist" ]]; then
    local pwd pwdb
    pwd=$(plutil_string "$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist" WorkingDirectory)
    pwdb=$(basename "$(expand_tilde "$pwd")")
    if launchagent_running "com.cursor.agent.worker"; then
      printf '        <div class="card-h"><span class="dot ok"></span>%s</div>\n' "$(_d "워커" "Worker")"
      printf '        <p class="card-lead ok">%s</p>\n' "$(_d "실행 중" "Running")"
      printf '        <p class="card-sub"><span class="path-chip mono" title="%s">%s · %s</span></p>\n' "$(html_escape "$pwd")" "$(_d "작업 폴더" "Working folder")" "$(html_escape "$pwdb")"
      printf '        <div class="card-actions">\n'
      printf '          <form method="post" action="/action/worker-kickstart"><button type="submit" class="btn btn-secondary btn-small btn-pill">%s</button></form>\n' "$(_d "재시작" "Restart")"
      printf '        </div>\n'
    else
      printf '        <div class="card-h"><span class="dot warn"></span>%s</div>\n' "$(_d "워커" "Worker")"
      printf '        <p class="card-lead bad">%s</p>\n' "$(_d "중지" "Stopped")"
      printf '        <p class="card-sub"><span class="path-chip mono" title="%s">%s · %s</span></p>\n' "$(html_escape "$pwd")" "$(_d "작업 폴더" "Working folder")" "$(html_escape "$pwdb")"
      printf '        <form method="post" action="/action/worker-kickstart"><button type="submit" class="btn btn-pill">%s</button></form>\n' "$(_d "시작" "Start")"
    fi
  elif cursor_worker_process_running; then
    printf '        <div class="card-h"><span class="dot warn"></span>%s</div>\n' "$(_d "워커" "Worker")"
    printf '        <p class="card-lead bad">%s</p>\n' "$(_d "프로세스만 실행" "Process only")"
    printf '        <p class="card-sub">%s</p>\n' "$(_d "프로젝트 카드에서 등록" "Register from a project card")"
  else
    printf '        <div class="card-h"><span class="dot bad"></span>%s</div>\n' "$(_d "워커" "Worker")"
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
  local other_worker_path other_worker_bn plist_w pwow
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
    plist_w="$HOME/Library/LaunchAgents/com.cursor.agent.worker.plist"
    if [[ -f "$plist_w" ]]; then
      pwow=$(plutil_string "$plist_w" WorkingDirectory)
      if ! dirs_same "$pwow" "$ws"; then
        other_worker_path=$(expand_tilde "$pwow")
        other_worker_path=$(cd "$other_worker_path" 2>/dev/null && pwd -P || printf '%s' "$other_worker_path")
        other_worker_bn=$(basename "$other_worker_path")
      fi
    fi
    local svc_shell svc_port svc_on svc_disp svc_exec_path disabled_attr stop_disabled stop_title _wsvc_json port_inp_extra
    local auto_csv primary_auto stop_port running_ports_label open_disabled open_title
    local cf_show_ports _rest _tp _hn _anyh _pp
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
    stop_disabled=""
    stop_title=""
    if [[ -z "$stop_port" ]]; then
      stop_disabled=" disabled"
      stop_title=" title=\"$(_d "포트 필요" "Port required")\""
    fi
    printf '          <form method="post" action="/workspace-service-stop"><input type="hidden" name="path" value="%s" />' "$(html_escape "$ws")"
    [[ -n "$stop_port" ]] && printf '<input type="hidden" name="port" value="%s" />' "$(html_escape "$stop_port")"
    if [[ -n "$stop_port" ]]; then
      printf '<button type="submit" class="btn btn-secondary btn-small"%s%s>%s %s</button></form>\n' "$stop_disabled" "$stop_title" "$(_d "포트 끄기" "Stop")" "$(html_escape "$stop_port")"
    else
      printf '<button type="submit" class="btn btn-secondary btn-small"%s%s>%s</button></form>\n' "$stop_disabled" "$stop_title" "$(_d "포트 끄기" "Stop port")"
    fi
    printf '          <form method="post" action="/workspace-service-open"><input type="hidden" name="path" value="%s" />' "$(html_escape "$ws")"
    [[ -n "$stop_port" ]] && printf '<input type="hidden" name="port" value="%s" />' "$(html_escape "$stop_port")"
    if [[ -n "$stop_port" ]]; then
      printf '<button type="submit" class="btn btn-secondary btn-small"%s%s>%s %s</button></form>\n' "$open_disabled" "$open_title" "$(_d "열기" "Open")" "$(html_escape "$stop_port")"
    else
      printf '<button type="submit" class="btn btn-secondary btn-small"%s%s>%s</button></form>\n' "$open_disabled" "$open_title" "$(_d "열기" "Open")"
    fi
    printf '          <form method="post" action="/workspace-service-open"><input type="hidden" name="path" value="%s" /><input type="hidden" name="network" value="1" />' "$(html_escape "$ws")"
    [[ -n "$stop_port" ]] && printf '<input type="hidden" name="port" value="%s" />' "$(html_escape "$stop_port")"
    if [[ -n "$stop_port" ]]; then
      printf '<button type="submit" class="btn btn-secondary btn-small"%s%s>%s</button></form>\n' "$open_disabled" "$open_title" "$(_d "LAN 열기" "Open on LAN")"
    else
      printf '<button type="submit" class="btn btn-secondary btn-small"%s%s>%s</button></form>\n' "$open_disabled" "$open_title" "$(_d "LAN 열기" "Open on LAN")"
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
        printf '        <div class="ws-tunnel-row"><span class="mono">%s %s</span> · ' "$(_d "포트" "Port")" "$(html_escape "$_tp")"
        _anyh=0
        while IFS= read -r _hn || [[ -n "$_hn" ]]; do
          [[ -z "$_hn" ]] && continue
          _anyh=1
          printf '<a class="ws-tunnel-link" href="https://%s/" target="_blank" rel="noopener noreferrer">%s</a> ' "$(html_escape "$_hn")" "$(html_escape "$_hn")"
        done < <(cloudflare_hostnames_for_port "$_tp")
        if [[ "$_anyh" -eq 0 ]]; then
          printf '<span class="ws-tunnel-miss">%s</span>' "$(_d "연결된 도메인 없음" "No domain for this port")"
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
      printf '          <p class="repo-worker-remote">%s <span class="mono" title="%s">%s</span> %s</p>\n' "$(_d "워커 폴더:" "Worker folder:")" "$(html_escape "$other_worker_path")" "$(html_escape "$other_worker_bn")" "$(_d "이 카드와 다를 수 있음. 아래에서 이 경로로 맞출 수 있습니다." "May differ from this card. Use below to align.")"
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
  .ws-svc-actions { display:flex; flex-wrap:wrap; gap:8px; }
  .ws-svc-actions form { margin:0; }
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
  .ws-tunnel-miss { color:var(--warn); font-size:11px; }
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
  details.quick-check summary { list-style:none; cursor:pointer; padding:12px 14px; display:flex; flex-wrap:wrap; align-items:center; gap:10px; user-select:none; }
  details.quick-check summary::-webkit-details-marker { display:none; }
  details.quick-check summary::marker { content:none; }
  .qc-summary-locale { display:flex; flex-wrap:wrap; align-items:center; gap:10px; flex:1; min-width:0; }
  .qc-mid { display:inline-flex; flex-wrap:wrap; align-items:center; gap:8px; max-width:100%; }
  .qc-dots { display:inline-flex; gap:7px; align-items:center; }
  .qc-dots .dot { width:10px; height:10px; }
  .qc-legend { font-size:10px; color:var(--muted); font-weight:500; line-height:1.3; letter-spacing:.02em; }
  .qc-title { font-size:13px; font-weight:700; color:var(--text); }
  .qc-chev { margin-left:auto; color:var(--muted); font-size:12px; transition:transform .15s ease; }
  details.quick-check[open] summary .qc-chev { transform:rotate(90deg); }
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
  _dashboard_quick_check_dual_to_file "$qcfile"
  dashboard_global_cards_html > "$gfile"
  printf '\n' > "$gafile"
  printf '%s\n' "<p class=\"side-note\">$(_d "로컬 서버:" "Local server:") <code>./setup</code></p>" > "$sfile"
  if ! discover_workspace_paths | grep -q .; then
    printf '    <div class="repo"><div class="repo-name">%s</div><div class="repo-path mono">%s</div></div>\n' "$(_d "폴더 없음" "No folders")" "$(_d "workspaces.txt 또는 ~/Dev 스캔" "workspaces.txt or ~/Dev scan")" > "$wfile"
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
  _dashboard_quick_check_dual_to_file "$qcfile"
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
      printf '      <div class="repo-path mono">%s <a href="/refresh">%s</a></div>\n' "$(_d "왼쪽 「Finder에서 폴더 추가」를 누르거나 아래를 눌러 목록을 만듭니다." "Use 「Add folder in Finder」 on the left, or add paths below.")" "$(_d "새로고침" "Refresh")"
      printf '      <form method="post" action="/workspace-add-folder" class="choice-form" style="margin-top:10px"><button type="submit" class="btn-choice"><span class="btn-choice-main"><span>%s</span><span class="btn-choice-sub">workspaces.txt</span></span><span class="chev">›</span></button></form>\n' "$(_d "Finder에서 폴더 추가" "Add folder in Finder")"
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
