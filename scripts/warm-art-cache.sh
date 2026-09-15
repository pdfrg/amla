#!/bin/bash
# Warm the subsonic cover-art disk cache (~/.cache/amla/art) for every album
# in the Navidrome library (paginated getAlbumList2, size=96 server-side
# resize ≈ 10-30 KB each) so popup browsing never waits on the network.
# Existing files are skipped, so re-running is cheap.
#
# Credentials never appear in argv or in request URLs: the Subsonic token is
# password-equivalent (replayable for any client-chosen salt), so it must not
# show up in `ps` output or in URLs that servers/proxies may log. Everything
# goes in POST form bodies, and creds reach python through the environment
# (owner-readable only) rather than command-line arguments.
set -euo pipefail

CACHE="$HOME/.cache/amla/art"
CFG="$HOME/.config/must/config.toml"
mkdir -p "$CACHE"
chmod 700 "$CACHE"

# Read [subsonic] creds into the environment (env is not argv).
read -r AMLA_SUB_URL AMLA_SUB_USER AMLA_SUB_PASS < <(python3 - "$CFG" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
section = text.split("[subsonic]", 1)[1] if "[subsonic]" in text else ""
def field(name):
    m = re.search(name + r"\s*=\s*'([^']*)'", section)
    return m.group(1) if m else ""
print(field("url"), field("username"), field("password"))
PY
)
export AMLA_SUB_URL AMLA_SUB_USER AMLA_SUB_PASS

if [ -z "$AMLA_SUB_URL" ] || [ -z "$AMLA_SUB_USER" ] || [ -z "$AMLA_SUB_PASS" ]; then
  echo "subsonic not configured in $CFG" >&2
  exit 1
fi

python3 <<'PY'
import hashlib
import json
import os
import random
import sys
import urllib.parse
import urllib.request

URL = (os.environ.get("AMLA_SUB_URL") or "").rstrip("/")
USER = os.environ.get("AMLA_SUB_USER") or ""
PASSWORD = os.environ.get("AMLA_SUB_PASS") or ""
CACHE = os.path.join(os.path.expanduser("~"), ".cache/amla/art")
COVER_MAX = 1024 * 1024
JSON_MAX = 2 * 1024 * 1024
HTTP_TIMEOUT = 15


def auth_body():
    salt = "".join(random.choices("abcdef0123456789", k=8))
    token = hashlib.md5((PASSWORD + salt).encode()).hexdigest()
    return ("u=%s&t=%s&s=%s&v=1.16.1&c=amla-warm&f=json"
            % (urllib.parse.quote(USER), token, salt))


def post(endpoint, params, max_bytes):
    body = (auth_body() + "&" + params).encode("utf-8")
    req = urllib.request.Request(
        URL + "/rest/" + endpoint, data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    resp = urllib.request.urlopen(req, timeout=HTTP_TIMEOUT)
    ctype = (resp.headers.get_content_type() or "").lower()
    declared = resp.headers.get("Content-Length")
    if declared is not None and int(declared) > max_bytes:
        resp.close()
        raise ValueError("response exceeds %d-byte cap" % max_bytes)
    data = resp.read(max_bytes + 1)
    resp.close()
    if len(data) > max_bytes:
        raise ValueError("response exceeds %d-byte cap" % max_bytes)
    return data, ctype


ids, offset = [], 0
while True:
    raw, _ = post("getAlbumList2",
                  "type=byYear&fromYear=0&toYear=9999&size=500&offset=%d"
                  % offset, JSON_MAX)
    sub = json.loads(raw.decode("utf-8", "replace"))["subsonic-response"]
    albums = (sub.get("albumList2") or {}).get("album") or []
    for a in albums:
        cid = a.get("coverArt") or a.get("id")
        if cid:
            ids.append(cid)
    if len(albums) < 500:
        break
    offset += 500
print("albums: %d" % len(ids))

done = 0
for cid in ids:
    safe = "".join(c if (c.isalnum() or c in "-_") else "_" for c in cid)
    out = os.path.join(CACHE, safe + "-96.jpg")
    if os.path.exists(out):
        continue
    tmp = out + ".tmp"
    try:
        data, ctype = post("getCoverArt",
                           "id=%s&size=96" % urllib.parse.quote(cid),
                           COVER_MAX)
        if not ctype.startswith("image/") or not data:
            continue
        with open(tmp, "wb") as fh:
            fh.write(data)
        os.chmod(tmp, 0o600)
        os.replace(tmp, out)
        done += 1
    except Exception as e:  # noqa: BLE001 - one bad cover must not abort
        sys.stderr.write("skip %s: %r\n" % (cid, e))
        if os.path.exists(tmp):
            os.unlink(tmp)
print("downloaded: %d" % done)
PY

echo "cache: $(ls -1 "$CACHE" | wc -l) files, $(du -sh "$CACHE" | cut -f1)"
