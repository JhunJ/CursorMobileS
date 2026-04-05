#!/usr/bin/env bash
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
