#!/usr/bin/env bash
# 브라우저 대시보드(127.0.0.1) — 클릭 시 터미널에서 이어 실행

dashboard_write_allowlist_file() {
  local dest="$1"
  discover_workspace_paths > "$dest"
}

# 임시 파일에 내장 Python 대시보드 서버 기록 후 경로 출력
_dashboard_server_write_py() {
  local out="$1"
  python3 <<'PY' > "$out"
import textwrap, sys
code = r'''
import os, subprocess, urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
import shlex

class H(BaseHTTPRequestHandler):
    server_version = "CursorSetupDash/1.0"

    def log_message(self, fmt, *args):
        pass

    def _run_term(self, script_body, auto_close=False):
        if auto_close:
            script_body = script_body + "; exit"
        wrapped = "bash -lc " + shlex.quote(script_body)
        def aq(s):
            return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
        scpt = "tell application \"Terminal\" to do script " + aq(wrapped)
        subprocess.run(["osascript", "-e", scpt], check=False)

    def _regen(self):
        setup = os.environ["CURSOR_SETUP_SCRIPT"]
        htm = os.environ["CURSOR_DASH_HTML"]
        subprocess.run([setup, "--_cursor-setup-write-dash", htm], check=False)

    def _allow_ok(self, path):
        path = os.path.realpath(path)
        if not path or not os.path.isdir(path):
            return False
        al = os.environ.get("CURSOR_DASH_ALLOWLIST", "")
        if not al or not os.path.isfile(al):
            return False
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

    def do_GET(self):
        p = self.path.split("?", 1)[0]
        if p == "/refresh":
            self._regen()
            self.send_response(302)
            self.send_header("Location", "/")
            self.end_headers()
            return
        if p in ("/", "/index.html"):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            with open(os.environ["CURSOR_DASH_HTML"], "rb") as fp:
                self.wfile.write(fp.read())
            return
        self.send_error(404)

    def do_POST(self):
        root = os.environ["CURSOR_SETUP_ROOT"]
        setup = os.environ["CURSOR_SETUP_SCRIPT"]
        p = self.path
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
        if p.startswith("/action/"):
            uid = os.getuid()
            ag = os.path.expanduser("~/.local/bin/agent")
            agq = shlex.quote(ag)
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
                "/action/worker-kickstart": "launchctl kickstart -k gui/{}/com.cursor.agent.worker 2>/dev/null || true".format(
                    uid
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
    host = "127.0.0.1"
    httpd = HTTPServer((host, port), H)
    print("[정보] 대시보드 http://{}:{}/ (종료: Ctrl+C)".format(host, port), flush=True)
    httpd.serve_forever()

if __name__ == "__main__":
    main()
'''
sys.stdout.write(textwrap.dedent(code))
PY
}

dashboard_server_main_blocking() {
  local root="${CURSOR_SETUP_ROOT:-$ROOT}"
  local port html allow py preferred
  if ! command_exists python3; then
    log_err "대시보드 서버에 python3 가 필요합니다."
    return 1
  fi
  preferred="${CURSOR_DASH_PORT:-58741}"
  if python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1', int('$preferred'))); s.close()" 2>/dev/null; then
    port="$preferred"
  else
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
    log_info "기본 포트 ${preferred} 사용 중 — 임시 포트 ${port} 로 뜹니다 (즐겨찾기는 포트마다 따로 저장됩니다)."
  fi
  html="$(mktemp).html"
  allow="$(mktemp)"
  py="$(mktemp).py"
  dashboard_write_allowlist_file "$allow"
  local setup_cmd="$root/setup"
  [[ -f "$setup_cmd" ]] || setup_cmd="$root/MacMini-Cursor-Setup.command"
  export CURSOR_SETUP_EXEC_HINT="$setup_cmd"
  "$setup_cmd" --_cursor-setup-write-dash "$html" || {
    log_err "대시보드 HTML 생성 실패"
    rm -f "$allow" "$py"
    return 1
  }
  _dashboard_server_write_py "$py"
  chmod +x "$py" 2>/dev/null || true

  export CURSOR_DASH_PORT="$port"
  export CURSOR_DASH_HTML="$html"
  export CURSOR_DASH_ALLOWLIST="$allow"
  export CURSOR_SETUP_SCRIPT="$setup_cmd"
  export CURSOR_SETUP_ROOT="$root"

  _dashboard_cleanup() {
    rm -f "$html" "$allow" "$py" 2>/dev/null || true
  }
  trap '_dashboard_cleanup' EXIT INT TERM

  ( sleep 0.35 && open "http://127.0.0.1:${port}/" ) &
  python3 "$py"
}
