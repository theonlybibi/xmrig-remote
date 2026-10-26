#!/usr/bin/env python3
"""Minimal HTTP API to monitor/control ONE systemd unit (xmrig) and set its RandomX thread count.

Endpoints (Authorization: Bearer <token>):
  GET  /status                 -> service state + current/max thread count
  POST /start | /stop | /restart
  POST /threads                -> body {"threads": N, "restart": true}

Stdlib only.
"""
import hmac
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UNIT = os.environ.get("XMRIG_UNIT", "xmrig.service")
HOST = os.environ.get("API_HOST", "127.0.0.1")      # safe default: local only
PORT = int(os.environ.get("API_PORT", "8080"))
TOKEN = os.environ.get("API_TOKEN", "")
CONFIG_OVERRIDE = os.environ.get("XMRIG_CONFIG", "")            # explicit config.json path
STATE_DIR = os.environ.get("STATE_DIRECTORY", "").split(":")[0]  # set by systemd (StateDirectory=)
ACTIONS = {"start", "stop", "restart"}

MAX_FAILS = 10          # failed auth attempts before an IP is blocked
BLOCK_SECONDS = 300     # block duration
REQUEST_TIMEOUT = 10    # socket timeout per connection (anti-slowloris)
MAX_BODY = 1024         # max request body (bytes)
MAX_CONFIG_BYTES = 1_000_000
SEARCH_DEPTH = 4
SEARCH_MAX_ENTRIES = 5000

if not re.fullmatch(r"[A-Za-z0-9_.@-]+\.service", UNIT):
    sys.exit("XMRIG_UNIT must look like 'name.service'")

_fails = {}             # ip -> [failed_count, blocked_until]
_lock = threading.Lock()
_cfg_lock = threading.Lock()
_search_cache = {}      # base dir -> (result, timestamp)


# ---------------------------------------------------------------- auth helpers
def is_blocked(ip):
    with _lock:
        e = _fails.get(ip)
        return bool(e and e[1] > time.time())


def record_failure(ip):
    now = time.time()
    with _lock:
        if len(_fails) > 10000:   # keep memory bounded
            for k in [k for k, v in _fails.items() if v[1] < now]:
                del _fails[k]
        e = _fails.setdefault(ip, [0, 0.0])
        e[0] += 1
        if e[0] >= MAX_FAILS:
            e[0] = 0
            e[1] = now + BLOCK_SECONDS


def clear_failures(ip):
    with _lock:
        _fails.pop(ip, None)


# --------------------------------------------------------------------- systemd
def systemctl(*args):
    return subprocess.run(["systemctl", *args], capture_output=True, text=True, timeout=20)


def show(props):
    out = systemctl("show", UNIT, "-p", props).stdout
    return dict(l.split("=", 1) for l in out.splitlines() if "=" in l)


# ------------------------------------------------------------ config discovery
class ConfigError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def _config_from_unit(d):
    """Return (explicit_config_path_or_None, base_dir) from ExecStart/WorkingDirectory."""
    m = re.search(r"path=(\S+) ; argv\[\]=(.*?) ; ignore_errors=", d.get("ExecStart", ""))
    exe = m.group(1) if m else ""
    try:
        args = shlex.split(m.group(2)) if m else []
    except ValueError:
        args = []
    wd = d.get("WorkingDirectory", "").lstrip("!-")
    if wd in ("", "~"):
        wd = ""
    base = wd or (os.path.dirname(exe) if exe else "")
    cfg = None
    for i, a in enumerate(args):
        if a.startswith("--config="):
            cfg = a.split("=", 1)[1]
        elif a in ("--config", "-c") and i + 1 < len(args):
            cfg = args[i + 1]
    if cfg:
        cfg = os.path.normpath(cfg if os.path.isabs(cfg) else os.path.join(base or "/", cfg))
    return cfg, base


def _search(base):
    """Recursive search for config.json below `base` (bounded, no symlinks)."""
    now = time.time()
    hit = _search_cache.get(base)
    if hit and now - hit[1] < 300:
        return hit[0]
    matches, seen = [], 0
    root_depth = base.rstrip("/").count("/")
    for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
        depth = dirpath.rstrip("/").count("/") - root_depth
        seen += len(dirnames) + len(filenames)
        if depth >= SEARCH_DEPTH or seen > SEARCH_MAX_ENTRIES:
            dirnames[:] = []
        if "config.json" in filenames:
            matches.append((depth, os.path.join(dirpath, "config.json")))
    matches.sort()
    result = None
    if matches and (len(matches) == 1 or matches[0][0] < matches[1][0]):
        result = matches[0][1]            # unique at the shallowest depth
    _search_cache[base] = (result, now)
    return result


def find_config(d):
    """1) XMRIG_CONFIG  2) --config in the unit's ExecStart  3) <dir>/config.json  4) recursive search."""
    if CONFIG_OVERRIDE:
        return CONFIG_OVERRIDE
    explicit, base = _config_from_unit(d)
    if explicit:
        return explicit
    if base and base != "/":
        cand = os.path.join(base, "config.json")
        if os.path.isfile(cand):
            return cand
        return _search(base)
    return None


# ------------------------------------------------------------------ cpu/threads
def allowed_cpus():
    try:
        return sorted(os.sched_getaffinity(0))
    except AttributeError:
        return list(range(os.cpu_count() or 1))


def max_threads():
    return len(allowed_cpus())


def cpu_order():
    """Logical CPUs ordered so that each physical core is used once before its SMT siblings."""
    cpus = allowed_cpus()
    cpuset, seen, groups = set(cpus), set(), []
    for c in cpus:
        if c in seen:
            continue
        sibs = [c]
        try:
            with open("/sys/devices/system/cpu/cpu%d/topology/thread_siblings_list" % c) as f:
                sibs = []
                for part in f.read().strip().split(","):
                    a, _, b = part.partition("-")
                    sibs += range(int(a), int(b or a) + 1)
        except (OSError, ValueError):
            pass
        sibs = sorted(s for s in set(sibs) if s in cpuset) or [c]
        seen.update(sibs)
        groups.append(sibs)
    out = []
    for r in range(max(len(g) for g in groups)):
        out += [g[r] for g in groups if r < len(g)]
    return out


# --------------------------------------------------------- config.json handling
def read_config(path):
    try:
        st = os.stat(path)
        if not stat.S_ISREG(st.st_mode) or st.st_size > MAX_CONFIG_BYTES:
            raise ConfigError("invalid_file")
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        raise ConfigError("not_found")
    except PermissionError:
        raise ConfigError("permission_denied")
    except (OSError, UnicodeDecodeError):
        raise ConfigError("unreadable")
    try:
        data = json.loads(text)
    except ValueError:
        raise ConfigError("invalid_json")
    return text, data


def thread_count(data):
    cpu = data.get("cpu") if isinstance(data, dict) else None
    rx = cpu.get("rx") if isinstance(cpu, dict) else None
    return len(rx) if isinstance(rx, list) else None


# Tiny JSON scanner: lets us replace ONE value without reformatting the whole file.
def _ws(t, i):
    while i < len(t) and t[i] in " \t\r\n":
        i += 1
    return i


def _end_string(t, i):
    i += 1
    while t[i] != '"':
        i += 2 if t[i] == "\\" else 1
    return i + 1


def _end_value(t, i):
    if t[i] == '"':
        return _end_string(t, i)
    if t[i] in "{[":
        depth = 0
        while True:
            ch = t[i]
            if ch == '"':
                i = _end_string(t, i)
                continue
            if ch in "{[":
                depth += 1
            elif ch in "}]":
                depth -= 1
            i += 1
            if depth == 0:
                return i
    while i < len(t) and t[i] not in ",}] \t\r\n":
        i += 1
    return i


def _members(t, start):
    """Members of the object starting at t[start]=='{' -> ([(key, key_start, val_start, val_end)], close_index)."""
    i, res = _ws(t, start + 1), []
    while t[i] != "}":
        ks = i
        ke = _end_string(t, i)
        key = json.loads(t[ks:ke])
        i = _ws(t, ke)
        if t[i] != ":":
            raise ValueError
        i = _ws(t, i + 1)
        ve = _end_value(t, i)
        res.append((key, ks, i, ve))
        i = _ws(t, ve)
        if t[i] == ",":
            i = _ws(t, i + 1)
    return res, i


def _replace_rx(text, rx):
    new = "[" + ", ".join(str(int(c)) for c in rx) + "]"
    try:
        i = _ws(text, 0)
        members, _ = _members(text, i)
        cpu = [m for m in members if m[0] == "cpu"]
        if not cpu or text[cpu[-1][2]] != "{":
            raise ConfigError("unsupported_config")
        cs = cpu[-1][2]
        cmembers, close = _members(text, cs)
        old = [m for m in cmembers if m[0] == "rx"]
        if old:
            return text[:old[-1][2]] + new + text[old[-1][3]:]
        if not cmembers:
            return text[:cs + 1] + '"rx": ' + new + text[cs + 1:]
        _, ks, _, ve = cmembers[-1]
        if "\n" in text[cs:close]:
            ls = text.rfind("\n", 0, ks) + 1
            indent = text[ls:ks] if not text[ls:ks].strip() else ""
            sep = ",\n" + indent
        else:
            sep = ", "
        return text[:ve] + sep + '"rx": ' + new + text[ve:]
    except (IndexError, ValueError):
        raise ConfigError("edit_failed")


def set_threads(path, n):
    """Set cpu.rx to the first n CPUs (physical cores first). Only that value is touched."""
    with _cfg_lock:
        text, data = read_config(path)
        if not isinstance(data, dict) or not isinstance(data.get("cpu"), dict):
            raise ConfigError("unsupported_config")
        rx = cpu_order()[:n]
        new_text = _replace_rx(text, rx)
        # Safety check: the new file must equal the old one with ONLY cpu.rx changed.
        expected = json.loads(text)
        expected["cpu"]["rx"] = rx
        try:
            if json.loads(new_text) != expected:
                raise ConfigError("edit_failed")
        except ValueError:
            raise ConfigError("edit_failed")
        if STATE_DIR:                                   # keep one backup in the private state dir
            try:
                fd = os.open(os.path.join(STATE_DIR, "config.json.bak"),
                             os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as b:
                    b.write(text)
            except OSError:
                raise ConfigError("backup_failed")
        raw = new_text.encode("utf-8")
        try:                                            # in place: needs write access to the FILE only
            with open(path, "r+b") as f:
                f.seek(0)
                f.write(raw)
                f.truncate()
                f.flush()
                os.fsync(f.fileno())
        except PermissionError:
            raise ConfigError("permission_denied")
        except OSError:
            raise ConfigError("write_failed")
        return rx


# ----------------------------------------------------------------------- status
def status():
    d = show("ActiveState,SubState,MainPID,ActiveEnterTimestamp,Result,NRestarts,ExecStart,WorkingDirectory")
    try:
        pid = int(d.get("MainPID", "0") or 0)
    except ValueError:
        pid = 0
    threads, cfg_err = None, None
    path = find_config(d)
    if path is None:
        cfg_err = "config_not_found"
    else:
        try:
            threads = thread_count(read_config(path)[1])   # None => rx not set (xmrig auto mode)
        except ConfigError as e:
            cfg_err = e.code
    return {
        "unit": UNIT,
        "state": d.get("ActiveState", "unknown"),   # active / inactive / failed / activating...
        "substate": d.get("SubState", ""),
        "pid": pid,
        "since": d.get("ActiveEnterTimestamp", ""),
        "result": d.get("Result", ""),
        "restarts": d.get("NRestarts", ""),
        "threads": threads,
        "max_threads": max_threads(),
        "config_error": cfg_err,
    }


# ------------------------------------------------------------------------- HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = "xmrig-api"
    sys_version = ""
    timeout = REQUEST_TIMEOUT

    def _send(self, code, body, extra=None):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def _authed(self):
        ip = self.client_address[0]
        if is_blocked(ip):
            self._send(429, {"error": "too many failed attempts"},
                       {"Retry-After": str(BLOCK_SECONDS)})
            return False
        h = self.headers.get("Authorization", "")
        given = h[7:].encode("utf-8", "replace") if h.startswith("Bearer ") else b""
        if not hmac.compare_digest(given, TOKEN.encode()):
            record_failure(ip)
            self._send(401, {"error": "unauthorized"})
            return False
        clear_failures(ip)
        return True

    def _json_body(self):
        try:
            n = int(self.headers.get("Content-Length", "0"))
            if not 0 < n <= MAX_BODY:
                return None
            obj = json.loads(self.rfile.read(n))
        except (ValueError, OSError):
            return None
        return obj if isinstance(obj, dict) else None

    def do_GET(self):
        if not self._authed():
            return
        if self.path.split("?", 1)[0] == "/status":
            self._send(200, status())
        else:
            self._send(404, {"error": "not found"})

    def _post_threads(self):
        body = self._json_body()
        t = body.get("threads") if body else None
        restart = body.get("restart", True) if body else True
        if (body is None or not isinstance(t, int) or isinstance(t, bool)
                or not isinstance(restart, bool)):
            return self._send(400, {"error": "expected JSON {\"threads\": <int>, \"restart\": <bool, optional>}"})
        mx = max_threads()
        if not 1 <= t <= mx:
            return self._send(400, {"error": "threads must be between 1 and %d" % mx})
        try:
            d = show("ActiveState,ExecStart,WorkingDirectory")
            path = find_config(d)
            if path is None:
                raise ConfigError("config_not_found")
            set_threads(path, t)
        except ConfigError as e:
            code = 404 if e.code in ("not_found", "config_not_found") else \
                   422 if e.code in ("invalid_json", "unsupported_config", "invalid_file") else 500
            print("set threads failed: %s" % e.code, flush=True)
            return self._send(code, {"error": e.code})
        restarted = False
        if restart and d.get("ActiveState") in ("active", "activating"):
            try:
                restarted = systemctl("restart", UNIT).returncode == 0
            except (subprocess.TimeoutExpired, OSError):
                restarted = False
        out = status()
        out["restarted"] = restarted
        self._send(200, out)

    def do_POST(self):
        if not self._authed():
            return
        action = self.path.split("?", 1)[0].strip("/")
        if action == "threads":
            return self._post_threads()
        if action not in ACTIONS:
            return self._send(404, {"error": "not found"})
        try:
            r = systemctl(action, UNIT)
        except subprocess.TimeoutExpired:
            return self._send(504, {"error": "systemctl timed out"})
        except OSError:
            return self._send(500, {"error": "systemctl unavailable"})
        if r.returncode != 0:
            print("systemctl %s %s failed: %s" % (action, UNIT, r.stderr.strip()), flush=True)
            return self._send(500, {"error": "action failed"})   # details stay in the log
        self._send(200, status())

    def log_message(self, fmt, *a):
        print("%s - %s" % (self.client_address[0], fmt % a), flush=True)


def main():
    if "--find-config" in sys.argv:           # used by install.sh
        path = find_config(show("ExecStart,WorkingDirectory"))
        if path:
            print(path)
        return
    if len(TOKEN) < 32:
        sys.exit("API_TOKEN must be set and at least 32 characters long")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
