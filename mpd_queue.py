#!/usr/bin/env python3
"""Queue a staged track list into MPD over a single TCP connection.

Staged JSON (written by the amla plugin via FileView, never a giant
env var — quickshell Process command strings stall past ~190 KB):
  {"tracks": [{"uri": "<music-dir-relative path | stream URL>",
               "tags": {"artist": .., "album": .., "title": ..,
                        "track": .., "date": ..}}],
   "insertNext": false}

Absolute local paths are mapped into music_directory-relative URIs by
stripping the longest matching --strip-prefix (mpc over TCP cannot
touch local files at all: "Access to local files via TCP is not
allowed"). Tracks matching no prefix are skipped; exit 4 when nothing
was queued. Tags ride addtagid (stream URLs carry no tags of their
own, so the queue would otherwise show raw stream.view URLs).
No password support (local daemon); host/port also read MPD_HOST/PORT.

Exit 0 prints "queued N skipped M".
"""
import argparse
import json
import os
import socket
import sys


def esc(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


class Mpd:
    def __init__(self, host, port):
        self.f = socket.create_connection((host, port), timeout=10).makefile("rwb")
        greet = self._line()
        if not greet.startswith("OK MPD "):
            raise RuntimeError("bad greeting: " + greet)

    def _line(self):
        return self.f.readline().decode("utf-8", "replace").rstrip("\n")

    def cmd(self, *parts):
        self.f.write((" ".join(parts) + "\n").encode("utf-8"))
        self.f.flush()
        out = []
        while True:
            line = self._line()
            if line == "OK":
                return out
            if line.startswith("ACK"):
                raise RuntimeError(line)
            out.append(line)

    def close(self):
        # `close` gets no reply (the daemon drops the connection),
        # so write it raw — cmd() would block forever on readline.
        try:
            self.f.write(b"close\n")
            self.f.flush()
        except Exception:
            pass
        try:
            self.f.close()
        except Exception:
            pass


def current_pos(mpd):
    for line in mpd.cmd("status"):
        if line.startswith("song: "):
            try:
                return int(line.split(": ", 1)[1])
            except ValueError:
                return None
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=os.environ.get("MPD_HOST", "localhost"))
    ap.add_argument("--port", default=os.environ.get("MPD_PORT", "6600"))
    ap.add_argument("--queue-file", required=True)
    ap.add_argument("--strip-prefix", action="append", default=[])
    ap.add_argument("--clear", action="store_true")
    ap.add_argument("--play", action="store_true")
    ap.add_argument("--shuffle", action="store_true")
    ap.add_argument("--random", choices=["on", "off"])
    args = ap.parse_args()

    with open(args.queue_file, "r", encoding="utf-8") as fh:
        q = json.load(fh)
    tracks = q.get("tracks", []) or []
    insert_next = bool(q.get("insertNext"))

    prefixes = sorted(
        [p for p in (args.strip_prefix or []) if p], key=len, reverse=True
    )

    def rel(uri):
        if "://" in uri:
            return uri  # stream URL: pass through untouched
        for p in prefixes:
            base = p.rstrip("/")
            if uri == p or uri.startswith(base + "/"):
                return "" if uri == p else uri[len(base) + 1:]
        return None

    mpd = Mpd(args.host, int(args.port))
    try:
        if args.clear:
            mpd.cmd("clear")
        pos = None
        if insert_next and not args.clear:
            pos = current_pos(mpd)
        queued, skipped = 0, 0
        for t in tracks:
            uri = (t.get("uri") if isinstance(t, dict) else t) or ""
            tags = t.get("tags", {}) if isinstance(t, dict) else {}
            r = rel(str(uri))
            if not r:
                skipped += 1
                continue
            if pos is None:
                rid = mpd.cmd("addid", esc(r))
            else:
                rid = mpd.cmd("addid", esc(r), str(pos + 1 + queued))
            sid = None
            if rid and rid[0].startswith("Id: "):
                sid = rid[0].split(": ", 1)[1]
            if sid:
                for tag in ("artist", "album", "title", "track", "date"):
                    v = tags.get(tag, "")
                    if v is None or str(v) == "":
                        continue
                    try:
                        mpd.cmd("addtagid", sid, tag, esc(str(v)))
                    except RuntimeError as e:
                        print("tag warning: %s" % e, file=sys.stderr)
            queued += 1
        if args.random is not None:
            mpd.cmd("random", "1" if args.random == "on" else "0")
        if args.shuffle and queued > 1:
            mpd.cmd("shuffle")
        if args.play and queued > 0:
            mpd.cmd("play")
    finally:
        mpd.close()

    print("queued %d skipped %d" % (queued, skipped))
    return 4 if queued == 0 else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print("mpd_queue: %s" % e, file=sys.stderr)
        sys.exit(1)
