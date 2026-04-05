#!/usr/bin/env bash
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
