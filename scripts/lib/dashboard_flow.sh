#!/usr/bin/env bash
# 브라우저 대시보드(기본 127.0.0.1 바인딩) — 클릭 시 터미널에서 이어 실행

dashboard_write_allowlist_file() {
  local dest="$1"
  discover_workspace_paths > "$dest"
}

# 127.0.0.1:port LISTEN 프로세스 종료 (터미널만 닫고 남은 이전 대시보드 정리)
dashboard_free_listen_port() {
  local port="$1"
  local pids pid
  command_exists lsof || return 0
  pids=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null) || true
  [[ -z "$pids" ]] && return 0
  log_warn "포트 ${port} 사용 중 — 이전 프로세스를 종료합니다."
  for pid in $(printf '%s\n' "$pids" | sort -u); do
    [[ -z "$pid" ]] && continue
    kill "$pid" 2>/dev/null || true
  done
  sleep 0.45
  pids=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null) || true
  if [[ -n "$pids" ]]; then
    for pid in $(printf '%s\n' "$pids" | sort -u); do
      [[ -z "$pid" ]] && continue
      kill -9 "$pid" 2>/dev/null || true
    done
    sleep 0.25
  fi
}

# 임시 파일에 내장 Python 대시보드 서버 기록 후 경로 출력
_dashboard_server_write_py() {
  local out="$1"
  python3 <<'PY' > "$out"
import textwrap, sys
code = r'''
import os, re, secrets, subprocess, sys, threading, time, urllib.parse, json, pathlib
from http.server import HTTPServer, BaseHTTPRequestHandler
import shlex


def _dash_server_binds_all_interfaces():
    b = (os.environ.get("CURSOR_DASH_HOST") or "127.0.0.1").strip()
    return b in ("0.0.0.0", "::")


def _client_ip_trusted_without_origin(ip: str) -> bool:
    """Origin/Referer 가 없을 때: localhost 또는(서버가 0.0.0.0 이면) 사설망 클라이언트만 POST 허용."""
    if not ip:
        return False
    ip = ip.strip().lower()
    if ip in ("127.0.0.1", "::1", "::ffff:127.0.0.1"):
        return True
    if not _dash_server_binds_all_interfaces():
        return False
    if ip.startswith("::ffff:"):
        ip = ip[7:]
    parts = ip.split(".")
    if len(parts) != 4:
        return False
    try:
        a, b, _, _ = (int(x) for x in parts)
    except ValueError:
        return False
    if a == 10:
        return True
    if a == 172 and 16 <= b <= 31:
        return True
    if a == 192 and b == 168:
        return True
    if a == 127:
        return True
    if a == 169 and b == 254:
        return True
    return False


def _coerce_port(pv):
    if pv is None or isinstance(pv, bool):
        return None
    if isinstance(pv, (int, float)):
        try:
            n = int(pv)
        except (TypeError, ValueError):
            return None
        if isinstance(pv, float) and float(pv) != float(int(pv)):
            return None
        return n if 1 <= n <= 65535 else None
    s = str(pv).strip()
    if not s:
        return None
    try:
        n = int(float(s))
    except (ValueError, OverflowError):
        return None
    return n if 1 <= n <= 65535 else None


def _port_from_obj(o):
    if not isinstance(o, dict):
        return None
    for key in ("port", "devPort", "listen", "listenPort"):
        if key not in o:
            continue
        pn = _coerce_port(o.get(key))
        if pn is not None:
            return pn
    return None


def _effective_shell_from_obj(o):
    sh = (o.get("shell") or "").strip().replace("\r", "").replace("\n", " ")
    ex = (o.get("exec") or "").strip().replace("\r", "")
    if ex:
        ep = pathlib.Path(ex).expanduser()
        try:
            try:
                ep = ep.resolve(strict=False)
            except TypeError:
                ep = ep.resolve()
        except OSError:
            try:
                ep = pathlib.Path(os.path.realpath(ex))
            except OSError:
                ep = pathlib.Path(ex)
        return "bash " + shlex.quote(str(ep))
    return sh or None


def _workspace_service_read(path_abs):
    p = pathlib.Path(path_abs).resolve()
    f = pathlib.Path.home() / ".cursor-setup" / "workspace-services.jsonl"
    if not f.is_file():
        return None, None
    try:
        text = f.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None, None

    def _match(ap, target):
        if ap == target:
            return True
        try:
            if ap.exists() and target.exists() and os.path.samefile(ap, target):
                return True
        except OSError:
            pass
        return os.path.normcase(str(ap)) == os.path.normcase(str(target))

    last = None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            o = json.loads(line)
        except json.JSONDecodeError:
            continue
        rawp = (o.get("path") or "").replace("\r", "").strip()
        ap = pathlib.Path(rawp).expanduser()
        try:
            try:
                ap = ap.resolve(strict=False)
            except TypeError:
                ap = ap.resolve()
        except OSError:
            ap = pathlib.Path(os.path.realpath(str(rawp)))
        if not _match(ap, p):
            continue
        last = o
    if last is None:
        return None, None
    eff = _effective_shell_from_obj(last)
    po = _port_from_obj(last)
    return (eff, po)


def _bash_invocation_script_path(sh_cmd):
    """'bash /abs/script' 한 줄이면 그 스크립트 실경로, 아니면 None."""
    s = (sh_cmd or "").strip()
    if not s.startswith("bash "):
        return None
    rest = s[5:].strip()
    try:
        parts = shlex.split(rest)
    except ValueError:
        return None
    if not parts:
        return None
    cand = parts[0]
    if cand.startswith("-"):
        cand = None
        for p in parts[1:]:
            if not p.startswith("-"):
                cand = p
                break
        if not cand:
            return None
    exp = os.path.expanduser(cand)
    if not exp.startswith("/"):
        return None
    ep = os.path.realpath(exp)
    if os.path.isfile(ep):
        return ep
    return None


def _path_is_cursor_setup_entrypoint(path):
    """workspace-services 의 exec 가 CursorMobileS setup(또는 스태시 복사본)인지."""
    path = os.path.realpath(path)
    base = os.path.basename(path).lower()
    if base == "setup":
        return True
    stash_dir = os.path.realpath(
        str(pathlib.Path.home() / ".cursor-setup" / "workspace-exec-stash")
    )
    if path.startswith(stash_dir + os.sep) and ("setup" in base or base.endswith("_setup")):
        return True
    return False


def _workspace_setup_script_path(ws_rp):
    """프로젝트 루트의 ./setup 또는 대시보드가 쓰는 CURSOR_SETUP_SCRIPT."""
    ws_rp = os.path.realpath(ws_rp)
    cand = os.path.join(ws_rp, "setup")
    if os.path.isfile(cand):
        return cand
    envp = (os.environ.get("CURSOR_SETUP_SCRIPT") or "").strip()
    if envp and os.path.isfile(envp):
        return os.path.realpath(envp)
    return None


def _lan_ipv4():
    # macOS 기준: 우선순위 인터페이스에서 LAN IPv4 탐색
    for ifn in ("en0", "en1", "en2"):
        try:
            r = subprocess.run(
                ["ipconfig", "getifaddr", ifn],
                capture_output=True,
                text=True,
                timeout=2,
            )
        except Exception:
            continue
        ip = (r.stdout or "").strip()
        if r.returncode == 0 and ip:
            return ip
    return None


def _favorite_paths_filtered():
    dest = pathlib.Path.home() / ".cursor-setup" / "dashboard-favorites.json"
    raw = []
    if dest.is_file():
        try:
            data = json.loads(dest.read_text(encoding="utf-8"))
            if isinstance(data, list):
                raw = [str(x).strip() for x in data if isinstance(x, str) and str(x).strip()]
        except Exception:
            pass
    al = os.environ.get("CURSOR_DASH_ALLOWLIST", "")
    allowed = set()
    if al and os.path.isfile(al):
        with open(al, encoding="utf-8", errors="replace") as fp:
            for line in fp:
                line = line.strip()
                if not line:
                    continue
                try:
                    allowed.add(os.path.realpath(line))
                except OSError:
                    continue
    use_allowlist = len(allowed) > 0
    out = []
    for x in raw:
        try:
            rp = os.path.realpath(x)
        except OSError:
            continue
        if use_allowlist:
            if rp in allowed:
                out.append(rp)
        elif os.path.isdir(rp):
            out.append(rp)
    return out


def _workspace_order_paths_filtered():
    dest = pathlib.Path.home() / ".cursor-setup" / "dashboard-workspace-order.json"
    raw = []
    if dest.is_file():
        try:
            data = json.loads(dest.read_text(encoding="utf-8"))
            if isinstance(data, list):
                raw = [str(x).strip() for x in data if isinstance(x, str) and str(x).strip()]
        except Exception:
            pass
    al = os.environ.get("CURSOR_DASH_ALLOWLIST", "")
    allowed = set()
    if al and os.path.isfile(al):
        with open(al, encoding="utf-8", errors="replace") as fp:
            for line in fp:
                line = line.strip()
                if not line:
                    continue
                try:
                    allowed.add(os.path.realpath(line))
                except OSError:
                    continue
    use_allowlist = len(allowed) > 0
    out = []
    for x in raw:
        try:
            rp = os.path.realpath(x)
        except OSError:
            continue
        if use_allowlist:
            if rp in allowed:
                out.append(rp)
        elif os.path.isdir(rp):
            out.append(rp)
    return out


def _send_json(handler, obj, status=200):
    b = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("Content-Length", str(len(b)))
    handler.end_headers()
    handler.wfile.write(b)


def _ws_path_match_entry_path(rawp, target_resolved):
    rawp = (rawp or "").replace("\r", "").strip()
    ap = pathlib.Path(rawp).expanduser()
    try:
        try:
            ap = ap.resolve(strict=False)
        except TypeError:
            ap = ap.resolve()
    except OSError:
        try:
            ap = pathlib.Path(os.path.realpath(str(rawp)))
        except OSError:
            return False
    if ap == target_resolved:
        return True
    try:
        if ap.exists() and target_resolved.exists() and os.path.samefile(ap, target_resolved):
            return True
    except OSError:
        pass
    return os.path.normcase(str(ap)) == os.path.normcase(str(target_resolved))


def _workspace_services_jsonl_path():
    return pathlib.Path.home() / ".cursor-setup" / "workspace-services.jsonl"


def _workspace_services_upsert_exec(ws_real, exec_abs, port_opt=None):
    f = _workspace_services_jsonl_path()
    f.parent.mkdir(parents=True, exist_ok=True)
    tgt = pathlib.Path(ws_real).resolve()
    lines_kept = []
    last_match = None
    text = f.read_text(encoding="utf-8", errors="replace") if f.is_file() else ""
    for line in text.splitlines():
        raw = line.strip()
        if not raw or raw.startswith("#"):
            lines_kept.append(line)
            continue
        try:
            o = json.loads(raw)
        except json.JSONDecodeError:
            lines_kept.append(line)
            continue
        rp = o.get("path") or ""
        if _ws_path_match_entry_path(rp, tgt):
            last_match = o
            continue
        lines_kept.append(line)
    merged = dict(last_match) if last_match else {}
    merged["path"] = str(tgt)
    merged["exec"] = exec_abs
    if "shell" in merged:
        del merged["shell"]
    if port_opt is not None:
        merged["port"] = int(port_opt)
    lines_kept.append(json.dumps(merged, ensure_ascii=False))
    nf = f.with_name(f.name + ".tmp")
    nf.write_text("\n".join(lines_kept) + "\n", encoding="utf-8")
    nf.replace(f)


def _safe_filename(name):
    name = os.path.basename(name or "")
    name = re.sub(r"[^\w.\- ]+", "_", name).strip("._")[:120]
    return name or "exec-file"


def _stash_exec_file(ws_real, filename, raw):
    ws_path = pathlib.Path(ws_real).resolve()
    try:
        cand = ws_path / pathlib.Path(filename).name
        if cand.is_file() and cand.read_bytes() == raw:
            try:
                suf = cand.suffix.lower()
                if suf in (".command", ".sh", ".tool") or cand.name.endswith(".command"):
                    os.chmod(cand, 0o755)
            except OSError:
                pass
            return str(cand.resolve())
    except OSError:
        pass
    stash = pathlib.Path.home() / ".cursor-setup" / "workspace-exec-stash"
    stash.mkdir(parents=True, exist_ok=True)
    base = _safe_filename(filename)
    ws_tag = _safe_filename(os.path.basename(ws_real))[:40]
    dest = stash / (ws_tag + "_" + base)
    n = 0
    while dest.exists():
        n += 1
        dest = stash / (ws_tag + "_" + str(n) + "_" + base)
    dest.write_bytes(raw)
    try:
        suf = dest.suffix.lower()
        if suf in (".command", ".sh", ".tool") or dest.name.endswith(".command"):
            os.chmod(dest, 0o755)
    except OSError:
        pass
    return str(dest.resolve())


def _multipart_parse(ct, rawb):
    try:
        from io import BytesIO
        from cgi import FieldStorage

        env = {
            "REQUEST_METHOD": "POST",
            "CONTENT_TYPE": ct,
            "CONTENT_LENGTH": str(len(rawb)),
        }
        fs = FieldStorage(fp=BytesIO(rawb), environ=env, keep_blank_values=True)
        fields = {}
        files = {}
        if "path" in fs:
            fields["path"] = fs.getfirst("path") or ""
        if "port" in fs:
            fields["port"] = fs.getfirst("port") or ""
        if "_csrf" in fs:
            fields["_csrf"] = fs.getfirst("_csrf") or ""
        if "file" in fs:
            item = fs["file"]
            if isinstance(item, list):
                item = item[0] if item else None
            if item is not None:
                fn = getattr(item, "filename", None) or ""
                fobj = getattr(item, "file", None)
                blob = fobj.read() if fobj is not None else b""
                if fn or blob:
                    files["file"] = (fn or "upload.bin", blob)
        return fields, files
    except Exception:
        pass
    return _multipart_parse_manual(ct, rawb)


def _multipart_parse_manual(content_type, data):
    fields = {}
    files = {}
    if "multipart/form-data" not in content_type or "boundary=" not in content_type:
        return fields, files
    bd = content_type.split("boundary=", 1)[1].strip()
    if bd.startswith('"') and bd.endswith('"'):
        bd = bd[1:-1]
    bdelim = b"--" + bd.encode("ascii", errors="ignore")
    for part in data.split(bdelim):
        part = part.strip(b"\r\n")
        if not part or part == b"--":
            continue
        if b"\r\n\r\n" not in part:
            continue
        head, body = part.split(b"\r\n\r\n", 1)
        if body.endswith(b"\r\n"):
            body = body[:-2]
        htext = head.decode("latin1", errors="replace")
        name = None
        filename = None
        for hl in htext.split("\r\n"):
            if hl.lower().startswith("content-disposition:"):
                m = re.search(r'name="([^"]+)"', hl)
                if m:
                    name = m.group(1)
                m2 = re.search(r'filename="([^"]*)"', hl)
                if m2:
                    filename = m2.group(1)
        if not name:
            continue
        if filename is not None:
            files[name] = (filename, body)
        else:
            fields[name] = body.decode("utf-8", errors="replace")
    return fields, files


def _mac_choose_file_posix():
    scr = 'POSIX path of (choose file with prompt "실행 파일 선택")'
    try:
        r = subprocess.run(
            ["osascript", "-e", scr],
            capture_output=True,
            text=True,
            timeout=600,
        )
    except subprocess.TimeoutExpired:
        return None
    if r.returncode != 0:
        return None
    p = (r.stdout or "").strip().rstrip("\n")
    return p or None


class DashServer(HTTPServer):
    def __init__(self, server_address, RequestHandlerClass):
        super().__init__(server_address, RequestHandlerClass)
        self.csrf_token = secrets.token_urlsafe(32)


class H(BaseHTTPRequestHandler):
    server_version = "CursorSetupDash/1.0"
    # 부모 프로세스가 이미 HTML 을 썼을 때 첫 GET 에서 중복 --_cursor-setup-write-dash 를 피함
    _regen_cooldown_sec = 2.5
    _last_regen_time = 0.0

    def log_message(self, fmt, *args):
        pass

    def end_headers(self):
        # 로컬 대시보드라도 브라우저 기본 보호 헤더를 넣어 임의 임베드/스니핑을 줄인다.
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; "
            "script-src 'self' 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
        )
        super().end_headers()

    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            # 브라우저가 응답 도중 연결을 끊는 경우(새로고침/탭 닫기)는 정상 동작으로 본다.
            return

    def _run_term(self, script_body, auto_close=False):
        if auto_close:
            script_body = script_body + "; exit"
        wrapped = "bash -lc " + shlex.quote(script_body)

        def aq(s):
            return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

        # 앞으로 가져오기 — 대시보드 버튼 후 터미널이 뒤에만 뜨는 문제 완화
        subprocess.run(
            ["osascript", "-e", 'tell application "Terminal" to activate'],
            check=False,
        )
        scpt = "tell application \"Terminal\" to do script " + aq(wrapped)
        subprocess.run(["osascript", "-e", scpt], check=False)

    def _dash_lang_from_headers(self):
        c = self.headers.get("Cookie", "") or ""
        for part in c.split(";"):
            part = part.strip()
            if part.lower().startswith("cursor_dash_lang="):
                v = part.split("=", 1)[1].strip().lower()
                if v == "en":
                    return "en"
        return "ko"

    def _regen(self):
        setup = os.environ["CURSOR_SETUP_SCRIPT"]
        htm = os.environ["CURSOR_DASH_HTML"]
        env = os.environ.copy()
        env["CURSOR_DASH_LANG"] = self._dash_lang_from_headers()
        subprocess.run([setup, "--_cursor-setup-write-dash", htm], env=env, check=False)

    def _request_forces_regen(self):
        """브라우저 강력 새로고침 등 — 쿨다운 무시"""
        cc = (self.headers.get("Cache-Control") or "").lower()
        if "no-cache" in cc or "max-age=0" in cc:
            return True
        pragma = (self.headers.get("Pragma") or "").lower()
        if "no-cache" in pragma:
            return True
        return False

    def _maybe_regen_dashboard(self):
        now = time.time()
        force = self._request_forces_regen()
        if (
            force
            or (now - H._last_regen_time) >= H._regen_cooldown_sec
        ):
            self._regen()
            H._last_regen_time = time.time()

    def _allow_ok(self, path):
        path = os.path.realpath(path)
        if not path or not os.path.isdir(path):
            return False
        al = os.environ.get("CURSOR_DASH_ALLOWLIST", "")
        if not al or not os.path.isfile(al):
            return True
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

    def _post_same_origin_ok(self):
        host = (self.headers.get("Host", "") or "").strip().lower()
        if not host:
            return False
        for hname in ("Origin", "Referer"):
            raw = (self.headers.get(hname, "") or "").strip()
            if not raw:
                continue
            try:
                p = urllib.parse.urlsplit(raw)
            except Exception:
                continue
            if p.scheme not in ("http", "https"):
                continue
            src = (p.netloc or "").strip().lower()
            if src and src == host:
                return True
        # 일부 클라이언트(특히 모바일)는 Origin/Referer 를 안 보냄. LAN 바인딩(0.0.0.0)일 때는 사설망 IP 도 허용.
        ra = ""
        try:
            ra = (self.client_address[0] or "").strip().lower()
        except Exception:
            pass
        return _client_ip_trusted_without_origin(ra)

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

    def _html_origin_denied(self):
        b = (
            "<!DOCTYPE html><html lang=\"ko\"><meta charset=\"utf-8\">"
            "<body style=\"font-family:system-ui;background:#0d1117;color:#e6edf3;padding:24px\">"
            "<p>요청 출처를 확인할 수 없어 거부했습니다. 대시보드 페이지에서 다시 시도해 주세요.</p>"
            "<p><a href=\"/\" style=\"color:#2f81f7\">대시보드로</a></p></body></html>"
        )
        return b.encode("utf-8")

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        p = parsed.path
        if p == "/refresh":
            self._regen()
            H._last_regen_time = time.time()
            self.send_response(302)
            self.send_header("Location", "/")
            self.end_headers()
            return
        if p in ("/", "/index.html"):
            q = urllib.parse.parse_qs(parsed.query or "")
            if "lang" in q and q["lang"]:
                v = (q["lang"][0] or "").lower()
                if v in ("en", "ko"):
                    self.send_response(302)
                    # 쿠키 반영 HTML 이 필요하므로 /refresh 로 한 번 갱신 후 홈으로
                    self.send_header("Location", "/refresh")
                    self.send_header(
                        "Set-Cookie",
                        "cursor_dash_lang=" + v + "; Path=/; Max-Age=31536000; SameSite=Lax; HttpOnly",
                    )
                    self.end_headers()
                    return
            # 직전에 부모가 HTML 을 썼으면 쿨다운 동안 스킵(시작 직후 이중 실행 방지).
            # 오래 지난 뒤·강력 새로고침·footer 의 /refresh 는 최신 상태로 다시 그림.
            self._maybe_regen_dashboard()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            with open(os.environ["CURSOR_DASH_HTML"], "rb") as fp:
                self.wfile.write(fp.read())
            return
        if p == "/favorite-list":
            data = _favorite_paths_filtered()
            body = json.dumps(data, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if p == "/workspace-order-list":
            data = _workspace_order_paths_filtered()
            body = json.dumps(data, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def do_POST(self):
        root = os.environ["CURSOR_SETUP_ROOT"]
        setup = os.environ["CURSOR_SETUP_SCRIPT"]
        p = self.path.split("?", 1)[0]
        if not self._post_same_origin_ok():
            self.send_response(403)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_origin_denied())
            return
        if p == "/set-lang":
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8", errors="replace") if length else ""
            q = urllib.parse.parse_qs(body)
            raw = (q.get("lang") or [""])[0].strip().lower()
            if raw not in ("ko", "en"):
                raw = "ko"
            self.send_response(204)
            self.send_header(
                "Set-Cookie",
                "cursor_dash_lang=" + raw + "; Path=/; Max-Age=31536000; SameSite=Lax; HttpOnly",
            )
            self.end_headers()
            return
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
        if p == "/tunnel-workspace":
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
            rp = os.path.realpath(raw)
            inner = "export CURSOR_SETUP_TUNNEL_WORKSPACE={}; export CURSOR_SETUP_CF_FORCE=1; cd {} && /bin/bash {} --tunnel-only".format(
                shlex.quote(rp),
                shlex.quote(root),
                shlex.quote(setup),
            )
            self._run_term(inner, auto_close=False)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            return
        if p == "/rename-repo":
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
            newn = (q.get("new_name") or [""])[0].strip()
            if not self._allow_ok(raw) or not newn:
                self.send_response(403)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(self._html_denied())
                return
            inner = "/bin/bash {} --rename-repo {} {}".format(
                shlex.quote(setup),
                shlex.quote(raw),
                shlex.quote(newn),
            )
            self._run_term(inner, auto_close=True)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            return
        if p == "/workspace-service-start":
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
            rp = os.path.realpath(raw)
            sh, _po = _workspace_service_read(rp)
            if not sh:
                self.send_response(404)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(
                    (
                        "<!DOCTYPE html><html lang=ko><meta charset=utf-8>"
                        "<body style=background:#0d1117;color:#e6edf3;padding:24px>"
                        "<p>이 폴더에 exec(실행 파일) 또는 shell 이 workspace-services.jsonl 에 없습니다.</p>"
                        "<p><a href=/ style=color:#2f81f7>대시보드</a></p></body></html>"
                    ).encode("utf-8")
                )
                return
            # exec 가 setup(또는 스태시 복사본)만 가리키면 인자 없이 또 HTTP 대시보드를 띄워 포트가 충돌함 → 터미널 --workspace 만 연다.
            invoked = _bash_invocation_script_path(sh)
            if invoked and _path_is_cursor_setup_entrypoint(invoked):
                real_setup = _workspace_setup_script_path(rp)
                if real_setup:
                    sh = "bash " + shlex.quote(real_setup) + " --workspace " + shlex.quote(rp)
                    inner = "cd {} && export CURSOR_SETUP_ROOT={} && {}".format(
                        shlex.quote(rp),
                        shlex.quote(rp),
                        sh,
                    )
                else:
                    inner = (
                        "cd {} && "
                        "export CURSOR_SETUP_ROOT={} HOST=0.0.0.0 VITE_HOST=0.0.0.0 BIND=0.0.0.0 BIND_ADDR=0.0.0.0 "
                        "npm_config_host=0.0.0.0 && {}"
                    ).format(shlex.quote(rp), shlex.quote(rp), sh)
            else:
                # dev server 가 LAN(동일 네트워크)에서도 접근 가능하도록 host 관련 env를 기본 주입
                inner = (
                    "cd {} && "
                    "export CURSOR_SETUP_ROOT={} HOST=0.0.0.0 VITE_HOST=0.0.0.0 BIND=0.0.0.0 BIND_ADDR=0.0.0.0 "
                    "npm_config_host=0.0.0.0 && {}"
                ).format(shlex.quote(rp), shlex.quote(rp), sh)
            self._run_term(inner, auto_close=False)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            return
        if p == "/workspace-service-open":
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
            rp = os.path.realpath(raw)
            _sh, po = _workspace_service_read(rp)
            ov = (q.get("port") or [""])[0].strip()
            if ov.isdigit():
                pn = int(ov)
                if 1 <= pn <= 65535:
                    po = pn
            if not po:
                self.send_response(400)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(
                    (
                        "<!DOCTYPE html><html lang=ko><meta charset=utf-8>"
                        "<body style=background:#0d1117;color:#e6edf3;padding:24px>"
                        "<p>열 포트가 없습니다.</p>"
                        "<p><a href=/ style=color:#2f81f7>대시보드</a></p></body></html>"
                    ).encode("utf-8")
                )
                return
            nw = (q.get("network") or [""])[0].strip() in ("1", "true", "yes", "on")
            host = "127.0.0.1"
            if nw:
                lan = _lan_ipv4()
                if lan:
                    host = lan
            subprocess.Popen(
                ["open", "http://{}:{}/".format(host, int(po))],
                env=os.environ,
                close_fds=True,
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            return
        if p == "/workspace-service-stop":
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
            rp = os.path.realpath(raw)
            _sh, po = _workspace_service_read(rp)
            ov = (q.get("port") or [""])[0].strip()
            if ov.isdigit():
                pn = int(ov)
                if 1 <= pn <= 65535:
                    po = pn
            if not po:
                self.send_response(400)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(
                    (
                        "<!DOCTYPE html><html lang=ko><meta charset=utf-8>"
                        "<body style=background:#0d1117;color:#e6edf3;padding:24px>"
                        "<p>끌 포트가 없습니다. 폼에서 포트를 보내거나 jsonl 에 port 를 적어 주세요.</p>"
                        "<p><a href=/ style=color:#2f81f7>대시보드</a></p></body></html>"
                    ).encode("utf-8")
                )
                return
            inner = (
                "p=$(lsof -nP -tiTCP:%d -sTCP:LISTEN 2>/dev/null); "
                '[[ -n "$p" ]] && kill $p 2>/dev/null; sleep 0.4; '
                "p=$(lsof -nP -tiTCP:%d -sTCP:LISTEN 2>/dev/null); "
                '[[ -n "$p" ]] && kill -9 $p 2>/dev/null; true'
            ) % (po, po)
            self._run_term(inner, auto_close=True)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            return
        if p == "/workspace-exec-choose":
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
                _send_json(self, {"ok": False, "err": "허용되지 않은 폴더"}, 403)
                return
            if sys.platform != "darwin":
                _send_json(
                    self,
                    {"ok": False, "err": "Finder 선택은 macOS 전용입니다 · 찾아보기로 올리세요"},
                    400,
                )
                return
            rp = os.path.realpath(raw)
            pv = (q.get("port") or [""])[0].strip()
            po = int(pv) if pv.isdigit() and 1 <= int(pv) <= 65535 else None
            chosen = _mac_choose_file_posix()
            if not chosen:
                _send_json(self, {"ok": False, "err": "취소됨"}, 200)
                return
            try:
                cpath = os.path.realpath(chosen)
            except OSError:
                _send_json(self, {"ok": False, "err": "경로 오류"}, 400)
                return
            if not os.path.isfile(cpath):
                _send_json(self, {"ok": False, "err": "파일이 아닙니다"}, 400)
                return
            try:
                _workspace_services_upsert_exec(rp, cpath, po)
            except OSError as ex:
                _send_json(self, {"ok": False, "err": str(ex)}, 500)
                return
            _send_json(self, {"ok": True, "exec": cpath}, 200)
            return
        if p == "/workspace-exec-upload":
            allow_path = os.environ.get("CURSOR_DASH_ALLOWLIST", "")
            if allow_path:
                subprocess.run(
                    [setup, "--_cursor-setup-write-allowlist", allow_path],
                    check=False,
                )
            ct = self.headers.get("Content-Type", "")
            if "multipart/form-data" not in ct:
                _send_json(self, {"ok": False, "err": "multipart/form-data 가 필요합니다"}, 400)
                return
            length = int(self.headers.get("Content-Length", "0"))
            rawb = self.rfile.read(length)
            fields, files = _multipart_parse(ct, rawb)
            raw = (fields.get("path") or "").strip()
            if not self._allow_ok(raw):
                _send_json(self, {"ok": False, "err": "허용되지 않은 폴더"}, 403)
                return
            rp = os.path.realpath(raw)
            fl = files.get("file")
            if not fl:
                _send_json(self, {"ok": False, "err": "파일이 없습니다"}, 400)
                return
            fname, fbody = fl
            if len(fbody) > 12 * 1024 * 1024:
                _send_json(self, {"ok": False, "err": "12MB 이하만 가능합니다"}, 400)
                return
            pv = (fields.get("port") or "").strip()
            po = int(pv) if pv.isdigit() and 1 <= int(pv) <= 65535 else None
            try:
                dest = _stash_exec_file(rp, fname, fbody)
                _workspace_services_upsert_exec(rp, dest, po)
            except OSError as ex:
                _send_json(self, {"ok": False, "err": str(ex)}, 500)
                return
            _send_json(self, {"ok": True, "exec": dest}, 200)
            return
        if p == "/favorite-save":
            al = os.environ.get("CURSOR_DASH_ALLOWLIST", "")
            allowed = set()
            if al and os.path.isfile(al):
                with open(al, encoding="utf-8", errors="replace") as fp:
                    for line in fp:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            allowed.add(os.path.realpath(line))
                        except OSError:
                            continue
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8", errors="replace")
            try:
                arr = json.loads(body)
            except json.JSONDecodeError:
                self.send_response(400)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                return
            if not isinstance(arr, list):
                self.send_response(400)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                return
            use_allowlist = len(allowed) > 0
            clean = []
            for x in arr:
                if not isinstance(x, str):
                    continue
                try:
                    rp = os.path.realpath(x.strip())
                except OSError:
                    continue
                if use_allowlist:
                    if rp in allowed:
                        clean.append(rp)
                elif os.path.isdir(rp):
                    clean.append(rp)
            dest = pathlib.Path.home() / ".cursor-setup" / "dashboard-favorites.json"
            try:
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text(json.dumps(clean, ensure_ascii=False), encoding="utf-8")
            except OSError:
                self.send_response(500)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                return
            self.send_response(204)
            self.end_headers()
            return
        if p == "/workspace-order-save":
            al = os.environ.get("CURSOR_DASH_ALLOWLIST", "")
            allowed = set()
            if al and os.path.isfile(al):
                with open(al, encoding="utf-8", errors="replace") as fp:
                    for line in fp:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            allowed.add(os.path.realpath(line))
                        except OSError:
                            continue
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8", errors="replace")
            try:
                arr = json.loads(body)
            except json.JSONDecodeError:
                self.send_response(400)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                return
            if not isinstance(arr, list):
                self.send_response(400)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                return
            use_allowlist = len(allowed) > 0
            clean = []
            seen = set()
            for x in arr:
                if not isinstance(x, str):
                    continue
                try:
                    rp = os.path.realpath(x.strip())
                except OSError:
                    continue
                if rp in seen:
                    continue
                if use_allowlist:
                    if rp in allowed:
                        clean.append(rp)
                        seen.add(rp)
                elif os.path.isdir(rp):
                    clean.append(rp)
                    seen.add(rp)
            dest = pathlib.Path.home() / ".cursor-setup" / "dashboard-workspace-order.json"
            try:
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text(json.dumps(clean, ensure_ascii=False), encoding="utf-8")
            except OSError:
                self.send_response(500)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                return
            self.send_response(204)
            self.end_headers()
            return
        if p == "/dashboard-stop":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())

            def _stop():
                time.sleep(0.2)
                self.server.shutdown()

            threading.Thread(target=_stop, daemon=True).start()
            return
        if p == "/launch-setup":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            inner = "cd {} && /bin/bash {} --full-wizard".format(
                shlex.quote(root),
                shlex.quote(setup),
            )
            self._run_term(inner, auto_close=False)
            return
        if p == "/workspace-add-folder":
            ck = (self.headers.get("Cookie", "") or "").replace(" ", "")
            pr_en = "cursor_dash_lang=en" in ck
            pr = (
                "Choose a project folder to add to the list"
                if pr_en
                else "추가할 프로젝트 폴더를 선택하세요"
            )
            scr = 'POSIX path of (choose folder with prompt "' + pr.replace("\\", "\\\\").replace('"', '\\"') + '")'
            inner = (
                "mkdir -p \"$HOME/.cursor-setup\" && f=\"$HOME/.cursor-setup/workspaces.txt\" && touch \"$f\" && "
                "p=$(osascript -e "
                + shlex.quote(scr)
                + " 2>/dev/null) && "
                "if [[ -n \"$p\" ]]; then r=$(cd \"$p\" 2>/dev/null && pwd -P); "
                "[[ -n \"$r\" ]] && (grep -Fxq \"$r\" \"$f\" 2>/dev/null || echo \"$r\" >> \"$f\"); fi"
            )
            self._run_term(inner, auto_close=True)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(self._html_ok())
            return
        if p.startswith("/action/"):
            uid = os.getuid()
            ag = os.path.expanduser("~/.local/bin/agent")
            agq = shlex.quote(ag)
            if p == "/action/open-user-workspaces":
                ws = pathlib.Path.home() / ".cursor-setup" / "workspaces.txt"
                try:
                    ws.parent.mkdir(parents=True, exist_ok=True)
                    ws.touch(exist_ok=True)
                except OSError:
                    pass
                inner = "open -e " + shlex.quote(str(ws))
                self._run_term(inner, auto_close=True)
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(self._html_ok())
                return
            if p == "/action/open-user-services-jsonl":
                jf = pathlib.Path.home() / ".cursor-setup" / "workspace-services.jsonl"
                try:
                    jf.parent.mkdir(parents=True, exist_ok=True)
                    jf.touch(exist_ok=True)
                except OSError:
                    pass
                inner = "open -e " + shlex.quote(str(jf))
                self._run_term(inner, auto_close=True)
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(self._html_ok())
                return
            if p == "/action/open-cloudflared-config":
                cf = pathlib.Path.home() / ".cloudflared" / "config.yml"
                try:
                    cf.parent.mkdir(parents=True, exist_ok=True)
                    cf.touch(exist_ok=True)
                except OSError:
                    pass
                inner = "open -e " + shlex.quote(str(cf))
                self._run_term(inner, auto_close=True)
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.end_headers()
                self.wfile.write(self._html_ok())
                return
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
                "/action/worker-kickstart": (
                    "echo '=== Cursor agent workers ==='; echo ''; "
                    "uid=$(id -u); n=0; "
                    "shopt -s nullglob; "
                    "for p in \"$HOME/Library/LaunchAgents\"/com.cursor.agent.worker.plist "
                    "\"$HOME/Library/LaunchAgents\"/com.cursor.agent.worker.*.plist; do "
                    '[[ -f "$p" ]] || continue; '
                    'lb=$(plutil -extract Label raw "$p" 2>/dev/null) || continue; '
                    'echo "-- $lb"; '
                    'if launchctl kickstart -k "gui/$uid/$lb" 2>&1; then echo "   OK"; else echo "   FAILED"; fi; '
                    "n=$((n+1)); done; shopt -u nullglob; "
                    "if [[ \"$n\" -eq 0 ]]; then echo '(No worker plists — run Set up this folder on each project.)'; fi; "
                    "echo ''; echo 'Closing in 4 seconds...'; sleep 4"
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
    host = os.environ.get("CURSOR_DASH_HOST", "127.0.0.1")
    try:
        H._regen_cooldown_sec = float(os.environ.get("CURSOR_DASH_REGEN_COOLDOWN_SEC", "2.5"))
    except (TypeError, ValueError):
        H._regen_cooldown_sec = 2.5
    if H._regen_cooldown_sec < 0:
        H._regen_cooldown_sec = 0.0
    H._last_regen_time = time.time()
    httpd = DashServer((host, port), H)
    shown_host = host
    if host in ("0.0.0.0", "::"):
        shown_host = "127.0.0.1"
    print("[정보] 대시보드 http://{}:{}/ (종료: Ctrl+C)".format(shown_host, port), flush=True)
    if host in ("0.0.0.0", "::"):
        lip = _lan_ipv4()
        if lip:
            print("[정보] LAN 접근 주소: http://{}:{}/".format(lip, port), flush=True)
    httpd.serve_forever()

if __name__ == "__main__":
    main()
'''
sys.stdout.write(textwrap.dedent(code))
PY
}

dashboard_server_main_blocking() {
  local root="${CURSOR_SETUP_ROOT:-$ROOT}"
  local port html allow py preferred bind_host
  if ! command_exists python3; then
    log_err "대시보드 서버에 python3 가 필요합니다."
    return 1
  fi
  # ~/.cursor-setup/dashboard-bind-lan 파일이 있으면 매번 LAN 바인딩(0.0.0.0) — CURSOR_DASH_HOST 가 없을 때만
  if [[ -z "${CURSOR_DASH_HOST:-}" && "${CURSOR_DASH_LAN:-0}" != "1" && -f "${HOME}/.cursor-setup/dashboard-bind-lan" ]]; then
    CURSOR_DASH_LAN=1
  fi
  preferred="${CURSOR_DASH_PORT:-58741}"
  if [[ -n "${CURSOR_DASH_HOST:-}" ]]; then
    bind_host="$CURSOR_DASH_HOST"
  elif [[ "${CURSOR_DASH_LAN:-0}" == "1" ]]; then
    bind_host="0.0.0.0"
  else
    bind_host="127.0.0.1"
  fi
  dashboard_free_listen_port "$preferred"
  if python3 -c "import socket; s=socket.socket(); s.bind(('$bind_host', int('$preferred'))); s.close()" 2>/dev/null; then
    port="$preferred"
  else
    port="$(python3 -c "import socket; s=socket.socket(); s.bind(('$bind_host',0)); print(s.getsockname()[1]); s.close()")"
    log_info "포트 ${preferred} 을(를) 비울 수 없어 임시 포트 ${port} 로 뜹니다."
    log_info "접속 주소는 아래 http://…:${port}/ 만 쓰면 됩니다. ${preferred} 는 이전 대시보드 등이 붙잡고 있을 수 있습니다."
  fi
  html="$(mktemp).html"
  allow="$(mktemp)"
  py="$(mktemp).py"
  dashboard_write_allowlist_file "$allow"
  local setup_cmd="$root/setup"
  [[ -f "$setup_cmd" ]] || setup_cmd="$root/MacMini-Cursor-Setup.command"
  export CURSOR_SETUP_EXEC_HINT="$setup_cmd"
  # HTML 생성 시 사이드바에 LAN 링크·바인드 정보를 쓰려면 이 시점에 포트·호스트가 있어야 함
  export CURSOR_DASH_PORT="$port"
  export CURSOR_DASH_HOST="$bind_host"
  "$setup_cmd" --_cursor-setup-write-dash "$html" || {
    log_err "대시보드 HTML 생성 실패"
    rm -f "$allow" "$py"
    return 1
  }
  _dashboard_server_write_py "$py"
  chmod +x "$py" 2>/dev/null || true

  export CURSOR_DASH_HTML="$html"
  export CURSOR_DASH_ALLOWLIST="$allow"
  export CURSOR_SETUP_SCRIPT="$setup_cmd"
  export CURSOR_SETUP_ROOT="$root"

  _dashboard_cleanup() {
    rm -f "$html" "$allow" "$py" 2>/dev/null || true
  }
  trap '_dashboard_cleanup' EXIT INT TERM

  if [[ "${CURSOR_DASH_OPEN_BROWSER:-1}" != "0" ]]; then
    ( sleep 0.2 && open "http://127.0.0.1:${port}/" ) &
  fi
  if [[ "$bind_host" != "127.0.0.1" && "$bind_host" != "::1" && "$bind_host" != "localhost" ]]; then
    log_warn "대시보드가 LAN 에 노출됩니다 (${bind_host}:${port}). 신뢰 네트워크에서만 사용하세요."
  fi
  python3 "$py"
}
