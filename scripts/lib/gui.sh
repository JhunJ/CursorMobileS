#!/usr/bin/env bash
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
