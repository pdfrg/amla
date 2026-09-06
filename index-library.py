#!/usr/bin/env python3
"""amla library indexer (PLAN.md §§13-14).

Walks music roots, reads tags (mutagen → ffprobe → path-parse ladder),
and upserts into the amla-owned sqlite file index. stdlib-only; mutagen
and ffprobe are both optional. Single batched invocation (never one exec
per file — that is ~95% of the speed difference measured in the plan).

Usage:
  index-library.py --db ~/.cache/amla/files.db [--tagger auto|path|mutagen|ffprobe]
                   [--extra-buckets w] [--extra-noise x,y] <root>...

Prints one JSON summary line to stdout; exit 0 on success (per-file
errors are skipped, never fatal), exit 2 on fatal errors. Never touches
anything outside --db. Never installs anything.
"""

import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
import time

AUDIO_EXTS = {
    ".mp3", ".flac", ".m4a", ".mp4", ".ogg", ".oga", ".opus",
    ".wav", ".wma", ".aac", ".aif", ".aiff",
}

# Directory names that are never artist/album (buckets, formats, sort dirs).
BUCKET_DEFAULT = {
    "albums", "music", "musik", "flac", "mp3", "sorted", "library",
    "audio", "songs", "tracks", "unsorted", "incoming", "singles",
    "single", "downloads", "new", "temp", "misc", "other", "unknown",
    "loose",
}

# Trailing " - " segments stripped from album dir names (codecs, sources).
NOISE_RE = re.compile(
    r"^(mp3|flac|alac|ogg|opus|wav|m4a|aac|wma|"
    r"\d+\s*kbit|\d+\s*k|16\s*bit|24\s*bit|32\s*bit|"
    r"44\.?1?\s*kh?z|48\s*kh?z|96\s*kh?z|192\s*kh?z|"
    r"web|cd|vinyl|lp|car|"
    r"v0|v2|320|cbr|vbr|lossless)$",
    re.IGNORECASE,
)

YEAR_RE = re.compile(r"\b((?:19|20)\d{2})\b")
TRACK_RE = re.compile(r"^(\d{1,3})[\s.\-_]+(.+)$")
DISC_TRACK_RE = re.compile(r"^(\d{1,2})[-_](\d{1,2})\s*[-.]?\s*(.+)$")
DISC_DIR_RE = re.compile(r"^(?:cd|disc|disk)\s*\d+$", re.IGNORECASE)
VA_RE = re.compile(r"^(va|various|various artists|soundtrack|ost)$",
                   re.IGNORECASE)

# Mirror of Catalog.filesDbSchema() — keep the two in sync.
SCHEMA = """
CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY,
title TEXT DEFAULT '', artist TEXT DEFAULT '', album TEXT DEFAULT '',
album_artist TEXT DEFAULT '', year INTEGER DEFAULT 0, genre TEXT DEFAULT '',
track_num INTEGER DEFAULT 0, duration INTEGER DEFAULT 0,
mtime INTEGER DEFAULT 0, source TEXT DEFAULT 'file');
CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
title, artist, album, album_artist, genre,
content='files', content_rowid='rowid');
CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN
INSERT INTO files_fts(rowid, title, artist, album, album_artist, genre)
VALUES (new.rowid, new.title, new.artist, new.album,
new.album_artist, new.genre); END;
CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
INSERT INTO files_fts(files_fts, rowid, title, artist, album,
album_artist, genre) VALUES ('delete', old.rowid, old.title, old.artist,
old.album, old.album_artist, old.genre); END;
CREATE TRIGGER IF NOT EXISTS files_au AFTER UPDATE ON files BEGIN
INSERT INTO files_fts(files_fts, rowid, title, artist, album,
album_artist, genre) VALUES ('delete', old.rowid, old.title, old.artist,
old.album, old.album_artist, old.genre);
INSERT INTO files_fts(rowid, title, artist, album, album_artist, genre)
VALUES (new.rowid, new.title, new.artist, new.album,
new.album_artist, new.genre); END;
"""


def parse_args(argv):
    ap = argparse.ArgumentParser(description="amla library indexer")
    ap.add_argument("--db", required=True, help="sqlite file index path")
    ap.add_argument("--tagger", default="auto",
                    choices=["auto", "path", "mutagen", "ffprobe"])
    ap.add_argument("--extra-buckets", default=[], action="append",
                    help="extra bucket dir name, exact match (repeat the "
                         "flag; commas allowed); matched case-insensitively")
    ap.add_argument("--extra-noise", default="",
                    help="comma-separated extra noise tokens (regex, "
                         "matched whole-segment case-insensitively)")
    ap.add_argument("roots", nargs="+", help="music root directories")
    return ap.parse_args(argv)


def first_str(tags, *keys):
    """First non-empty string from a tag dict tried case-insensitively."""
    lowered = {}
    for k, v in tags.items():
        lowered[str(k).lower()] = v
    for key in keys:
        v = lowered.get(key)
        if v is None:
            continue
        if isinstance(v, (list, tuple)):
            v = v[0] if v else ""
        s = str(v).strip()
        if s:
            return s
    return ""


def parse_year(s):
    m = YEAR_RE.search(s or "")
    return int(m.group(1)) if m else 0


def parse_tracknum(s):
    m = re.match(r"^(\d{1,3})(?:/\d+)?$", (s or "").strip())
    return int(m.group(1)) if m else 0


class TagReader:
    """One tagger for the whole run (auto = mutagen → ffprobe → path)."""

    def __init__(self, mode):
        self.mode = mode
        self.mutagen_file = None
        self.ffprobe = False
        if mode in ("auto", "mutagen"):
            try:
                from mutagen import File as mfile
                self.mutagen_file = mfile
                self.mode = "mutagen"
            except Exception:
                if mode == "mutagen":
                    raise
        if self.mode == "auto":
            self.mode = "ffprobe" if self.have_ffprobe() else "path"
            if self.mode == "ffprobe":
                self.ffprobe = True
        elif self.mode == "ffprobe":
            if not self.have_ffprobe():
                raise RuntimeError("ffprobe not found on PATH")
            self.ffprobe = True

    @staticmethod
    def have_ffprobe():
        try:
            subprocess.run(["ffprobe", "-version"],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, check=False)
            return True
        except OSError:
            return False

    def read(self, path):
        """Return dict of tag fields (possibly empty — never raises)."""
        try:
            if self.mode == "mutagen":
                return self.read_mutagen(path)
            if self.mode == "ffprobe":
                return self.read_ffprobe(path)
        except Exception:
            pass
        return {}

    def read_mutagen(self, path):
        m = self.mutagen_file(path, easy=True)
        if m is None:
            return {}
        try:
            length = int(m.info.length)
        except Exception:
            length = 0
        return {
            "title": first_str(m, "title"),
            "artist": first_str(m, "artist"),
            "album": first_str(m, "album"),
            "album_artist": first_str(m, "albumartist", "album artist"),
            "date": first_str(m, "date", "year", "originaldate"),
            "genre": first_str(m, "genre"),
            "track": first_str(m, "tracknumber", "track"),
            "length": length,
        }

    def read_ffprobe(self, path):
        p = subprocess.run(
            ["ffprobe", "-v", "quiet", "-print_format", "json",
             "-show_format", path],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30)
        fmt = json.loads(p.stdout.decode("utf-8", "replace"))
        fmt = fmt.get("format", {})
        tags = fmt.get("tags", {})
        try:
            length = int(float(fmt.get("duration", 0)))
        except (TypeError, ValueError):
            length = 0
        return {
            "title": first_str(tags, "title"),
            "artist": first_str(tags, "artist"),
            "album": first_str(tags, "album"),
            "album_artist": first_str(tags, "album_artist",
                                      "albumartist", "album artist"),
            "date": first_str(tags, "date", "year", "originaldate",
                              "creation_time"),
            "genre": first_str(tags, "genre"),
            "track": first_str(tags, "track"),
            "length": length,
        }


def split_filename(name):
    """File stem → (track_num, title)."""
    stem = name
    if "." in stem:
        stem = stem.rsplit(".", 1)[0]
    stem = stem.strip()
    m = DISC_TRACK_RE.match(stem)
    if m:
        return int(m.group(2)), m.group(3).strip()
    m = TRACK_RE.match(stem)
    if m:
        return int(m.group(1)), m.group(2).strip()
    return 0, stem


def is_noise(seg, extra_res):
    if NOISE_RE.match(seg.strip()):
        return True
    for rx in extra_res:
        try:
            if rx.match(seg.strip()):
                return True
        except Exception:
            pass
    return False


def strip_noise_words(seg, extra_res):
    """Drop trailing noise words inside one segment.

    Handles compounds the whole-segment match misses ('FLAC 16bit-44kHz',
    'MP3 320k'): a word matches when it matches directly or when every
    hyphen-split part matches. A trailing ALL-CAPS token ('ENRICH',
    'OBZEN') is a release-group tag. Only trailing words are stripped, so
    an album genuinely called 'Web' keeps its name unless noise follows it.
    """
    words = seg.strip().split()
    while words and (word_is_noise(words[-1], extra_res)
                     or re.fullmatch(r"[A-Z0-9]{2,8}", words[-1])):
        words.pop()
    return " ".join(words)


def word_is_noise(word, extra_res):
    if is_noise(word, extra_res):
        return True
    if "-" in word:
        parts = [p for p in word.split("-") if p]
        if parts and all(is_noise(p, ()) for p in parts):
            return True
    return False


def parse_album_dir(dirname, extra_res):
    """Flat 'Artist [- Year] [- Album] [- noise…]' → dict (maybe empty)."""
    if " - " not in dirname:
        return {}
    segs = [s.strip() for s in dirname.split(" - ")]
    if len(segs) < 2:
        return {}
    out = {"artist": segs[0], "year": 0, "album": ""}
    raw_rest = []
    rest = []
    for seg in segs[1:]:
        if out["year"] == 0 and re.fullmatch(r"(?:19|20)\d{2}", seg):
            out["year"] = int(seg)
        else:
            raw_rest.append(seg)
            cleaned = strip_noise_words(seg, extra_res)
            if cleaned:
                rest.append(cleaned)
    # Never strip down to nothing: 'Artist - ABBA' keeps its album, while
    # 'Artist - Album - ENRICH' loses only the group tag.
    if not rest:
        rest = raw_rest
    out["album"] = " - ".join(rest)
    return out


def parse_dirs(dirnames, buckets, extra_res):
    """Innermost-first dir chain → {artist, album, year, album_artist}."""
    # Transparent levels (disc dirs) are skipped, not parsed.
    dirs = [d for d in dirnames if not DISC_DIR_RE.match(d)]
    if not dirs:
        return {}
    d1 = dirs[0]
    flat = parse_album_dir(d1, extra_res) if " - " in d1 else {}
    if flat and flat.get("album"):
        return flat
    if len(dirs) >= 2 and dirs[1].lower() not in buckets \
            and d1.lower() not in buckets:
        return {"artist": dirs[1], "album": d1, "year": 0}
    if flat:
        return flat
    if d1.lower() not in buckets:
        return {"album": d1}
    return {}


def index_file(path, root, reader, buckets, extra_res):
    """One file → record dict. Tags win; path fills blanks only."""
    try:
        rel = os.path.relpath(path, root)
    except ValueError:
        rel = path
    parts = rel.split(os.sep)
    fname = parts[-1]
    track_num, title = split_filename(fname)
    parsed = parse_dirs(parts[-2::-1] if len(parts) > 1 else [], buckets,
                        extra_res)
    tags = reader.read(path)
    rec = {
        "path": path,
        "title": tags.get("title") or title,
        "artist": tags.get("artist") or parsed.get("artist", ""),
        "album": tags.get("album") or parsed.get("album", ""),
        "album_artist": tags.get("album_artist") or "",
        "year": parse_year(tags.get("date")) or parsed.get("year", 0),
        "genre": tags.get("genre") or "",
        "track_num": parse_tracknum(tags.get("track"))
        or track_num,
        "duration": tags.get("length") or 0,
    }
    # Compilations: dir says VA → keep dir as album_artist, never as artist.
    if VA_RE.match(rec["artist"]) and not tags.get("artist"):
        rec["album_artist"] = parsed.get("album", "")
        rec["artist"] = ""
    return rec


def iter_audio_files(roots):
    for root in roots:
        if not os.path.isdir(root):
            print("skip missing root: %s" % root, file=sys.stderr)
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames
                           if not d.startswith(".")]
            for fn in filenames:
                if os.path.splitext(fn)[1].lower() in AUDIO_EXTS:
                    yield os.path.join(dirpath, fn)


def main(argv):
    t0 = time.time()
    args = parse_args(argv)
    buckets = set(BUCKET_DEFAULT)
    # One flag = one exact word (no comma-splitting, so names with
    # commas survive); normalized the same way matching normalizes.
    for chunk in args.extra_buckets:
        if str(chunk).strip():
            buckets.add(str(chunk).strip().lower())
    extra_res = []
    for n in args.extra_noise.split(","):
        if n.strip():
            extra_res.append(re.compile(r"^(?:%s)$" % n.strip(),
                                        re.IGNORECASE))
    try:
        reader = TagReader(args.tagger)
    except RuntimeError as e:
        print("error: %s" % e, file=sys.stderr)
        return 2

    dbdir = os.path.dirname(os.path.abspath(args.db))
    try:
        os.makedirs(dbdir, exist_ok=True)
        con = sqlite3.connect(args.db)
    except Exception as e:
        print("error: cannot open db: %s" % e, file=sys.stderr)
        return 2
    try:
        con.executescript(SCHEMA)
        con.execute("PRAGMA journal_mode=WAL;")
        have = {r[0]: r[1] for r in
                con.execute("SELECT path, mtime FROM files "
                            "WHERE source = 'file'")}
        seen = set()
        added = updated = 0
        batch = []
        for path in iter_audio_files(args.roots):
            try:
                mtime = int(os.stat(path).st_mtime)
            except OSError:
                continue
            seen.add(path)
            if have.get(path) == mtime:
                continue
            rec = index_file(path, nearest_root(path, args.roots),
                             reader, buckets, extra_res)
            rec["mtime"] = mtime
            batch.append(rec)
            if have.get(path) is None:
                added += 1
            else:
                updated += 1
            if len(batch) >= 500:
                upsert(con, batch)
                batch = []
        if batch:
            upsert(con, batch)
        # Prune rows under current roots that no longer exist on disk.
        removed = 0
        prefixes = [r.rstrip(os.sep) + os.sep for r in args.roots
                    if os.path.isdir(r)]
        q = "SELECT path FROM files WHERE source = 'file'"
        for (p,) in con.execute(q).fetchall():
            if p not in seen and any(
                    p.startswith(px) for px in prefixes):
                con.execute("DELETE FROM files WHERE path = ?", (p,))
                removed += 1
        con.commit()
    finally:
        con.close()
    dt = time.time() - t0
    print(json.dumps({"ok": True, "tagger": reader.mode, "scanned": len(seen),
                      "added": added, "updated": updated, "removed": removed,
                      "seconds": round(dt, 1)}))
    return 0


def nearest_root(path, roots):
    for r in roots:
        if path == r or path.startswith(r.rstrip(os.sep) + os.sep):
            return r
    return roots[0]


def upsert(con, batch):
    con.executemany(
        "INSERT OR REPLACE INTO files(path, title, artist, album, "
        "album_artist, year, genre, track_num, duration, mtime, source) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,'file')",
        [(r["path"], r["title"], r["artist"], r["album"],
          r["album_artist"], r["year"], r["genre"], r["track_num"],
          r["duration"], r["mtime"]) for r in batch])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
