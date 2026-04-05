#!/usr/bin/env bash
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
  log_info "[2/4] Git · GitHub"

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
