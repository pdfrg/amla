#!/usr/bin/env python3
"""Loopback credential broker for Subsonic streams.

Why this exists: Subsonic has no header-based auth -- credentials are request
parameters -- so a stream URL necessarily carries the account token, and that
token is password-equivalent (md5(password + client-chosen salt) verifies for
any salt, so a captured triple is replayable indefinitely). Media players
persist the URLs they are handed: MPD keeps them in its queue and state file,
cliamp in its queue and resume.json. Handing a player a direct Subsonic stream
URL therefore leaks a reusable credential into that player's storage.

This broker keeps the credentials instead. It binds 127.0.0.1 only and serves
  GET|HEAD /<prefix>/s/<songId>
where <prefix> is an unguessable 128-bit capability generated once per install
and `songId` is an opaque Subsonic id. Players receive
  http://127.0.0.1:<port>/<prefix>/s/<songId>
which carries no reusable credential: loopback-only, scoped to a single song
id, and dead as soon as the broker is gone. Upstream requests are POSTs with
the auth parameters in the form body, so the token never appears in a URL on
either hop.

Bounds and validation: one route shape only (strict prefix compare, strict id
charset/length, no query strings, GET/HEAD only), same-origin redirect policy
capped at 3 hops, upstream responses size-capped and time-limited, Range
forwarded so seeking keeps working, and nothing logged to disk.

Lifecycle: a user-scope helper started on demand by the plugin and living as
long as the session, because players hold its URLs in persistent queues (MPD
restores its queue from state_file across restarts). It publishes {port,
prefix} to a 0600 state file so a respawn reuses the same address and URLs
already queued by a player keep resolving.
"""
import fcntl
import hashlib
import hmac
import json
import os
import random
import re
import signal
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Upstream response ceiling. A single lossless track is far below this; the
# cap exists so a faulty server cannot stream unboundedly into a player.
MAX_BYTES = 1024 * 1024 * 1024
UPSTREAM_TIMEOUT = 20
CHUNK = 65536
AUTH_VERSION = "1.16.1"
CLIENT_NAME = "amla-broker"
MAX_REDIRECTS = 3

ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
PREFIX_RE = re.compile(r"^[0-9a-f]{32}$")

STATE = {
    "base": "",
    "user": "",
    "password": "",
    "prefix": "",
    "port": 0,
    "inflight": 0,
}


def log(msg):
    """Diagnostics go to stderr only; never print credentials or URLs."""
    try:
        sys.stderr.write("subsonic_broker: %s\n" % msg)
        sys.stderr.flush()
    except Exception:  # noqa: BLE001
        pass


def acquire_lock(state_path):
    """Take an exclusive lock so a slow first start cannot leave two
    brokers running (the plugin may spawn again while the first is still
    binding). The lock is held for the process lifetime and released by the
    kernel on exit. Returns the fd, or None when another broker holds it."""
    if not state_path:
        return None
    lock_path = state_path + ".lock"
    try:
        os.makedirs(os.path.dirname(lock_path), exist_ok=True)
        fd = os.open(lock_path, os.O_WRONLY | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except OSError:
        return None


def write_state(path, port, prefix):
    """Atomically publish {port, prefix} for the plugin (no credentials)."""
    if not path:
        return
    data = {"pid": os.getpid(), "port": port, "prefix": prefix}
    tmp = path + ".tmp"
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        os.replace(tmp, path)
    except OSError as e:
        log("state write failed: %r" % (e,))


def origin(url):
    p = urllib.parse.urlparse(url)
    default_port = 443 if p.scheme.lower() == "https" else 80
    return (p.scheme.lower(), (p.hostname or "").lower(), p.port or default_port)


class SameOriginRedirects(urllib.request.HTTPRedirectHandler):
    """Follow redirects only back to the configured server's own origin.

    A cross-origin redirect is refused rather than followed: the broker must
    not be usable as a fetch primitive pointed at anything else (and it sends
    no credentials to a redirect target either way). 301/302/303 drop the
    body and become GETs, 307/308 keep method and body; amla asks for raw
    streams, so the former is what a server-side transcode hand-off needs.
    """

    def __init__(self, base_origin):
        super().__init__()
        self.base_origin = base_origin
        self.hops = 0

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self.hops += 1
        if self.hops > MAX_REDIRECTS or origin(newurl) != self.base_origin:
            raise urllib.error.HTTPError(
                newurl, code, "redirect refused", headers, fp)
        if code in (301, 302, 303):
            return urllib.request.Request(
                newurl, headers={"Range": req.get_header("Range") or ""})
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def auth_body():
    salt = "".join(random.choices("abcdef0123456789", k=8))
    token = hashlib.md5((STATE["password"] + salt).encode()).hexdigest()
    return ("u=%s&t=%s&s=%s&v=%s&c=%s&f=json"
            % (urllib.parse.quote(STATE["user"]), token, salt,
               AUTH_VERSION, CLIENT_NAME))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "amla-broker"
    sys_version = ""

    def log_message(self, *args):
        pass  # never log request lines (they contain the capability prefix)

    def _fail(self, code, why):
        body = ("amla broker: %s\n" % why).encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _route(self):
        """Return the song id for the one valid route shape, else None."""
        parts = urllib.parse.urlsplit(self.path)
        if parts.query or parts.fragment:
            return None
        segs = parts.path.split("/")
        # ["", prefix, "s", id]
        if len(segs) != 4 or segs[2] != "s" or not segs[3]:
            return None
        if not hmac.compare_digest(segs[1], STATE["prefix"]):
            return None
        if not ID_RE.match(segs[3]):
            return None
        return segs[3]

    def _proxy(self, song_id, head_only):
        body = auth_body() + "&id=" + urllib.parse.quote(song_id)
        req = urllib.request.Request(
            STATE["base"] + "/rest/stream", data=body.encode("utf-8"),
            headers={"Content-Type": "application/x-www-form-urlencoded"})
        rng = self.headers.get("Range")
        if rng:
            req.add_header("Range", rng)
        opener = urllib.request.build_opener(
            SameOriginRedirects(origin(STATE["base"])))
        try:
            resp = opener.open(req, timeout=UPSTREAM_TIMEOUT)
        except urllib.error.HTTPError as e:
            try:
                e.close()
            except Exception:  # noqa: BLE001
                pass
            self._fail(502, "upstream rejected the request")
            return
        except Exception:  # noqa: BLE001
            self._fail(502, "upstream unavailable")
            return
        try:
            ctype = (resp.headers.get("Content-Type") or "").lower()
            if "json" in ctype or ctype.startswith("text/"):
                # Subsonic reports failures as HTTP 200 with a JSON error
                # body. Never hand that to a player as if it were audio:
                # surface it as an upstream error instead.
                resp.read(2048)
                self._fail(502, "upstream returned an error payload")
                return
            length = resp.headers.get("Content-Length")
            if length is not None and int(length) > MAX_BYTES:
                self._fail(502, "upstream response exceeds cap")
                return
            self.send_response(resp.status)
            self.send_header("Content-Type",
                             resp.headers.get("Content-Type")
                             or "application/octet-stream")
            if length is not None:
                self.send_header("Content-Length", length)
            cr = resp.headers.get("Content-Range")
            if cr:
                self.send_header("Content-Range", cr)
            self.send_header("Accept-Ranges", "bytes")
            if length is None:
                self.send_header("Connection", "close")
            self.end_headers()
            if head_only:
                return
            total = 0
            while True:
                chunk = resp.read(CHUNK)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_BYTES:
                    self.close_connection = True
                    return
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True  # player seeked away; not an error
        except Exception:  # noqa: BLE001
            self.close_connection = True
        finally:
            try:
                resp.close()
            except Exception:  # noqa: BLE001
                pass

    def _serve(self, head_only):
        song_id = self._route()
        if song_id is None:
            self._fail(404, "no such route")
            return
        STATE["inflight"] += 1
        try:
            self._proxy(song_id, head_only)
        finally:
            STATE["inflight"] -= 1

    def do_GET(self):
        self._serve(False)

    def do_HEAD(self):
        self._serve(True)

    def do_POST(self):
        self._fail(405, "method not allowed")

    def do_PUT(self):
        self._fail(405, "method not allowed")

    def do_DELETE(self):
        self._fail(405, "method not allowed")


def main():
    STATE["base"] = (os.environ.get("AMLA_BROKER_BASE") or "").rstrip("/")
    STATE["user"] = os.environ.get("AMLA_BROKER_USER") or ""
    STATE["password"] = os.environ.get("AMLA_BROKER_PASS") or ""
    state_path = os.environ.get("AMLA_BROKER_STATE") or ""
    want_port = int(os.environ.get("AMLA_BROKER_PORT") or "0")
    prefix = (os.environ.get("AMLA_BROKER_PREFIX") or "").strip().lower()

    if not (STATE["base"] and STATE["user"] and STATE["password"]):
        log("no credentials, exiting")
        return 1
    if not PREFIX_RE.match(prefix):
        prefix = os.urandom(16).hex()
    STATE["prefix"] = prefix

    lock_fd = acquire_lock(state_path)
    if lock_fd is None:
        log("another broker is already running")
        return 0

    try:
        httpd = ThreadingHTTPServer(("127.0.0.1", want_port), Handler)
    except OSError:
        if want_port == 0:
            log("bind failed")
            return 1
        return 3  # requested port unavailable: caller retries with port 0

    httpd.daemon_threads = True
    STATE["port"] = httpd.server_address[1]
    write_state(state_path, STATE["port"], STATE["prefix"])

    def stop(_sig, _frm):
        # Direct exit: Server.shutdown() would deadlock when called from a
        # signal handler on the serve_forever thread. Nothing needs flushing
        # (per-request state is in-memory only; the state file is meant to
        # outlive the process so a respawn reuses the same address).
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        httpd.serve_forever(poll_interval=0.5)
    except Exception as e:  # noqa: BLE001
        log("serve failed: %r" % (e,))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
