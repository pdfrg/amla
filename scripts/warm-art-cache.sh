#!/bin/bash
# Warm the subsonic cover-art disk cache (~/.cache/amla/art) for every album
# in the Navidrome library (paginated getAlbumList2, size=96 server-side
# resize ≈ 10-30 KB each) so popup browsing never waits on the network.
# Existing files are skipped, so re-running is cheap.
set -euo pipefail

CACHE="$HOME/.cache/amla/art"
CFG="$HOME/.config/must/config.toml"
mkdir -p "$CACHE"

read -r URL USER PASS < <(python3 - "$CFG" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
section = text.split("[subsonic]", 1)[1] if "[subsonic]" in text else ""
def field(name):
    m = re.search(name + r"\s*=\s*'([^']*)'", section)
    return m.group(1) if m else ""
print(field("url"), field("username"), field("password"))
PY
)

if [ -z "$URL" ] || [ -z "$USER" ] || [ -z "$PASS" ]; then
  echo "subsonic not configured in $CFG" >&2
  exit 1
fi

SALT="amla-warm-0000"
TOKEN=$(python3 -c "import hashlib,sys; print(hashlib.md5(('$PASS'+'$SALT').encode()).hexdigest())")
AUTH="u=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$USER")&t=$TOKEN&s=$SALT&v=1.16.1&c=amla-warm&f=json"

IDS=$(python3 - "$URL" "$AUTH" <<'PY'
import json, sys, urllib.request
url, auth = sys.argv[1], sys.argv[2]
JSON_MAX = 2 * 1024 * 1024  # paged album listings are ~hundreds of KiB
ids, offset = [], 0
while True:
    u = f"{url.rstrip('/')}/rest/getAlbumList2?{auth}&type=byYear&fromYear=0&toYear=9999&size=500&offset={offset}"
    req = urllib.request.urlopen(u, timeout=15)
    try:
        declared = req.headers.get("Content-Length")
        if declared is not None and int(declared) > JSON_MAX:
            raise ValueError("getAlbumList2 response exceeds cap")
        chunks, total = [], 0
        while True:
            chunk = req.read(65536)
            if not chunk:
                break
            total += len(chunk)
            if total > JSON_MAX:
                raise ValueError("getAlbumList2 response exceeds cap")
            chunks.append(chunk)
        sub = json.loads(b"".join(chunks).decode("utf-8", "replace"))["subsonic-response"]
    finally:
        req.close()
    albums = (sub.get("albumList2") or {}).get("album") or []
    for a in albums:
        cid = a.get("coverArt") or a.get("id")
        if cid:
            ids.append(cid)
    if len(albums) < 500:
        break
    offset += 500
print("\n".join(ids))
PY
)

TOTAL=$(printf '%s\n' "$IDS" | grep -c . || true)
echo "albums: $TOTAL"

DONE=0
printf '%s\n' "$IDS" | while read -r CID; do
  [ -n "$CID" ] || continue
  SAFE=$(printf '%s' "$CID" | tr -c 'A-Za-z0-9_-' '_')
  OUT="$CACHE/$SAFE-96.jpg"
  [ -f "$OUT" ] && continue
  ENC=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$CID")
  if curl -fs --max-time 15 --max-filesize 1048576 -o "$OUT" "$URL/rest/getCoverArt?$AUTH&id=$ENC&size=96"; then
    DONE=$((DONE+1))
  else
    rm -f "$OUT"
  fi
done

echo "cache: $(ls -1 "$CACHE" | wc -l) files, $(du -sh "$CACHE" | cut -f1)"
