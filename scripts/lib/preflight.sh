#!/usr/bin/env bash
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
