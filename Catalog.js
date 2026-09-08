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
function trackPathSql(artist, album, title, table) {
  var t = table || "tracks"
  return "SELECT path FROM " + t + " WHERE COALESCE(NULLIF(album_artist,''), artist) = " + sqlQuote(artist) +
    " COLLATE NOCASE AND album = " + sqlQuote(album) + " COLLATE NOCASE AND title = " + sqlQuote(title) + " COLLATE NOCASE LIMIT 1"
}

// One sample track path for an album (art lookup + backfill).
function albumPathSql(artist, album, table) {
  var t = table || "tracks"
  return "SELECT path FROM " + t + " WHERE COALESCE(NULLIF(album_artist,''), artist) = " + sqlQuote(artist) +
    " COLLATE NOCASE AND album = " + sqlQuote(album) + " COLLATE NOCASE LIMIT 1"
}

// One row per history item lacking a path: {k, path} (path NULL when no
// local match). Scalar subqueries keep it a single sqlite3 call.
function backfillPathsSql(items, table) {
  var parts = []
  for (var i = 0; i < items.length; i++) {
    var it = items[i]
    var sel = it.type === "album" ? albumPathSql(it.artist, it.album, table) : trackPathSql(it.artist, it.album, it.title, table)
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
function pathsForKindM3uSql(kind, row, randomOrder, table) {
    var t = table || "tracks"
    var v = String(row.title || "").replace(/'/g, "''")
    // EXTINF carries real duration but NO title: cliamp takes a wholesale
    // m3u title literally (no Album field → no album-header grouping),
    // while an empty title falls through to tag probing, yielding
    // structured Artist/Album/Title + durations (Q6). Both tables have
    // a seconds duration column.
    // Playshuffle pre-shuffles in SQL (cliamp pins the loaded head at
    // position 0, so deterministic ORDER BY would always start the same
    // track); plain play keeps album/track order.
    var albumOrder = randomOrder ? "ORDER BY RANDOM()" : "ORDER BY album, track_num"
    var trackOrder = randomOrder ? "ORDER BY RANDOM()" : "ORDER BY track_num"
    var inf = "'#EXTINF:' || CAST(COALESCE(duration, 0) AS INTEGER) || ',' || char(10) || path"
    if (kind === "artist")
        return "SELECT " + inf + " FROM " + t + " WHERE COALESCE(NULLIF(album_artist,''), artist) = '" + v + "' COLLATE NOCASE " + albumOrder
    if (kind === "album") {
        var a = String(row.artist || "").replace(/'/g, "''")
        var where = "album = '" + v + "' COLLATE NOCASE"
        if (a.length > 0)
            where += " AND COALESCE(NULLIF(album_artist,''), artist) = '" + a + "' COLLATE NOCASE"
        return "SELECT " + inf + " FROM " + t + " WHERE " + where + " " + trackOrder
    }
    if (kind === "genre")
        return "SELECT " + inf + " FROM " + t + " WHERE genre = '" + v + "' COLLATE NOCASE " + albumOrder
    if (kind === "year")
        return "SELECT " + inf + " FROM " + t + " WHERE CAST(year AS TEXT) = '" + v + "' " + albumOrder
    if (kind === "decade")
        return "SELECT " + inf + " FROM " + t + " WHERE year BETWEEN " + (parseInt(row.decade, 10) || 0) + " AND " + ((parseInt(row.decade, 10) || 0) + 9) + " " + albumOrder
    return "SELECT path FROM " + t + " LIMIT 0"
}

// Track list for an MPD dispatch: same filters as pathsForKindM3uSql
// but bare paths (one per row) — the helper maps them into
// music_directory-relative URIs. Playshuffle needs no SQL pre-shuffle:
// the daemon shuffles server-side.
function pathsForKindSql(kind, row, table) {
    var t = table || "tracks"
    var v = String(row.title || "").replace(/'/g, "''")
    var albumOrder = "ORDER BY album, track_num"
    var trackOrder = "ORDER BY track_num"
    if (kind === "artist")
        return "SELECT path FROM " + t + " WHERE COALESCE(NULLIF(album_artist,''), artist) = '" + v + "' COLLATE NOCASE " + albumOrder
    if (kind === "album") {
        var a = String(row.artist || "").replace(/'/g, "''")
        var where = "album = '" + v + "' COLLATE NOCASE"
        if (a.length > 0)
            where += " AND COALESCE(NULLIF(album_artist,''), artist) = '" + a + "' COLLATE NOCASE"
        return "SELECT path FROM " + t + " WHERE " + where + " " + trackOrder
    }
    if (kind === "genre")
        return "SELECT path FROM " + t + " WHERE genre = '" + v + "' COLLATE NOCASE " + albumOrder
    if (kind === "year")
        return "SELECT path FROM " + t + " WHERE CAST(year AS TEXT) = '" + v + "' " + albumOrder
    if (kind === "decade")
        return "SELECT path FROM " + t + " WHERE year BETWEEN " + (parseInt(row.decade, 10) || 0) + " AND " + ((parseInt(row.decade, 10) || 0) + 9) + " " + albumOrder
    return "SELECT path FROM " + t + " LIMIT 0"
}

// Directory expansion for MPD temp/library rows: audio files under dir.
// LIKE metacharacters escaped (underscores are common in dir names);
// the extension filter keeps stray art/text out of the queue.
function pathsUnderDirSql(dir, table) {
    var t = table || "tracks"
    var d = String(dir || "").replace(/'/g, "''").replace(/\\/g, "\\\\").replace(/%/g, "\\%").replace(/_/g, "\\_")
    var ext = ["mp3", "flac", "ogg", "oga", "opus", "m4a", "aac", "wav", "aiff", "ape", "wv"]
    var conds = []
    for (var i = 0; i < ext.length; i++)
        conds.push("path LIKE '%." + ext[i] + "' COLLATE NOCASE")
    return "SELECT path FROM " + t + " WHERE path LIKE '" + d + "/%' ESCAPE '\\' AND (" + conds.join(" OR ") + ") ORDER BY path"
}

// Facets: full genre + year lists, fetched once per popup open.
function facetSql() {
  return "SELECT genre AS g, COUNT(DISTINCT album) AS n FROM tracks WHERE genre != '' GROUP BY genre ORDER BY n DESC;" +
    "SELECT year AS y, COUNT(DISTINCT album) AS n FROM tracks WHERE year > 0 GROUP BY year ORDER BY year;"
}

// Facets over the amla file index: same g/y shapes as facetSql so the
// facetProc handler parses both identically.
function filesFacetSql() {
  return "SELECT genre AS g, COUNT(DISTINCT album) AS n FROM files WHERE genre != '' GROUP BY genre ORDER BY n DESC;" +
    "SELECT year AS y, COUNT(DISTINCT album) AS n FROM files WHERE year > 0 GROUP BY year ORDER BY year;"
}

// Tiered search over the amla file index: same tier/a1..a6 shapes as
// localSearchSql so localDbRows consumes both.
function filesSearchSql(q) {
  var m = ftsQuery(q)
  if (!m)
    return ""
  var join = "FROM files_fts f JOIN files t ON t.rowid = f.rowid WHERE files_fts MATCH '" + m.replace(/'/g, "''") + "'"
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

// Temp albums + playlists + library dirs in one shell pass.
// T<path> and L<path> lines; P<count>\t<path> (must m3u, exact entries)
// and C<count>[+]\t<path> (cliamp toml, + when [[dir]]-backed). Library dirs are depth 1-2 under
// each music root (covers flat "Artist - Album" and nested
// "Artist/Album" layouts); bucket dirs are harmless — they play the
// whole subtree via url.load, and the file index supersedes them later.
function listingCommand(tempDirs, playlistDir, musicDirs, cliampPlaylistDir) {
  var dirs = []
  for (var i = 0; i < tempDirs.length; i++)
    dirs.push(String(tempDirs[i]).replace(/'/g, "'\\''"))
  var cmd = ""
  for (var j = 0; j < dirs.length; j++) {
    cmd += "/usr/bin/find '" + dirs[j] + "' -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | /usr/bin/sed 's/^/T/' | /usr/bin/sort -f;"
  }
  if (playlistDir) {
    // must m3u dir: one P<count>\t<path> line per playlist; the count is
    // the entry lines (non-# non-blank), shown in the subtitle.
    var pd = String(playlistDir).replace(/'/g, "'\\''")
    cmd += "for f in '" + pd + "'/*.m3u '" + pd + "'/*.m3u8 '" + pd + "'/*.M3U '" + pd + "'/*.M3U8; do [ -e \"$f\" ] || continue; printf 'P%d\\t%s\\n' \"$(/usr/bin/grep -cv -e '^#' -e '^$' \"$f\")\" \"$f\"; done;"
  }
  if (cliampPlaylistDir) {
    // cliamp toml dir: one C<count>[+]\t<path> line per playlist.
    // [[track]] sections are exact; a [[dir]] source scans at load so
    // the count is a lower bound, marked with +.
    var cd = String(cliampPlaylistDir).replace(/'/g, "'\\''")
    cmd += "for f in '" + cd + "'/*.toml '" + cd + "'/*.TOML; do [ -e \"$f\" ] || continue; n=$(/usr/bin/grep -c '^\\[\\[track\\]\\]' \"$f\"); d=''; /usr/bin/grep -q '^\\[\\[dir\\]\\]' \"$f\" && d='+'; printf 'C%s%s\\t%s\\n' \"$n\" \"$d\" \"$f\"; done;"
  }
  var roots = []
  for (var k = 0; k < (musicDirs || []).length; k++)
    roots.push(String(musicDirs[k]).replace(/'/g, "'\\''"))
  for (var m = 0; m < roots.length; m++) {
    cmd += "/usr/bin/find '" + roots[m] + "' -mindepth 1 -maxdepth 2 -type d -print 2>/dev/null | /usr/bin/sed 's/^/L/' | /usr/bin/sort -f;"
  }
  for (var s = 0; s < roots.length; s++) {
    // Stray playlists: entry counts exactly like the must-dir pass;
    // parseListing dedups paths (a playlist dir inside a music root
    // keeps its P-line identity — first-seen wins).
    cmd += "/usr/bin/find '" + roots[s] + "' -type f \\( -iname '*.m3u' -o -iname '*.m3u8' \\) -print 2>/dev/null | while IFS= read -r f; do printf 'S%d\\t%s\\n' \"$(/usr/bin/grep -cv -e '^#' -e '^$' \"$f\")\" \"$f\"; done;";
  }
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

// listingCommand output → { temp: [paths], playlists: [{ path, source,
// count, dirBacked }], library: [paths] }. P = must m3u (count exact),
// C = cliamp toml (count = [[track]] sections, + when [[dir]] backed),
// S = stray m3u under a music root (count exact, source "stray").
function parseListing(out) {
  var temp = []
  var playlists = []
  var library = []
  var lines = String(out || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.length < 2)
      continue
    var tag = line.charAt(0)
    var p = line.substring(1)
    if (tag === "T")
      temp.push(p)
    else if (tag === "P" || tag === "C" || tag === "S") {
      var tab = p.indexOf("\t")
      var count = -1
      var dirBacked = false
      var pp = p
      if (tab >= 0) {
        var num = p.substring(0, tab)
        if (num.charAt(num.length - 1) === "+") {
          dirBacked = true
          num = num.substring(0, num.length - 1)
        }
        count = parseInt(num, 10)
        if (isNaN(count))
          count = -1
        pp = p.substring(tab + 1)
      }
      // Stray (S) rows come from the music-root scan; a playlist dir
      // inside a music root also emits P — first-seen wins, so the
      // designated-dir identity (must/cliamp) is kept.
      var src = tag === "C" ? "cliamp" : (tag === "S" ? "stray" : "must")
      var dup = false
      for (var d = 0; d < playlists.length; d++) if (playlists[d].path === pp) {
        dup = true;
        break;
      }
      if (!dup)
        playlists.push({ path: pp, source: src, count: count, dirBacked: dirBacked })
    } else if (tag === "L")
      library.push(p)
  }
  return { temp: temp, playlists: playlists, library: library }
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
      subtitle: "genre · " + genres[j].n + " album" + (genres[j].n === 1 ? "" : "s")
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

// §14 temp folder names: "Artist - YYYY - Album - MP3 320k - TAG" →
// {artist, album, year}. Tag salad (codec, bitrate, source caps-words)
// is stripped so temp rows render a predictable "Artist - Album";
// noiseTokens (amla config) extends the built-in strip patterns.
// Unparseable names fall back to the raw basename.
function tempNoiseExtra(noiseTokens) {
  return (noiseTokens || []).map(function (x) { return String(x).toLowerCase() })
}
function tempTokenIsNoise(tok, extra) {
  var t = String(tok || "").trim()
  if (t.length === 0)
    return true
  var low = t.toLowerCase()
  if (extra && extra.indexOf(low) >= 0)
    return true
  if (/mp3|flac|alac|wav|aiff|ogg|vorbis|opus|m4a|aac|kbps|kbit|\b\d+k\b|\bbit\b|khz|lossless|cbr|vbr/i.test(t))
    return true
  // Source caps-tags (ENRICH, NICFEIN, SC4R3CR0W): all-caps/digits.
  // Only consulted past the album slot, so a caps album falls back
  // to the raw name instead of mis-splitting.
  if (/^[A-Z0-9]{3,}$/.test(t))
    return true
  return false
}
function parseTempName(name, noiseTokens) {
  var raw = String(name || "")
  var extra = tempNoiseExtra(noiseTokens)
  var parts = raw.split(/\s+-\s+/)
  var year = 0
  var yi = -1
  for (var i = 0; i < parts.length; i++) {
    if (/^(19|20)\d\d$/.test(parts[i].trim())) {
      year = parseInt(parts[i].trim(), 10)
      yi = i
      break
    }
  }
  var artist = ""
  var album = ""
  if (yi >= 0) {
    artist = parts.slice(0, yi).join(" - ").trim()
    for (var j = yi + 1; j < parts.length; j++) {
      if (!tempTokenIsNoise(parts[j], extra)) {
        album = parts[j].trim()
        break
      }
    }
  } else if (parts.length === 2) {
    artist = parts[0].trim()
    album = parts[1].trim()
  } else if (parts.length === 1) {
    album = parts[0].trim()
  } else if (parts.length > 2) {
    artist = parts[0].trim()
    album = parts.slice(1).join(" - ").trim()
  }
  if (!album)
    return { "artist": "", "album": "", "year": 0, "title": raw }
  return {
    "artist": artist,
    "album": album,
    "year": year,
    "title": artist ? artist + " - " + album : album
  }
}

// Playlists + temp albums from the cached directory listing. Call exactly
// once per rebuild -- localDbRows never includes these, so the two compose
// without duplicating (previously both came from one function called twice).
// NOTE: dir-level library rows were removed (no-must is the normal mode
// and the file index supersedes them); temp dirs stay by design.
function listingRows(listing, q, noiseTokens) {
  var query = String(q || "").toLowerCase()
  var rows = []
  for (var i = 0; i < listing.playlists.length; i++) {
    var pl = listing.playlists[i]
    var name = basename(pl.path).replace(/\.(m3u8?|M3U8?|toml|TOML)$/, "")
    if (query.length === 0 || name.toLowerCase().indexOf(query) >= 0) {
      // Counts come from the listing pass (m3u entries exact, toml
      // [[track]] sections with + when [[dir]]-backed and unbounded).
      var n = pl.count >= 0 ? String(pl.count) + (pl.dirBacked ? "+" : "") : "?"
      var unit = (!pl.dirBacked && pl.count === 1) ? " track" : " tracks"
      rows.push({
        kind: "playlist",
        badge: "",
        title: name,
        subtitle: "playlist · " + n + unit + " · " + pl.source,
        path: pl.path,
        source: pl.source,
        count: pl.count
      })
    }
  }

  for (i = 0; i < listing.temp.length; i++) {
    var tp = listing.temp[i]
    var tname = basename(tp)
    if (query.length === 0 || tname.toLowerCase().indexOf(query) >= 0) {
      // §14: strip tag salad so the row reads "Artist - Album"
      // (query still matches the raw folder name above).
      var parsed = parseTempName(tname, noiseTokens)
      rows.push({
        kind: "temp",
        badge: "Temp",
        title: parsed.title,
        subtitle: "temp · " + basename(parentDir(tp)) + (parsed.year > 0 ? " · " + parsed.year : ""),
        path: tp,
        artist: parsed.artist,
        album: parsed.album,
        year: parsed.year
      })
    }
  }
  // Dir-level library rows: removed. The file index (facets + search)
  // covers local browsing with zero must; temp dirs above are the only
  // folder rows by design.
  return rows
}

// Shuffle an m3u body for playshuffle pre-shuffle (cliamp's doShuffle
// pins the loaded head at 0, so the body itself must arrive shuffled —
// same policy as the facet flows). #EXTM3U stays first; #EXTINF stays
// glued to its entry; every other line shuffles as a singleton.
function shuffleM3uBody(body) {
  var chunks = []
  var head = null
  var lines = String(body || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var ln = lines[i]
    if (ln.length === 0)
      continue
    if (head === null && ln.indexOf("#EXTM3U") === 0) {
      head = ln
      continue
    }
    if (ln.indexOf("#EXTINF") === 0 && i + 1 < lines.length) {
      chunks.push(ln + "\n" + lines[i + 1])
      i++
      continue
    }
    chunks.push(ln)
  }
  for (var j = chunks.length - 1; j > 0; j--) {
    var k = Math.floor(Math.random() * (j + 1))
    var t = chunks[j]
    chunks[j] = chunks[k]
    chunks[k] = t
  }
  if (head !== null)
    chunks.unshift(head)
  return chunks.join("\n") + "\n"
}

var TIER_ORDER = {
  artist: 0,
  album: 1,
  playlist: 2,
  genre: 3,
  year: 4,
  decade: 5,
  temp: 6,
  library: 6,
  song: 7,
  "subsonic-artist": 0,
  "subsonic-album": 1,
  "subsonic-playlist": 2,
  "subsonic-genre": 3,
  "subsonic-year": 4,
  "subsonic-decade": 5,
  "subsonic-song": 7
}

// Title match quality vs the raw query: 2 exact, 1 prefix, else 0.
// Title-only on purpose: a row that matched via another field (a song
// found through its artist) scores 0 and sinks below title matches.
function matchQuality(title, q) {
  var t = String(title || "").toLowerCase()
  var query = String(q || "").toLowerCase()
  if (query.length === 0 || t.length === 0)
    return 0
  if (t === query)
    return 2
  if (t.indexOf(query) === 0)
    return 1
  return 0
}

// Stable merge: favorite score (already ×1000 when the favorite matches the
// query, else 0) first, then tier order, then title match quality, then
// source order.
// Local and subsonic kinds share tiers (interleaved by kind); within a
// tier the source order tiebreak puts local rows first. Containers rank
// above tracks: collection matches are few, song matches are many.
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
    var ma = a.matchScore || 0
    var mb = b.matchScore || 0
    if (ma !== mb)
      return mb - ma
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
                "; else /usr/bin/rm -f " + shq(out) + "; /usr/bin/curl -fs --max-time 10 -o " + shq(out) + " " + shq(job.url) +
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
    case "library":
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

// amla-owned file index (§13): same columns as the must queries plus
// mtime (incremental refresh) and source ('file' now, 'mpd' later per
// §18 — the old Go amla's trick, so mpd sync needs no migration).
function filesDbSchema() {
    return "CREATE TABLE IF NOT EXISTS files" +
        "(path TEXT PRIMARY KEY, title TEXT DEFAULT '', artist TEXT DEFAULT '', album TEXT DEFAULT '', " +
        "album_artist TEXT DEFAULT '', year INTEGER DEFAULT 0, genre TEXT DEFAULT '', " +
        "track_num INTEGER DEFAULT 0, duration INTEGER DEFAULT 0, mtime INTEGER DEFAULT 0, source TEXT DEFAULT 'file');" +
        "CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5" +
        "(title, artist, album, album_artist, genre, content='files', content_rowid='rowid');" +
        "CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN " +
        "INSERT INTO files_fts(rowid, title, artist, album, album_artist, genre) " +
        "VALUES (new.rowid, new.title, new.artist, new.album, new.album_artist, new.genre); END;" +
        "CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN " +
        "INSERT INTO files_fts(files_fts, rowid, title, artist, album, album_artist, genre) " +
        "VALUES ('delete', old.rowid, old.title, old.artist, old.album, old.album_artist, old.genre); END;" +
        "CREATE TRIGGER IF NOT EXISTS files_au AFTER UPDATE ON files BEGIN " +
        "INSERT INTO files_fts(files_fts, rowid, title, artist, album, album_artist, genre) " +
        "VALUES ('delete', old.rowid, old.title, old.artist, old.album, old.album_artist, old.genre); " +
        "INSERT INTO files_fts(rowid, title, artist, album, album_artist, genre) " +
        "VALUES (new.rowid, new.title, new.artist, new.album, new.album_artist, new.genre); END;"
}
