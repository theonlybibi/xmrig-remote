#!/usr/bin/env python3
"""Minimal HTTP API to monitor and control ONE systemd unit (stdlib only)."""
import hmac
import json
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UNIT = os.environ.get("XMRIG_UNIT", "xmrig.service")
HOST = os.environ.get("API_HOST", "127.0.0.1")      # safe default: local only
PORT = int(os.environ.get("API_PORT", "8080"))
TOKEN = os.environ.get("API_TOKEN", "")
ACTIONS = {"start", "stop", "restart"}

MAX_FAILS = 10          # failed auth attempts before an IP is blocked
BLOCK_SECONDS = 300     # block duration
REQUEST_TIMEOUT = 10    # socket timeout per connection (anti-slowloris)

if not re.fullmatch(r"[A-Za-z0-9_.@-]+\.service", UNIT):
    sys.exit("XMRIG_UNIT must look like 'name.service'")
if len(TOKEN) < 32:
    sys.exit("API_TOKEN must be set and at least 32 characters long")
TOKEN_BYTES = TOKEN.encode()

_fails = {}             # ip -> [failed_count, blocked_until]
_lock = threading.Lock()


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


def systemctl(*args):
    return subprocess.run(["systemctl", *args], capture_output=True, text=True, timeout=20)


def status():
    props = "ActiveState,SubState,MainPID,ActiveEnterTimestamp,Result,NRestarts"
    out = systemctl("show", UNIT, "-p", props).stdout
    d = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
    try:
        pid = int(d.get("MainPID", "0") or 0)
    except ValueError:
        pid = 0
    return {
        "unit": UNIT,
        "state": d.get("ActiveState", "unknown"),   # active / inactive / failed / activating...
        "substate": d.get("SubState", ""),
        "pid": pid,
        "since": d.get("ActiveEnterTimestamp", ""),
        "result": d.get("Result", ""),
        "restarts": d.get("NRestarts", ""),
    }


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
        if not hmac.compare_digest(given, TOKEN_BYTES):
            record_failure(ip)
            self._send(401, {"error": "unauthorized"})
            return False
        clear_failures(ip)
        return True

    def do_GET(self):
        if not self._authed():
            return
        if self.path.split("?", 1)[0] == "/status":
            self._send(200, status())
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._authed():
            return
        action = self.path.split("?", 1)[0].strip("/")
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


if __name__ == "__main__":
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
