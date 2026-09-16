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
restores its queue from state_file across restarts). It never exits on an idle
timer for the same reason; the plugin's liveness probe restarts it instead.
It publishes {pid, port, prefix, token} to a 0600 state file -- random
same-directory temporary created O_CREAT|O_EXCL|O_NOFOLLOW, fsynced, renamed
through a directory fd, destination rejected unless it is a regular file we
own, lock file checked for type and owner -- so a respawn reuses the same
address and URLs already queued by a player keep resolving.
"""
import fcntl
import hashlib
import hmac
import json
import os
import random
import re
import signal
import socket
import stat
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Upstream response ceiling. A single lossless track is far below this; the
# cap exists so a faulty server cannot stream unboundedly into a player.
MAX_BYTES = 1024 * 1024 * 1024
UPSTREAM_TIMEOUT = 20
CHUNK = 65536
# Hard ceiling on simultaneous streams (and therefore upstream connections):
# each one can hold a socket for UPSTREAM_TIMEOUT and push up to MAX_BYTES,
# so unlimited concurrency is a local resource-exhaustion vector. Excess
# requests are refused immediately rather than queued.
MAX_CONCURRENT = 8
# A client that stops reading must not pin a worker forever, and a client
# that never finishes a request must not pin one for long either: the read
# phase gets a short budget, the write phase a longer one.
CLIENT_WRITE_TIMEOUT = 30
REQUEST_READ_TIMEOUT = 5
# Ceiling on live connections (not just streams): without it, idle or
# slow-drip clients park one thread each, unbounded.
MAX_CONNECTIONS = 32
# The plugin refreshes this lease while its shell session lives; a stale one
# means the session is gone and the helper should not keep credentials
# resident on a machine sitting at a login prompt.
LEASE_TIMEOUT = 300
LEASE_POLL = 30
# Bounded read of our own small state file, used by --read-state.
STATE_MAX_BYTES = 4096
SLOTS = threading.BoundedSemaphore(MAX_CONCURRENT)
CONN_LOCK = threading.Lock()
CONNECTIONS = set()
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
    "token": "",
    "port": 0,
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
    kernel on exit. Returns the fd, or None when the lock cannot be taken.

    O_NOFOLLOW plus a regular-file/owner check: a same-user component must
    not be able to aim this at a symlink. An existing lock file we own is
    repaired to 0600 rather than trusted."""
    if not state_path:
        return None
    lock_path = state_path + ".lock"
    try:
        os.makedirs(os.path.dirname(lock_path), exist_ok=True)
        fd = os.open(lock_path,
                     os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
            os.close(fd)
            return None
        if st.st_mode & 0o777 != 0o600:
            os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


def write_state(path, port, prefix, token):
    """Atomically publish {pid, port, prefix, token} for the plugin (no
    credentials).

    Hardened against a pre-placed symlink or file at either path: the
    temporary is random, same-directory, and created O_CREAT|O_EXCL|
    O_NOFOLLOW; the payload is fsynced; the destination is rejected unless
    it is a regular file we own; the rename goes through a directory fd and
    the directory is fsynced. So this never truncates or follows anything,
    and never clobbers a file that is not ours."""
    if not path:
        return
    payload = json.dumps({"pid": os.getpid(), "port": port,
                          "prefix": prefix, "token": token})
    name = os.path.basename(path)
    tmp_name = ".%s.%s.tmp" % (name, os.urandom(8).hex())
    dfd = None
    created = False
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        dfd = os.open(os.path.dirname(path) or ".",
                      os.O_RDONLY | os.O_DIRECTORY)
        fd = os.open(tmp_name,
                     os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=dfd)
        created = True
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            st = os.fstat(fh.fileno())
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
                raise OSError("temporary is not a regular file we own")
            fh.write(payload)
            fh.flush()
            os.fsync(fh.fileno())
        try:
            st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
                raise OSError("state path is not a regular file we own")
        os.replace(tmp_name, name, src_dir_fd=dfd, dst_dir_fd=dfd)
        created = False
        os.fsync(dfd)
    except OSError as e:
        log("state write failed: %r" % (e,))
    finally:
        if created and dfd is not None:
            try:
                os.unlink(tmp_name, dir_fd=dfd)
            except OSError:
                pass
        if dfd is not None:
            os.close(dfd)


def read_state(path):
    """Print the state document (bounded, no symlink following), for the
    plugin's --read-state probe. Refuses anything that is not a 0600 regular
    file owned by us, and never reads more than STATE_MAX_BYTES."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return 1
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
            return 1
        if st.st_mode & 0o777 != 0o600 or st.st_size > STATE_MAX_BYTES:
            return 1
        data = os.read(fd, STATE_MAX_BYTES)
    except OSError:
        return 1
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
    sys.stdout.write(data.decode("utf-8", "replace"))
    return 0


def origin(url):
    p = urllib.parse.urlparse(url)
    default_port = 443 if p.scheme.lower() == "https" else 80
    return (p.scheme.lower(), (p.hostname or "").lower(), p.port or default_port)


class Server(ThreadingHTTPServer):
    """Threading server with a hard ceiling on live connections.

    verify_request refuses (and the socket is immediately closed) once
    MAX_CONNECTIONS are open, so idle or slow-drip clients cannot park an
    unbounded number of threads. Rejected requests are never counted, and
    the same request object is passed to shutdown_request, so the tally
    cannot drift."""

    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 16

    def verify_request(self, request, client_address):
        with CONN_LOCK:
            if len(CONNECTIONS) >= MAX_CONNECTIONS:
                return False
            CONNECTIONS.add(request)
        return True

    def shutdown_request(self, request):
        with CONN_LOCK:
            CONNECTIONS.discard(request)
        super().shutdown_request(request)


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
            headers_out = {}
            rng = req.get_header("Range")
            if rng:
                headers_out["Range"] = rng
            return urllib.request.Request(newurl, headers=headers_out)
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

    def setup(self):
        super().setup()
        # Short budget for the request phase; streaming stretches this later.
        self.connection.settimeout(REQUEST_READ_TIMEOUT)

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
        """Return ("stream", songId) or ("health", "") for the two accepted
        route shapes, else None. Both are scoped to the capability prefix;
        health additionally requires this instance's token, so a foreign
        listener on the same port cannot pass itself off as the broker."""
        parts = urllib.parse.urlsplit(self.path)
        if parts.fragment:
            return None
        segs = parts.path.split("/")
        if len(segs) < 3 or not segs[1]:
            return None
        if not hmac.compare_digest(segs[1], STATE["prefix"]):
            return None
        if len(segs) == 3 and segs[2] == "health":
            given = urllib.parse.parse_qs(parts.query).get("t", [""])[0]
            if not hmac.compare_digest(given, STATE["token"]):
                return None
            return ("health", "")
        if len(segs) != 4 or segs[2] != "s" or not segs[3]:
            return None
        if parts.query or not ID_RE.match(segs[3]):
            return None
        return ("stream", segs[3])

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
        except socket.timeout:
            self.close_connection = True  # stalled reader; free the slot
        except Exception:  # noqa: BLE001
            self.close_connection = True
        finally:
            try:
                resp.close()
            except Exception:  # noqa: BLE001
                pass

    def _serve(self, head_only):
        route = self._route()
        if route is None:
            self._fail(404, "no such route")
            return
        kind, song_id = route
        if kind == "health":
            self.connection.settimeout(CLIENT_WRITE_TIMEOUT)
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        # Refuse excess work outright: every stream can hold an upstream
        # socket for UPSTREAM_TIMEOUT and push MAX_BYTES, so an unbounded
        # accept path is a local resource-exhaustion vector.
        if not SLOTS.acquire(blocking=False):
            self._fail(503, "broker busy")
            return
        try:
            self.connection.settimeout(CLIENT_WRITE_TIMEOUT)
            self._proxy(song_id, head_only)
        finally:
            SLOTS.release()

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


def health_check(state_path):
    """Probe our own broker without putting the capability or instance token
    in a process argument list: read them from the state file in-process and
    print the HTTP status (or nothing on failure).

    Reasons this exists rather than a curl one-liner: /proc/<pid>/cmdline is
    world-readable, so a command line carrying the capability would hand the
    broker's whole access control to any local user, once a minute.
    """
    try:
        fd = os.open(state_path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return 1
    try:
        st = os.fstat(fd)
        if (not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid()
                or st.st_mode & 0o777 != 0o600 or st.st_size > STATE_MAX_BYTES):
            return 1
        doc = json.loads(os.read(fd, STATE_MAX_BYTES).decode("utf-8", "replace"))
    except (OSError, ValueError):
        return 1
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
    port = int(doc.get("port") or 0)
    prefix = str(doc.get("prefix") or "")
    token = str(doc.get("token") or "")
    if not (0 < port < 65536 and PREFIX_RE.match(prefix) and PREFIX_RE.match(token)):
        return 1
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=2) as sock:
            sock.sendall(("GET /%s/health?t=%s HTTP/1.0\r\n"
                          "Host: 127.0.0.1\r\n\r\n" % (prefix, token))
                         .encode("ascii"))
            line = sock.makefile("rb").readline(64).decode("ascii", "replace")
    except OSError:
        return 1
    bits = line.split()
    if len(bits) < 2 or not bits[1].isdigit():
        return 1
    sys.stdout.write(bits[1])
    return 0


def lease_watchdog(path):
    """Exit once the plugin's lease goes stale: the session it belonged to
    is gone, so credentials should not stay resident. Never while streams are
    live, since a player may be mid-track."""
    while True:
        time.sleep(LEASE_POLL)
        try:
            age = time.time() - os.stat(path).st_mtime
        except OSError:
            age = LEASE_TIMEOUT + 1
        if age > LEASE_TIMEOUT:
            with CONN_LOCK:
                busy = len(CONNECTIONS) > 0
            if not busy:
                log("lease stale, exiting")
                os._exit(0)


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--read-state":
        return read_state(sys.argv[2])
    if len(sys.argv) >= 3 and sys.argv[1] == "--health-check":
        return health_check(sys.argv[2])

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
    # Fresh per-start identity: the plugin's readiness probe must present it,
    # so another process squatting on the port cannot impersonate the broker
    # just by answering with an HTTP status.
    STATE["token"] = os.urandom(16).hex()

    lock_fd = acquire_lock(state_path)
    if lock_fd is None:
        log("another broker is already running")
        return 0

    try:
        httpd = Server(("127.0.0.1", want_port), Handler)
    except OSError:
        if want_port == 0:
            log("bind failed")
            return 1
        return 3  # requested port unavailable: caller retries with port 0

    STATE["port"] = httpd.server_address[1]
    write_state(state_path, STATE["port"], STATE["prefix"], STATE["token"])

    def stop(_sig, _frm):
        # Direct exit: Server.shutdown() would deadlock when called from a
        # signal handler on the serve_forever thread. Nothing needs flushing
        # (per-request state is in-memory only; the state file is meant to
        # outlive the process so a respawn reuses the same address).
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    lease_path = os.environ.get("AMLA_BROKER_LEASE") or ""
    if lease_path:
        threading.Thread(target=lease_watchdog, args=(lease_path,),
                         daemon=True).start()
    try:
        httpd.serve_forever(poll_interval=0.5)
    except Exception as e:  # noqa: BLE001
        log("serve failed: %r" % (e,))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
