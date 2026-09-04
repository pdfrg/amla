// Catalog queries over must's library.db (read-only) + temp albums + playlists.
// Pure JS: SQL builders, output parsers, and merges live here; the QML side
// runs them through one-shot Process calls (sqlite3 -json / sh).

function escapeLike(q) {
  return String(q).replace(/[\\%_]/g, function (c) { return "\\" + c })
}

// Shell-safe single-quoted SQL literal (value quotes doubled).
function sqlQuote(s) {
  return "'" + String(s || "").replace(/'/g, "''") + "'"
}

// Resolve a file path for player-reported metadata (MPRIS has no path of
// its own). Matches the app's artist coalescing; beets/lidarr tags trusted.
function trackPathSql(artist, album, title) {
  return "SELECT path FROM tracks WHERE COALESCE(NULLIF(album_artist,''), artist) = " + sqlQuote(artist) +
    " COLLATE NOCASE AND album = " + sqlQuote(album) + " COLLATE NOCASE AND title = " + sqlQuote(title) + " COLLATE NOCASE LIMIT 1"
}

// One sample track path for an album (art lookup + backfill).
function albumPathSql(artist, album) {
  return "SELECT path FROM tracks WHERE COALESCE(NULLIF(album_artist,''), artist) = " + sqlQuote(artist) +
    " COLLATE NOCASE AND album = " + sqlQuote(album) + " COLLATE NOCASE LIMIT 1"
}

// One row per history item lacking a path: {k, path} (path NULL when no
// local match). Scalar subqueries keep it a single sqlite3 call.
function backfillPathsSql(items) {
  var parts = []
  for (var i = 0; i < items.length; i++) {
    var it = items[i]
    var sel = it.type === "album" ? albumPathSql(it.artist, it.album) : trackPathSql(it.artist, it.album, it.title)
    parts.push("SELECT " + sqlQuote(it.key) + " AS k, (" + sel + ") AS path")
  }
  return parts.join(" UNION ALL ")
}

// FTS5 MATCH expression from raw user input: each whitespace token becomes a
// quoted prefix term. Quotes stripped; empty input → "" (caller skips SQL).
function ftsQuery(q) {
  var tokens = String(q).replace(/"/g, " ").split(/\s+/)
  var out = []
  for (var i = 0; i < tokens.length; i++) {
    var t = tokens[i].trim()
    if (t.length > 0)
      out.push("\"" + t + "\"*")
  }
  return out.join(" ")
}

function likeCond(q) {
  var e = escapeLike(q)
  return "LIKE '%" + e + "%' ESCAPE '\\'"
}

// Uniform song subtext: "song · Artist - Album" (parts omitted when
// empty, optional trailing source tag for remote rows).
function songSubtitle(artist, album, suffix) {
  var parts = []
  if (artist)
    parts.push(artist)
  if (album)
    parts.push(album)
  var s = "song"
  if (parts.length > 0)
    s += " · " + parts.join(" - ")
  if (suffix)
    s += " · " + suffix
  return s
}

// One batched statement: artists, albums, songs tiers via the same FTS match.
// Column aliases a1..a6 keep the union shapes identical.
function localSearchSql(q) {
  var m = ftsQuery(q)
  if (!m)
    return ""
  var join = "FROM tracks_fts f JOIN tracks t ON t.id = f.rowid WHERE tracks_fts MATCH '" + m.replace(/'/g, "''") + "'"
  return "SELECT * FROM (" +
    "SELECT 'artist' AS tier, COALESCE(NULLIF(t.album_artist,''), t.artist) AS a1, '' AS a2, '' AS a3, MIN(t.path) AS a4, 0 AS a5, COUNT(DISTINCT t.album) AS a6" +
    " " + join + " GROUP BY a1 ORDER BY a1 LIMIT 12" +
    ") UNION ALL SELECT * FROM (" +
    "SELECT 'album' AS tier, COALESCE(NULLIF(t.album_artist,''), t.artist) AS a1, t.album AS a2, '' AS a3, MIN(t.path) AS a4, MAX(t.year) AS a5, COUNT(*) AS a6" +
    " " + join + " GROUP BY a1, t.album ORDER BY a2 LIMIT 16" +
    ") UNION ALL SELECT * FROM (" +
    "SELECT 'song' AS tier, t.artist AS a1, t.album AS a2, t.title AS a3, t.path AS a4, t.year AS a5, CAST(t.duration AS INTEGER) AS a6" +
    " " + join + " LIMIT 30" +
    ");"
}

// Track list for a facet row (cliamp target has no library search): RAW SQL
// emitting a ready m3u body ("#EXTINF:-1,Artist - Title" + path per track).
// Passed to sqlite3 via env (no shell quoting); value quotes doubled SQL-side.
function pathsForKindM3uSql(kind, row) {
    var v = String(row.title || "").replace(/'/g, "''")
    var inf = "'#EXTINF:-1,' || COALESCE(NULLIF(album_artist,''), artist) || ' - ' || title || char(10) || path"
    if (kind === "artist")
        return "SELECT " + inf + " FROM tracks WHERE COALESCE(NULLIF(album_artist,''), artist) = '" + v + "' COLLATE NOCASE ORDER BY album, track_num"
    if (kind === "album") {
        var a = String(row.artist || "").replace(/'/g, "''")
        var where = "album = '" + v + "' COLLATE NOCASE"
        if (a.length > 0)
            where += " AND COALESCE(NULLIF(album_artist,''), artist) = '" + a + "' COLLATE NOCASE"
        return "SELECT " + inf + " FROM tracks WHERE " + where + " ORDER BY track_num"
    }
    if (kind === "genre")
        return "SELECT " + inf + " FROM tracks WHERE genre = '" + v + "' COLLATE NOCASE ORDER BY album, track_num"
    if (kind === "year")
        return "SELECT " + inf + " FROM tracks WHERE CAST(year AS TEXT) = '" + v + "' ORDER BY album, track_num"
    if (kind === "decade")
        return "SELECT " + inf + " FROM tracks WHERE year BETWEEN " + (parseInt(row.decade, 10) || 0) + " AND " + ((parseInt(row.decade, 10) || 0) + 9) + " ORDER BY album, track_num"
    return "SELECT path FROM tracks LIMIT 0"
}

// Facets: full genre + year lists, fetched once per popup open.
function facetSql() {
  return "SELECT genre AS g, COUNT(*) AS n FROM tracks WHERE genre != '' GROUP BY genre ORDER BY n DESC;" +
    "SELECT year AS y, COUNT(DISTINCT album) AS n FROM tracks WHERE year > 0 GROUP BY year ORDER BY year;"
}

// Temp albums + playlists in one shell pass. T<path> and P<path> lines.
function listingCommand(tempDirs, playlistDir) {
  var dirs = []
  for (var i = 0; i < tempDirs.length; i++)
    dirs.push(String(tempDirs[i]).replace(/'/g, "'\\''"))
  var cmd = ""
  for (var j = 0; j < dirs.length; j++) {
    cmd += "find '" + dirs[j] + "' -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sed 's/^/T/' | sort -f;"
  }
  if (playlistDir)
    cmd += "ls -1 '" + String(playlistDir).replace(/'/g, "'\\''") + "'/*.m3u 2>/dev/null | sed 's/^/P/';"
  return cmd
}

function basename(p) {
  var s = String(p || "")
  var idx = s.lastIndexOf("/")
  return idx >= 0 ? s.substring(idx + 1) : s
}

function parentDir(p) {
  var s = String(p || "")
  var idx = s.lastIndexOf("/")
  return idx > 0 ? s.substring(0, idx) : s
}

// sqlite3 -json emits one JSON array per statement, back to back.
function parseSqliteJson(out) {
  var text = String(out || "").trim()
  if (!text)
    return []
  var results = []
  var decoder = new JsonDecoder(text)
  while (true) {
    var arr = decoder.nextArray()
    if (arr === null)
      break
    for (var i = 0; i < arr.length; i++)
      results.push(arr[i])
  }
  return results
}

// Tolerant sequential reader for concatenated JSON arrays.
function JsonDecoder(text) {
  this.text = text
  this.pos = 0
}

JsonDecoder.prototype.nextArray = function () {
  var start = this.text.indexOf("[", this.pos)
  if (start < 0)
    return null
  var depth = 0
  var inStr = false
  var esc = false
  for (var i = start; i < this.text.length; i++) {
    var c = this.text.charAt(i)
    if (inStr) {
      if (esc)
        esc = false
      else if (c === "\\")
        esc = true
      else if (c === '"')
        inStr = false
      continue
    }
    if (c === '"')
      inStr = true
    else if (c === "[")
      depth++
    else if (c === "]") {
      depth--
      if (depth === 0) {
        this.pos = i + 1
        try {
          return JSON.parse(this.text.substring(start, i + 1))
        } catch (e) {
          return null
        }
      }
    }
  }
  return null
}

// listingCommand output → { temp: [paths], playlists: [paths] }
function parseListing(out) {
  var temp = []
  var playlists = []
  var lines = String(out || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.length < 2)
      continue
    var tag = line.charAt(0)
    var p = line.substring(1)
    if (tag === "T")
      temp.push(p)
    else if (tag === "P")
      playlists.push(p)
  }
  return { temp: temp, playlists: playlists }
}

// Cached facets (from facetSql) filtered by query → genre/year/decade rows.
// years: [{y: 1997, n: 4}, ...]
function facetRows(genres, years, q) {
  var rows = []
  var query = String(q || "").toLowerCase()
  if (query.length === 0)
    return rows
  var seenDecades = {}
  for (var i = 0; i < years.length; i++) {
    var y = years[i].y
    var ys = String(y)
    var decade = Math.floor(y / 10) * 10
    var decadeKey = String(decade)
    if (decadeKey.indexOf(query) === 0 && !seenDecades[decadeKey]) {
      seenDecades[decadeKey] = true
      rows.push({
        kind: "decade",
        badge: "",
        title: decade + "s",
        subtitle: "decade",
        decade: decade
      })
    }
    if (ys.indexOf(query) === 0)
      rows.push({
        kind: "year",
        badge: "",
        title: ys,
        subtitle: "year · " + years[i].n + " album" + (years[i].n === 1 ? "" : "s"),
        year: y
      })
  }
  // Exact match first, then prefix, then substring: a query of "rock"
  // surfaces "Rock" above "Prog Rock" (previously source order only).
  var exact = []
  var prefix = []
  var sub = []
  for (var j = 0; j < genres.length; j++) {
    var gl = String(genres[j].g).toLowerCase()
    var grow = {
      kind: "genre",
      badge: "",
      title: String(genres[j].g),
      subtitle: "genre · " + genres[j].n + " track" + (genres[j].n === 1 ? "" : "s")
    }
    if (gl === query)
      exact.push(grow)
    else if (gl.indexOf(query) === 0)
      prefix.push(grow)
    else if (gl.indexOf(query) >= 0)
      sub.push(grow)
  }
  return rows.concat(exact, prefix, sub)
}

// Local DB rows (tier,a1..a6) + listing caches → uniform result rows.
// DB tiers only (no listing rows): safe to call alongside listingRows.
function localDbRows(sqlRows) {
  var rows = []
  for (var i = 0; i < sqlRows.length; i++) {
    var r = sqlRows[i]
    if (r.tier === "artist")
      rows.push({
        kind: "artist",
        badge: "",
        title: String(r.a1),
        subtitle: "artist · " + r.a6 + " album" + (r.a6 === 1 ? "" : "s"),
        artist: String(r.a1),
        albumPath: String(r.a4)
      })
    else if (r.tier === "album")
      rows.push({
        kind: "album",
        badge: "",
        title: String(r.a2),
        subtitle: String(r.a1) + (r.a5 > 0 ? " · " + r.a5 : "") + " · " + r.a6 + " track" + (r.a6 === 1 ? "" : "s"),
        artist: String(r.a1),
        album: String(r.a2),
        albumPath: String(r.a4),
        year: r.a5
      })
    else if (r.tier === "song")
      rows.push({
        kind: "song",
        badge: "",
        title: String(r.a3),
        subtitle: songSubtitle(String(r.a1), String(r.a2), ""),
        artist: String(r.a1),
        album: String(r.a2),
        titleField: String(r.a3),
        path: String(r.a4),
        duration: r.a6
      })
  }
  return rows
}

// Playlists + temp albums from the cached directory listing. Call exactly
// once per rebuild -- localDbRows never includes these, so the two compose
// without duplicating (previously both came from one function called twice).
function listingRows(listing, q) {
  var query = String(q || "").toLowerCase()
  var rows = []
  for (var i = 0; i < listing.playlists.length; i++) {
    var pl = listing.playlists[i]
    var name = basename(pl).replace(/\.(m3u8?|M3U8?)$/, "")
    if (query.length === 0 || name.toLowerCase().indexOf(query) >= 0)
      rows.push({
        kind: "playlist",
        badge: "",
        title: name,
        subtitle: "playlist",
        path: pl
      })
  }

  for (i = 0; i < listing.temp.length; i++) {
    var tp = listing.temp[i]
    var tname = basename(tp)
    if (query.length === 0 || tname.toLowerCase().indexOf(query) >= 0)
      rows.push({
        kind: "temp",
        badge: "Temp",
        title: tname,
        subtitle: "temp · " + basename(parentDir(tp)),
        path: tp
      })
  }
  return rows
}

var TIER_ORDER = {
  artist: 0,
  album: 1,
  song: 2,
  genre: 3,
  year: 4,
  decade: 5,
  playlist: 6,
  temp: 7,
  "subsonic-artist": 8,
  "subsonic-album": 9,
  "subsonic-song": 10,
  "subsonic-genre": 11,
  "subsonic-year": 12
}

// Stable merge: favorite score (already ×1000 when the favorite matches the
// query, else 0) first, then tier order, then source order.
function mergeRanked(scoredRows, cap) {
  var rows = scoredRows.slice()
  rows.sort(function (a, b) {
    var fa = a.favScore || 0
    var fb = b.favScore || 0
    if (fa !== fb)
      return fb - fa
    var ta = TIER_ORDER[a.row.kind] !== undefined ? TIER_ORDER[a.row.kind] : 99
    var tb = TIER_ORDER[b.row.kind] !== undefined ? TIER_ORDER[b.row.kind] : 99
    if (ta !== tb)
      return ta - tb
    return a.order - b.order
  })
  var out = []
  for (var i = 0; i < rows.length && out.length < cap; i++)
    out.push(rows[i].row)
  return out
}

// ----- artwork (plan step 6) -----

function shq(p) {
    return "'" + String(p).replace(/'/g, "'\\''") + "'"
}

// One batched script per result batch: local dir probes (candidate cover
// files) + subsonic cache downloads. Output lines: A<dir>|<file>.
function artProbeCommand(jobs) {
    var lines = []
    for (var i = 0; i < jobs.length; i++) {
        var job = jobs[i]
        var out = job.out
        if (job.url) {
            lines.push("if [ -f " + shq(out) + " ]; then echo A" + shq(job.dir + "|" + out) +
                "; else rm -f " + shq(out) + "; curl -fs --max-time 10 -o " + shq(out) + " " + shq(job.url) +
                " && echo A" + shq(job.dir + "|" + out) + "; fi")
        } else {
            var candidates = ["folder.jpg", "cover.jpg", "album.jpg", "front.jpg", "front.png", "artist.jpg", "artist.png"]
            for (var c = 0; c < candidates.length; c++) {
                var f = job.dir + "/" + candidates[c]
                lines.push("[ -f " + shq(f) + " ] && echo A" + shq(job.dir + "|" + f))
            }
        }
    }
    return lines.join("; ")
}

function parseArtOutput(outText) {
    var map = {}
    var lines = String(outText || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
        var line = lines[i]
        if (line.charAt(0) !== "A")
            continue
        var rest = line.substring(1)
        var bar = rest.indexOf("|")
        if (bar < 0)
            continue
        map[rest.substring(0, bar)] = rest.substring(bar + 1)
    }
    return map
}

// Ordered artwork candidate dirs for a row (first hit wins in artFor).
// Artist rows probe the artist dir only (nested /artist/album/ layouts
// keep artist.jpg there); anything else falls back to a glyph — album
// covers are never shown as artist images. Others use artDirFor directly.
function artDirsFor(row) {
    if (!row)
        return []
    var out = []
    // Backfilled temp-album dir (history items whose file is untracked).
    if (row.artDir)
        out.push(row.artDir)
    if (row.kind === "artist") {
        var d = row.albumPath || row.path || ""
        if (!d)
            return out
        var albumDir = parentDir(d)
        var artistDir = parentDir(albumDir)
        if (artistDir && artistDir !== albumDir)
            out.push(artistDir)
        return out
    }
    var single = artDirFor(row)
    if (single && out.indexOf(single) < 0)
        out.push(single)
    return out
}

// Directory whose artwork represents a row.
function artDirFor(row) {
    if (!row)
        return ""
    switch (row.kind) {
    case "album":
        return row.albumPath ? parentDir(row.albumPath) : ""
    case "song":
    case "subsonic-song":
        return row.path ? parentDir(row.path) : (row.albumPath || "")
    case "temp":
        return row.path || ""
    case "artist":
        if (!row.albumPath && !row.path)
            return ""
        var aDir = parentDir(row.albumPath || row.path)
        var artistDir = parentDir(aDir)
        return artistDir && artistDir !== aDir ? artistDir : ""
    default:
        return ""
    }
}

// Art id for a subsonic row: the album id first for songs (per-song art
// rows can go stale server-side — mirror of must's loadSubsonicAlbumArtCmd
// preference; getCoverArt resolves a raw album id to the album image),
// else the row's own coverArt/id.
function subArtId(row) {
    if (!row)
        return ""
    if (row.kind === "subsonic-song" && row.albumId)
        return String(row.albumId)
    return String(row.coverArt || row.id || "")
}

// Disk-cache path for a subsonic coverArt id (~10-30 KB per file, size=96).
function subArtCacheFile(coverArtId, cacheDir) {
    var id = String(coverArtId || "")
    if (id.length === 0)
        return ""
    var safe = id.replace(/[^A-Za-z0-9_-]/g, "_")
    return cacheDir + "/" + safe + "-96.jpg"
}
