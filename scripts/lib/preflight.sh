#!/usr/bin/env bash
# Preflight: macOS, git, Homebrew, gh

preflight_main() {
  log_info "[1/4] 준비"

  if ! command_exists git; then
    log_err "git 없음 → 터미널에 입력: xcode-select --install"
    exit 1
  fi

  if ! command_exists brew; then
    log_warn "Homebrew 없음 (gh 설치에 필요)"
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
}
