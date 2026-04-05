#!/usr/bin/env bash
# 폴더별 실행 파일·명령 (~/.cursor-setup/workspace-services.jsonl) — exec(스크립트/ .command) 또는 shell + port

workspace_services_jsonl_path() {
  printf '%s\n' "${HOME}/.cursor-setup/workspace-services.jsonl"
}

# stdout: JSON 한 줄 {shell, port, disp, exec} — 탭/개행이 값에 있어도 깨지지 않음. jsonl 에 같은 path 가 여러 줄이면 마지막 줄이 우선.
workspace_service_config_line() {
  local abs="${1:-}"
  abs=$(cd "$abs" 2>/dev/null && pwd -P) || {
    printf '%s\n' '{"shell":"","port":"","disp":"","exec":""}'
    return 0
  }
  _WS_SVC_LOOKUP="$abs" python3 <<'PY'
import json, os, pathlib, shlex
p = pathlib.Path(os.environ["_WS_SVC_LOOKUP"]).resolve()
f = pathlib.Path.home() / ".cursor-setup" / "workspace-services.jsonl"
EMPTY = {"shell": "", "port": "", "disp": "", "exec": ""}


def _paths_match(ap, target):
    if ap == target:
        return True
    try:
        if ap.exists() and target.exists() and os.path.samefile(ap, target):
            return True
    except OSError:
        pass
    return os.path.normcase(str(ap)) == os.path.normcase(str(target))


def coerce_port(pv):
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


def port_from_obj(o):
    if not isinstance(o, dict):
        return ""
    for key in ("port", "devPort", "listen", "listenPort"):
        if key not in o:
            continue
        pn = coerce_port(o.get(key))
        if pn is not None:
            return str(pn)
    return ""


def _resolve_ep(ex):
    ep = pathlib.Path(ex).expanduser()
    try:
        return ep.resolve(strict=False)
    except TypeError:
        try:
            return ep.resolve()
        except OSError:
            pass
    except OSError:
        pass
    try:
        return pathlib.Path(os.path.realpath(ex))
    except OSError:
        return pathlib.Path(ex)


def effective_cmd_label_exec(o):
    sh = (o.get("shell") or "").strip().replace("\r", "").replace("\n", " ")
    ex = (o.get("exec") or "").strip().replace("\r", "")
    if ex:
        ep = _resolve_ep(ex)
        exec_abs = str(ep)
        cmd = "bash " + shlex.quote(exec_abs)
        disp = ep.name if ep.name else ex
        return cmd, disp, exec_abs
    if sh:
        label = sh if len(sh) <= 56 else sh[:56] + "…"
        return sh, label, ""
    return "", "", ""


if not f.is_file():
    print(json.dumps(EMPTY, ensure_ascii=False))
else:
    last = None
    for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
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
        if _paths_match(ap, p):
            last = o
    if last is None:
        print(json.dumps(EMPTY, ensure_ascii=False))
    else:
        cmd, disp, ex_abs = effective_cmd_label_exec(last)
        port_s = port_from_obj(last)
        print(
            json.dumps(
                {"shell": cmd, "port": port_s, "disp": disp, "exec": ex_abs},
                ensure_ascii=False,
            )
        )
PY
}

# 포트에 서버가 떠 있는지: LISTEN(lsof) 후 127.0.0.1 / ::1 연결 시도(nc)
workspace_service_port_listening() {
  local prt="${1:-}"
  [[ "$prt" =~ ^[0-9]+$ ]] || return 1
  lsof -nP -iTCP:"$prt" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  lsof -nP -iTCP:"$prt" 2>/dev/null | command grep -q LISTEN && return 0
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$prt" >/dev/null 2>&1 && return 0
    nc -z ::1 "$prt" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# stdin: discover_workspace_paths 와 동일한 한 줄당 한 경로 → LISTEN_JSON_OUT 에 JSON { "실경로": [포트,…], … }
# 주의: python heredoc 이 프로세스 stdin 을 쓰므로 파이프 내용은 임시 파일로 넘긴다.
workspace_listen_map_build() {
  local dest="${1:-}"
  [[ -n "$dest" ]] || return 1
  local _ws_paths
  _ws_paths=$(mktemp)
  cat > "$_ws_paths"
  LISTEN_JSON_OUT="$dest" WS_PATHS_FILE="$_ws_paths" python3 <<'PY'
import hashlib, json, os, subprocess, sys, time

def lsof_listen_rows():
    r = subprocess.run(
        ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"],
        capture_output=True,
        text=True,
        errors="replace",
        timeout=25,
    )
    if not (r.stdout or "").strip():
        return []
    # macOS 등에서 프로젝트와 무관한 LISTEN (미디어·시스템·GitHub Desktop 등)
    skip_cmd = frozenset(
        {
            "rapportd",
            "ControlCe",
            "ControlCenter",
            "GitHub",
        }
    )
    rows = []
    for line in r.stdout.strip().splitlines()[1:]:
        parts = line.split()
        if len(parts) < 4:
            continue
        if parts[0] in skip_cmd:
            continue
        try:
            pid = int(parts[1])
        except ValueError:
            continue
        if "(LISTEN)" not in parts:
            continue
        try:
            idx = parts.index("(LISTEN)")
        except ValueError:
            continue
        if idx < 1:
            continue
        addr = parts[idx - 1]
        if not addr or ":" not in addr:
            continue
        if "]:" in addr:
            port_s = addr.rsplit(":", 1)[-1].rstrip("]")
        else:
            port_s = addr.rsplit(":", 1)[-1]
        if not port_s.isdigit():
            continue
        rows.append((pid, int(port_s)))
    return rows


def get_pid_cwd(pid):
    r = subprocess.run(
        ["lsof", "-a", "-p", str(pid), "-d", "cwd"],
        capture_output=True,
        text=True,
        errors="replace",
        timeout=5,
    )
    if r.returncode != 0 or not (r.stdout or "").strip():
        return None
    lines = r.stdout.strip().splitlines()
    if len(lines) < 2:
        return None
    parts = lines[1].split()
    if len(parts) < 9:
        return None
    path = " ".join(parts[8:])
    try:
        return os.path.realpath(path)
    except OSError:
        return None


def get_pid_command(pid):
    for fmt in ("args=", "command="):
        r = subprocess.run(
            ["ps", "-p", str(pid), "-ww", "-o", fmt],
            capture_output=True,
            text=True,
            errors="replace",
            timeout=4,
        )
        if r.returncode != 0:
            continue
        lines = [ln.strip() for ln in (r.stdout or "").splitlines() if ln.strip()]
        if not lines:
            continue
        if len(lines) >= 2 and lines[0].upper() in ("COMMAND", "ARGS"):
            lines = lines[1:]
        if lines:
            return " ".join(lines)
    return ""


def _home_dir_norm():
    try:
        return os.path.normcase(os.path.realpath(os.path.expanduser("~")).rstrip(os.sep))
    except OSError:
        return os.path.normcase(os.path.expanduser("~").rstrip(os.sep))


def cwd_matches_ws(cwd, ws, all_paths):
    if not cwd:
        return False
    sep = os.sep
    cw = os.path.normcase(cwd.rstrip(sep))
    try:
        w_abs = os.path.realpath(ws)
    except OSError:
        w_abs = ws
    wn = os.path.normcase(w_abs.rstrip(sep))
    home = _home_dir_norm()
    if cw == home and wn != home:
        return False
    if cw == wn:
        return True
    if cw.startswith(wn + sep):
        return True
    try:
        parent = os.path.normcase(os.path.dirname(w_abs.rstrip(sep)))
        if parent != cw:
            pass
        else:
            same_parent = []
            for p in all_paths:
                try:
                    pr = os.path.realpath(p)
                    pp = os.path.normcase(os.path.dirname(pr.rstrip(sep)))
                    if pp == parent:
                        same_parent.append(pr)
                except OSError:
                    continue
            if len(same_parent) == 1 and os.path.normcase(
                w_abs.rstrip(sep)
            ) == os.path.normcase(same_parent[0].rstrip(sep)):
                return True
    except (OSError, ValueError):
        pass
    return False


def load_ws_exec_hints(paths):
    hints = {p: set() for p in paths}
    jf = os.path.join(os.path.expanduser("~"), ".cursor-setup", "workspace-services.jsonl")
    if not os.path.isfile(jf):
        return hints
    with open(jf, encoding="utf-8", errors="replace") as fp:
        for line in fp:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            rawp = (o.get("path") or "").replace("\r", "").strip()
            if not rawp:
                continue
            try:
                ap = os.path.realpath(os.path.expanduser(rawp))
            except OSError:
                continue
            if ap not in hints:
                continue
            ex = (o.get("exec") or "").strip()
            if ex:
                hints[ap].add(os.path.basename(ex))
            sh = (o.get("shell") or "").replace("\r", "").strip()
            for tok in sh.replace("\t", " ").split():
                if tok.startswith("/") and os.sep in tok:
                    hints[ap].add(os.path.basename(tok))
    return hints


def cmdline_touches_any_hint(cmd, hint_set):
    if not cmd or not hint_set:
        return False
    cc = os.path.normcase(cmd)
    sep = os.sep
    for hint in hint_set:
        if not hint or len(hint) < 2:
            continue
        hc = os.path.normcase(hint)
        if hc not in cc:
            continue
        idx = 0
        while True:
            j = cc.find(hc, idx)
            if j < 0:
                break
            end = j + len(hc)
            before_ok = j == 0 or cc[j - 1] in (
                sep,
                " ",
                "\t",
                '"',
                "'",
                ":",
                "(",
                "[",
                "=",
            )
            after_ok = end >= len(cc) or cc[end] in (
                sep,
                " ",
                "\t",
                '"',
                "'",
                ":",
                ")",
                "]",
                ",",
                ";",
            )
            if before_ok and after_ok:
                return True
            idx = j + 1
    return False


_BORING_WS_BASENAMES = frozenset(
    {
        "dev",
        "src",
        "app",
        "web",
        "api",
        "lib",
        "doc",
        "test",
        "tmp",
        "temp",
        "core",
        "home",
        "user",
        "code",
        "work",
        "main",
        "empty",
    }
)


def _cmdline_excludes_ide_listener(cmd):
    c = (cmd or "").lower()
    return "cursor helper" in c or "extension-host" in c or "code helper" in c


def cmdline_touches_workspace_basename(cmd, ws):
    if not cmd or _cmdline_excludes_ide_listener(cmd):
        return False
    base = os.path.basename(ws.rstrip(os.sep))
    if len(base) < 5:
        return False
    if base.lower() in _BORING_WS_BASENAMES:
        return False
    w = base
    wc = os.path.normcase(w)
    cc = os.path.normcase(cmd)
    if wc not in cc:
        return False
    idx = 0
    sep = os.sep
    while True:
        i = cc.find(wc, idx)
        if i < 0:
            return False
        end = i + len(wc)
        if end >= len(cc) or cc[end] in (
            sep,
            " ",
            "\t",
            '"',
            "'",
            ":",
            ")",
            ",",
            ";",
            "[",
            "]",
        ):
            return True
        idx = i + 1


def cmdline_touches_workspace(cmd, ws):
    if not cmd or not ws or len(ws) < 4:
        return False
    w = ws.rstrip(os.sep)
    wc = os.path.normcase(w)
    cc = os.path.normcase(cmd)
    if wc not in cc:
        return False
    idx = 0
    sep = os.sep
    while True:
        i = cc.find(wc, idx)
        if i < 0:
            return False
        end = i + len(wc)
        if end >= len(cc) or cc[end] in (sep, " ", "\t", '"', "'", ":", ")", ",", ";"):
            return True
        idx = i + 1


def get_pid_open_realpaths(pid, max_lines=240):
    r = subprocess.run(
        ["lsof", "-p", str(pid)],
        capture_output=True,
        text=True,
        errors="replace",
        timeout=6,
    )
    if r.returncode != 0 or not (r.stdout or "").strip():
        return []
    out = []
    for line in (r.stdout or "").strip().splitlines()[1 : max_lines + 1]:
        parts = line.split()
        if len(parts) < 9:
            continue
        name = " ".join(parts[8:])
        if name.startswith("["):
            continue
        raw = name.split("->", 1)[0].strip()
        if not raw.startswith("/"):
            continue
        try:
            out.append(os.path.realpath(raw))
        except OSError:
            out.append(raw)
    return out


_lsof_paths_cache = {}


def get_cached_lsof_paths(pid):
    if pid not in _lsof_paths_cache:
        _lsof_paths_cache[pid] = get_pid_open_realpaths(pid)
    return _lsof_paths_cache[pid]


def open_paths_touch_workspace(paths, ws):
    """열린 파일 경로가 이 워크스페이스 디렉터리 아래에 있을 때만 (역방향 부모 매칭 제외)."""
    if not paths:
        return False
    wn = os.path.normcase(ws.rstrip(os.sep))
    wp = wn + os.sep
    for p in paths:
        try:
            pn = os.path.normcase(os.path.realpath(p))
        except OSError:
            pn = os.path.normcase(str(p))
        if pn == wn or pn.startswith(wp):
            return True
    return False


def pid_matches_workspace(pid, ws, cwd_by_pid, cmd_by_pid, all_paths, exec_hints):
    cwd = cwd_by_pid.get(pid)
    if cwd_matches_ws(cwd, ws, all_paths):
        return True
    cmd = cmd_by_pid.get(pid) or ""
    if cmdline_touches_any_hint(cmd, exec_hints.get(ws, ())):
        return True
    if cmdline_touches_workspace(cmd, ws):
        return True
    if cmdline_touches_workspace_basename(cmd, ws):
        return True
    return open_paths_touch_workspace(get_cached_lsof_paths(pid), ws)


def drop_ancestor_workspaces(hits):
    """중첩 경로가 같이 매칭되면 더 깊은(구체적인) 워크스페이스만 남긴다."""
    if len(hits) <= 1:
        return hits
    sep = os.sep
    hits = list(dict.fromkeys(hits))
    hits.sort(key=lambda x: -len(x))
    out = []
    for h in hits:
        hp = h.rstrip(sep) + sep
        if any(o.rstrip(sep).startswith(hp) for o in out):
            continue
        out.append(h)
    return out


paths = []
_ws_file = os.environ.get("WS_PATHS_FILE", "")
if _ws_file:
    with open(_ws_file, encoding="utf-8", errors="replace") as _fp:
        for line in _fp:
            line = line.strip()
            if not line:
                continue
            try:
                paths.append(os.path.realpath(line))
            except OSError:
                continue
else:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            paths.append(os.path.realpath(line))
        except OSError:
            continue
paths = list(dict.fromkeys(paths))


def _listen_cache_ttl():
    try:
        v = float(os.environ.get("CURSOR_DASH_LISTEN_CACHE_SEC", "2.5"))
    except (TypeError, ValueError):
        return 2.5
    return max(0.0, v)


def _listen_cache_key(ps):
    h = hashlib.sha256()
    for p in sorted(ps):
        h.update(p.encode("utf-8", errors="replace"))
        h.update(b"\0")
    h.update((os.environ.get("CURSOR_DASH_PORT") or "").encode("utf-8"))
    h.update(b"\0")
    h.update((os.environ.get("CURSOR_SETUP_ROOT") or "").encode("utf-8"))
    return h.hexdigest()


_listen_ttl = _listen_cache_ttl()
_outp_pre = os.environ.get("LISTEN_JSON_OUT", "")
if _outp_pre and _listen_ttl > 0 and paths:
    _ck = _listen_cache_key(paths)
    _cp = os.path.join(os.path.expanduser("~"), ".cursor-setup", ".dash-listen-cache.json")
    _now = time.time()
    try:
        if os.path.isfile(_cp):
            with open(_cp, encoding="utf-8") as _cfp:
                _cj = json.load(_cfp)
            if (
                isinstance(_cj, dict)
                and _cj.get("k") == _ck
                and isinstance(_cj.get("t"), (int, float))
                and _now - float(_cj["t"]) < _listen_ttl
                and isinstance(_cj.get("r"), dict)
            ):
                with open(_outp_pre, "w", encoding="utf-8") as _ofp:
                    json.dump(_cj["r"], _ofp, ensure_ascii=False)
                sys.exit(0)
    except Exception:
        pass

exec_hints = load_ws_exec_hints(paths)
listen = lsof_listen_rows()
pid_to_ports = {}
for pid, port in listen:
    pid_to_ports.setdefault(pid, set()).add(port)
cwd_by_pid = {}
cmd_by_pid = {}
for pid in list(pid_to_ports.keys()):
    cwd_by_pid[pid] = get_pid_cwd(pid)
    cmd_by_pid[pid] = get_pid_command(pid)
result = {p: [] for p in paths}
for pid, ports in pid_to_ports.items():
    hits = [
        ws
        for ws in paths
        if pid_matches_workspace(pid, ws, cwd_by_pid, cmd_by_pid, paths, exec_hints)
    ]
    hits = drop_ancestor_workspaces(hits)
    if len(hits) == 0:
        continue
    if len(hits) == 1:
        ws0 = hits[0]
        for pt in ports:
            result[ws0].append(pt)
        continue
    if len(hits) > 1:
        cwd = cwd_by_pid.get(pid)
        cmd = cmd_by_pid.get(pid) or ""
        ex = []
        if cwd:
            ncw = os.path.normcase(cwd.rstrip(os.sep))
            for ws in hits:
                if ncw == os.path.normcase(ws.rstrip(os.sep)):
                    ex.append(ws)
        if len(ex) == 1:
            ws0 = ex[0]
            for pt in ports:
                result[ws0].append(pt)
            continue
        cm = [ws for ws in hits if cmdline_touches_workspace(cmd, ws)]
        if len(cm) == 1:
            ws0 = cm[0]
            for pt in ports:
                result[ws0].append(pt)
            continue
# 대시보드 HTTP 포트는 프로젝트 dev 서버와 별개이므로 워크스페이스 LISTEN 목록에 넣지 않는다
# (넣으면 '실행 중'에 대시보드 포트가 같이 뜨고, 포트 끄기로 대시보드까지 죽일 위험이 있음)
for ws in paths:
    result[ws] = sorted(set(result[ws]))
outp = os.environ.get("LISTEN_JSON_OUT", "")
if outp:
    if _listen_ttl > 0 and paths:
        try:
            _cdir = os.path.join(os.path.expanduser("~"), ".cursor-setup")
            os.makedirs(_cdir, exist_ok=True)
            _cpw = os.path.join(_cdir, ".dash-listen-cache.json")
            with open(_cpw, "w", encoding="utf-8") as _cfp:
                json.dump(
                    {"k": _listen_cache_key(paths), "t": time.time(), "r": result},
                    _cfp,
                    ensure_ascii=False,
                )
        except Exception:
            pass
    with open(outp, "w", encoding="utf-8") as fp:
        json.dump(result, fp, ensure_ascii=False)
PY
  rm -f "$_ws_paths"
}

# CURSOR_DASH_LISTEN_MAP 파일 기준, 워크스페이스에 자동 감지된 LISTEN 포트(콤마)
workspace_listen_ports_csv() {
  local ws="$1"
  local mapf="${CURSOR_DASH_LISTEN_MAP:-}"
  [[ -f "$mapf" ]] || return 0
  local rp
  rp=$(cd "$ws" 2>/dev/null && pwd -P) || return 0
  MAPFILE="$mapf" RP="$rp" python3 -c "
import json, os
m = json.load(open(os.environ['MAPFILE'], encoding='utf-8'))
print(','.join(str(p) for p in m.get(os.environ['RP'], [])))
"
}
