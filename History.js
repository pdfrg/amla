// Play history + favorites: ~/.local/state/amla/history.json.
// Score ported verbatim from old amla history.go:148-165:
//   score = playCount*10 + recency bonus (50 <24h, 25 <168h, 10 <720h, else 0)

var items = {}

function load(text) {
    items = {}
    var obj = {}
    try { obj = JSON.parse(String(text || "{}")) } catch (e) { obj = {} }
    if (obj && obj.items && typeof obj.items === "object")
        items = obj.items
}

function serialize() {
    return JSON.stringify({ "items": items }, null, 2) + "\n"
}

// Key per plan: song `artist|album|title`, album `aartist|album`,
// artist/genre/playlist/temp/subsonic-* = name, year = number.
function keyFor(type, artist, album, title) {
    if (type === "song")
        return (artist || "") + "|" + (album || "") + "|" + (title || "")
    if (type === "album")
        return (artist || "") + "|" + (album || "")
    return type === "year" ? String(title || album || "") : (title || artist || album || "")
}

function rowKey(row) {
    if (!row)
        return ""
    switch (row.kind) {
    case "song":
        return keyFor("song", row.artist, row.album, row.titleField)
    case "album":
        return keyFor("album", row.artist, row.album)
    case "artist":
    case "genre":
    case "playlist":
    case "temp":
    case "subsonic-artist":
    case "subsonic-album":
        return keyFor(row.kind, "", "", row.title)
    case "year":
        return keyFor("year", "", "", row.title)
    case "subsonic-song":
        return keyFor("song", row.artist, row.album, row.titleField)
    default:
        return ""
    }
}

// Strip a redundant "Artist - " title prefix (players reporting
// filename-style titles); leaves unrelated "Song - Remix" titles alone.
function stripArtistPrefix(artist, title) {
    var prefix = String(artist || "") + " - "
    if (artist && String(title || "").indexOf(prefix) === 0)
        return String(title).substring(prefix.length)
    return title
}

function setPath(key, path) {
    var it = items[key]
    if (!it || !path)
        return false
    path = String(path).split("\n")[0].trim()
    if (path.length === 0 || it.path === path)
        return false
    it.path = path
    return true
}

function recordPlay(type, artist, album, title, display, path, extra) {
    // Players sometimes report filename-style "Artist - Title" in the
    // title field; strip the redundant prefix so plays merge under the
    // clean key instead of spawning a parallel record. Only strips when
    // the prefix names this record's own artist -- "Song - Remix" by
    // someone else is untouched.
    if (type === "song" && artist && title) {
        var stripped = stripArtistPrefix(artist, title)
        if (stripped !== title) {
            title = stripped
            if (display !== undefined && display !== null && String(display).indexOf(String(artist) + " - ") === 0)
                display = String(display).substring(String(artist).length + 3)
        }
    }
    var key = keyFor(type, artist, album, title)
    if (key.length === 0)
        return false
    var now = new Date().toISOString()
    var it = items[key]
    if (!it) {
        it = {
            "type": type,
            "artist": artist || "",
            "album": album || "",
            "title": title || "",
            "display": display || title || album || artist || key,
            "playCount": 0,
            "lastPlayed": now,
            "path": path || ""
        }
        if (extra && extra.coverArt)
            it.coverArt = extra.coverArt
        if (extra && extra.subId)
            it.subId = extra.subId
        items[key] = it
    }
    if (extra && (extra.coverArt || extra.subId)) {
        if (extra.coverArt)
            it.coverArt = extra.coverArt
        if (extra.subId)
            it.subId = extra.subId
    }
    it.playCount = (it.playCount || 0) + 1
    it.lastPlayed = now
    return true
}

function hoursSince(iso) {
    var t = Date.parse(iso)
    if (isNaN(t))
        return Infinity
    return (Date.now() - t) / 3600000
}

// amla history.go:148-165
function scoreOf(it) {
    var score = (it.playCount || 0) * 10
    var h = hoursSince(it.lastPlayed)
    if (h < 24)
        score += 50
    else if (h < 168)
        score += 25
    else if (h < 720)
        score += 10
    return score
}

// Map of key -> item, for rebuild-time scoring.
function favoriteIndex() {
    return items
}

function topFavorites(n) {
    var keys = Object.keys(items)
    var scored = []
    for (var i = 0; i < keys.length; i++) {
        var it = items[keys[i]]
        scored.push({
            "key": keys[i],
            "item": it,
            "score": scoreOf(it)
        })
    }
    scored.sort(function (a, b) {
        if (b.score !== a.score)
            return b.score - a.score
        return Date.parse(b.item.lastPlayed || 0) - Date.parse(a.item.lastPlayed || 0)
    })
    return scored.slice(0, n)
}

function recentPlays(n) {
    var keys = Object.keys(items)
    var recent = []
    for (var i = 0; i < keys.length; i++)
        recent.push(items[keys[i]])
    recent.sort(function (a, b) {
        return Date.parse(b.lastPlayed || 0) - Date.parse(a.lastPlayed || 0)
    })
    return recent.slice(0, n)
}

// Uniform song subtext: "song · Artist - Album" (parts omitted when empty).
function songSubtitle(artist, album) {
    var parts = []
    if (artist)
        parts.push(artist)
    if (album)
        parts.push(album)
    var s = "song"
    if (parts.length > 0)
        s += " · " + parts.join(" - ")
    return s
}

function favoriteRow(it) {
    var kindMap = {
        "song": "song",
        "album": "album",
        "artist": "artist",
        "genre": "genre",
        "year": "year",
        "playlist": "playlist",
        "temp": "temp"
    }
    var kind = kindMap[it.type] || "artist"
    var subtitle = kind
    if (kind === "song")
        subtitle = songSubtitle(it.artist, it.album, "")
    else if (kind === "album" && it.artist)
        subtitle = it.artist + " · album"
    var row = {
        "kind": kind,
        "badge": "",
        "title": it.display || it.title || it.album || it.artist,
        "subtitle": subtitle,
        "star": true,
        "artist": it.artist,
        "album": it.album,
        "titleField": it.title,
        "path": it.path || "",
        "year": it.type === "year" ? parseInt(it.title, 10) || 0 : undefined
    }
    // History flattens subsonic plays to local types; restore the origin so
    // artwork (and dispatch) treat them as subsonic rows again.
    if ((kind === "song" || kind === "album" || kind === "artist") && (it.coverArt || it.subId)) {
        row.kind = "subsonic-" + kind
        row.coverArt = it.coverArt || ""
        row.id = it.subId || ""
    }
    // Album art resolves from a sample track file of that album.
    if (kind === "album")
        row.albumPath = it.path || ""
    return row
}

// Empty query: top 12 favorites, 6 most recent (deduped), then a
// "Play random album" action row.
function emptyStateRows(mustConfig, listing) {
    var rows = []
    var favs = topFavorites(12)
    for (var i = 0; i < favs.length; i++)
        rows.push(favoriteRow(favs[i].item))
    var seen = {}
    for (var j = 0; j < rows.length; j++)
        seen[rows[j].title] = true
    var recent = recentPlays(6)
    for (var k = 0; k < recent.length; k++) {
        var label = recent[k].display || recent[k].title
        if (seen[label])
            continue
        seen[label] = true
        rows.push(favoriteRow(recent[k]))
    }
    rows.push({
        "kind": "action",
        "badge": "",
        "title": "Random album (all sources)",
        "subtitle": "local · temp · subsonic",
        "action": "random-album"
    })
    rows.push({
        "kind": "action",
        "badge": "",
        "title": "Random album (local)",
        "subtitle": "local",
        "action": "random-album-local"
    })
    rows.push({
        "kind": "action",
        "badge": "",
        "title": "Random album (subsonic)",
        "subtitle": "subsonic",
        "action": "random-album-subsonic"
    })
    rows.push({
        "kind": "action",
        "badge": "",
        "title": "Random album (temp)",
        "subtitle": "temp",
        "action": "random-album-temp"
    })
    return rows
}
