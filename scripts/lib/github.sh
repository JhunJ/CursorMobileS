#!/usr/bin/env bash
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
