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


def fetch_cover(base, user, password, song_id):
    salt = "".join(random.choices("abcdef0123456789", k=8))
    token = hashlib.md5((password + salt).encode()).hexdigest()
    art_url = ("%s/rest/getCoverArt?u=%s&t=%s&s=%s&v=1.16.1"
               "&c=rmpc-art&f=json&id=%s&size=%d"
               % (base, urllib.parse.quote(user), token, salt,
                  urllib.parse.quote(song_id), COVER_SIZE))
    req = urllib.request.urlopen(art_url, timeout=HTTP_TIMEOUT)
    data = req.read()
    if not req.headers.get_content_type().startswith("image/") or not data:
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
        data = fetch_cover(base, user, password, song_id)
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
