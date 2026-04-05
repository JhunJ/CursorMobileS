#!/usr/bin/env bash
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
