#!/usr/bin/env python3
"""rmpc `album_art.custom_loader` hook: cover art for Subsonic streams.

MPD's `albumart`/`readpicture` only work for files inside music_directory,
so stream URLs (http...) can never have in-pane art in rmpc -- unless a
custom loader supplies the bytes. rmpc runs this script with the song URI
in $FILE; amla dispatches Subsonic streams as
  http://host:4533/rest/stream?...&id=<songId>
so the song id is parsed straight out of the URL and its cover fetched
via Navidrome `getCoverArt` (which accepts a song id, not just the
coverArt id). Anything else -- local files, missing id, no creds, any
error -- prints `action: fallback` (rmpc's default MPD behavior, so
local-file art is unaffected). Always exits 0 with stdout kept clean
for the protocol; diagnostics go to stderr, which rmpc ignores.

Creds mirror amla's pickSubsonic precedence: must [subsonic] (when
enabled) > cliamp [navidrome] > amla-owned config.json
(subsonicUrl/User/Pass, with ${VAR} expanded from the environment).

Enable (rmpc built after v0.11 -- custom_loader landed 2026-02-06):
  album_art: ( ... custom_loader: ["<plugin-dir>/rmpc_art.py"], )
The key is inert on stable v0.11 (unknown keys are ignored), so one
rmpc config works on both.
"""
import hashlib
import json
import os
import random
import sys
import urllib.parse
import urllib.request

COVER_SIZE = 500
HTTP_TIMEOUT = 15
# Producer-side byte ceilings (a compromised/faulty server must not be
# able to exhaust memory: Content-Length is pre-checked AND bodies are
# streamed with a MAX+1 cap, since chunked responses have no length).
# getSong responses are ~1-2 KiB; size=500 JPEG covers are tens of KiB.
JSON_MAX = 256 * 1024
IMAGE_MAX = 10 * 1024 * 1024
# Decoded-pixel bound (header check only; rmpc does the actual decode).
DIM_MAX = 4096
MAX_REDIRECTS = 3


def diag(msg):
    try:
        sys.stderr.write("rmpc_art: %s\n" % msg)
    except OSError:
        pass


def fallback():
    sys.stdout.write("action: fallback\n")
    sys.stdout.flush()


def expand_vars(s):
    """Expand ${VAR} from the environment (amla-owned secrets only)."""
    out = []
    i = 0
    while True:
        j = s.find("${", i)
        if j < 0:
            out.append(s[i:])
            break
        k = s.find("}", j + 2)
        if k < 0:
            out.append(s[i:])
            break
        out.append(s[i:j])
        out.append(os.environ.get(s[j + 2:k], s[j:k + 1]))
        i = k + 1
    return "".join(out)


def parse_toml_section(path, section):
    """Minimal TOML: top-level keys of one [section], quotes stripped."""
    vals = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            in_sec = False
            for line in fh:
                s = line.strip()
                if not s or s.startswith("#"):
                    continue
                if s.startswith("["):
                    name = s.strip("[]").strip()
                    in_sec = name.split(".")[0] == section
                    continue
                if not in_sec or "=" not in s:
                    continue
                k, v = s.split("=", 1)
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                vals[k.strip()] = v
    except OSError:
        pass
    return vals


def truthy(v):
    return str(v).strip().lower() in ("1", "true", "yes", "on")


def pick_subsonic(home):
    """must [subsonic] > cliamp [navidrome] > amla-owned config.json."""
    must = parse_toml_section(
        os.path.join(home, ".config/must/config.toml"), "subsonic")
    if truthy(must.get("enabled", "")) and must.get("url", ""):
        return (must["url"].rstrip("/"), must.get("username", ""),
                must.get("password", ""), "must")
    nav = parse_toml_section(
        os.path.join(home, ".config/cliamp/config.toml"), "navidrome")
    if nav.get("url", ""):
        return (nav["url"].rstrip("/"),
                nav.get("user", "") or nav.get("username", ""),
                nav.get("password", ""), "cliamp")
    try:
        with open(os.path.join(home, ".config/amla/config.json"),
                  "r", encoding="utf-8") as fh:
            owned = json.load(fh)
        url = str(owned.get("subsonicUrl", "")).rstrip("/")
        if url:
            return (url, expand_vars(str(owned.get("subsonicUser", ""))),
                    expand_vars(str(owned.get("subsonicPass", ""))),
                    "amla-owned")
    except (OSError, ValueError):
        pass
    return ("", "", "", "")


def song_id_from_uri(uri):
    if "://" not in uri:
        return ""
    try:
        ids = urllib.parse.parse_qs(urllib.parse.urlparse(uri).query
                                    ).get("id", [])
    except ValueError:
        return ""
    return ids[0] if ids else ""


def auth_query(user, password):
    salt = "".join(random.choices("abcdef0123456789", k=8))
    token = hashlib.md5((password + salt).encode()).hexdigest()
    return ("u=%s&t=%s&s=%s&v=1.16.1&c=rmpc-art&f=json"
            % (urllib.parse.quote(user), token, salt))


class RedirectBlocked(Exception):
    pass


def _origin(url):
    p = urllib.parse.urlparse(url)
    default_port = 443 if p.scheme.lower() == "https" else 80
    return (p.scheme.lower(), (p.hostname or "").lower(),
            p.port or default_port)


class SameOriginRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Follow redirects only back to the configured server's own origin
    (scheme+host+port), bounded hop count. Anything else -- notably a
    redirect carrying our query-string auth token to a third party -- is
    blocked and the caller falls back."""
    def __init__(self, base_origin):
        super().__init__()
        self.base_origin = base_origin
        self.hops = 0

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self.hops += 1
        if self.hops > MAX_REDIRECTS or _origin(newurl) != self.base_origin:
            raise RedirectBlocked("redirect to %s blocked" % newurl)
        return super().redirect_request(req, fp, code, msg, headers,
                                        newurl)


def bounded_get(url, max_bytes, expect):
    """GET with same-origin redirect policy, Content-Type gate checked
    BEFORE reading, Content-Length pre-check, and streaming MAX+1 read
    (covers lying/omitted lengths). Returns (body, content_type)."""
    opener = urllib.request.build_opener(
        SameOriginRedirectHandler(_origin(url)))
    req = opener.open(url, timeout=HTTP_TIMEOUT)
    try:
        ctype = (req.headers.get_content_type() or "").lower()
        if expect == "json":
            if (ctype and "json" not in ctype and "text" not in ctype
                    and "javascript" not in ctype):
                raise ValueError("unexpected content type %r" % ctype)
        elif expect == "image":
            if not ctype.startswith("image/"):
                raise ValueError("unexpected content type %r" % ctype)
        declared = req.headers.get("Content-Length")
        if declared is not None:
            try:
                if int(declared) > max_bytes:
                    raise ValueError("content-length %s exceeds cap"
                                     % declared)
            except ValueError as e:
                if "exceeds cap" in str(e):
                    raise
                # Unparseable length: fall through to the streaming cap.
        chunks = []
        total = 0
        while True:
            chunk = req.read(65536)
            if not chunk:
                break
            total += len(chunk)
            if total > max_bytes:
                raise ValueError("body exceeds %d-byte cap" % max_bytes)
            chunks.append(chunk)
        return b"".join(chunks), ctype
    finally:
        try:
            req.close()
        except Exception:  # noqa: BLE001 - best effort
            pass


def image_dimensions(data):
    """(width, height) from PNG/JPEG/GIF/WebP headers without decoding,
    else None. stdlib only."""
    import struct
    if len(data) >= 24 and data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    if len(data) >= 10 and data[:6] in (b"GIF87a", b"GIF89a"):
        return struct.unpack("<HH", data[6:10])
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        if len(data) >= 30 and data[12:16] == b"VP8X":
            w = struct.unpack("<I", data[24:27] + b"\x00")[0] + 1
            h = struct.unpack("<I", data[27:30] + b"\x00")[0] + 1
            return (w, h)
        if len(data) >= 30 and data[12:16] == b"VP8 ":
            w = struct.unpack("<H", data[26:28])[0] & 0x3FFF
            h = struct.unpack("<H", data[28:30])[0] & 0x3FFF
            return (w, h)
        if len(data) >= 25 and data[12:16] == b"VP8L":
            b1, b2, b3, b4 = data[21:25]
            w = 1 + (((b2 & 0x3F) << 8) | b1)
            h = 1 + (((b4 & 0x0F) << 10) | (b3 << 2) | ((b2 & 0xC0) >> 6))
            return (w, h)
        return None
    if len(data) >= 4 and data[:2] == b"\xff\xd8":
        # JPEG: walk segment markers to the first SOFn (bounded steps).
        off = 2
        for _ in range(64):
            if off + 4 > len(data) or data[off] != 0xFF:
                return None
            marker = data[off + 1]
            if marker in (0xD8, 0xD9, 0x01) or 0xD0 <= marker <= 0xD7:
                off += 2
                continue
            seg_len = struct.unpack(">H", data[off + 2:off + 4])[0]
            if seg_len < 2:
                return None
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                          0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                if off + 9 > len(data):
                    return None
                h = struct.unpack(">H", data[off + 5:off + 7])[0]
                w = struct.unpack(">H", data[off + 7:off + 9])[0]
                return (w, h)
            off += 2 + seg_len
        return None
    return None


def album_id_for_song(base, auth, song_id):
    """Album-level id for a song (getSong). Per-song coverArt rows
    (dc-*) can go stale server-side and resolve to disc art -- mirror
    of must's loadSubsonicAlbumArtCmd / amla's subArtId preference."""
    try:
        body, _ = bounded_get(
            "%s/rest/getSong?%s&id=%s"
            % (base, auth, urllib.parse.quote(song_id)), JSON_MAX, "json")
        sub = json.loads(body.decode("utf-8", "replace"))
        song = (sub.get("subsonic-response") or {}).get("song") or {}
        return str(song.get("albumId") or "")
    except Exception:  # noqa: BLE001 - caller falls back to song art
        return ""


def fetch_cover(base, auth, art_id):
    art_url = ("%s/rest/getCoverArt?%s&id=%s&size=%d"
               % (base, auth, urllib.parse.quote(art_id), COVER_SIZE))
    data, _ = bounded_get(art_url, IMAGE_MAX, "image")
    if not data:
        return None
    dims = image_dimensions(data)
    if dims is not None and (dims[0] > DIM_MAX or dims[1] > DIM_MAX):
        diag("cover dimensions %dx%d exceed cap, skipping" % dims)
        return None
    return data


def main():
    uri = os.environ.get("FILE", "")
    try:
        song_id = song_id_from_uri(uri)
        if not song_id:
            fallback()
            return
        home = os.path.expanduser("~")
        base, user, password, src = pick_subsonic(home)
        if not (base and user and password):
            diag("no subsonic creds, fallback")
            fallback()
            return
        auth = auth_query(user, password)
        ids = []
        album_id = album_id_for_song(base, auth, song_id)
        if album_id and album_id != song_id:
            ids.append(album_id)
        ids.append(song_id)
        data = None
        for art_id in ids:
            try:
                data = fetch_cover(base, auth, art_id)
            except Exception as e:  # noqa: BLE001 - try next id
                diag("cover fetch failed for %s: %r" % (art_id, e))
                continue
            if data is not None:
                break
        if data is None:
            diag("cover fetch failed via %s, fallback" % src)
            fallback()
            return
        out = sys.stdout.buffer
        out.write(("size: %d\n" % len(data)).encode())
        out.write(b"action: display\n")
        out.write(data)
        out.flush()
    except Exception as e:  # noqa: BLE001 - must always exit 0
        diag("error %r, fallback" % (e,))
        try:
            fallback()
        except Exception:  # noqa: BLE001
            pass


if __name__ == "__main__":
    main()
