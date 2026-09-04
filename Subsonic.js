.import "Md5.js" as Md5
// Subsonic client helpers: URL builders + response shaping. Pure JS; HTTP
// runs elsewhere (fetch in tests, curl via Process in the plugin).
// Auth per plan: token = md5(password+salt), params u,t,s,v,c=amla.

function authParams(username, password, salt) {
    return "u=" + encodeURIComponent(username) +
        "&t=" + Md5.subsonicToken(password, salt) +
        "&s=" + salt +
        "&v=1.16.1" +
        "&c=amla" +
        "&f=json"
}

function apiUrl(baseUrl, path, query) {
    return baseUrl.replace(/\/+$/, "") + "/rest/" + path + "?" + query
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

function search3Url(baseUrl, auth, query) {
    return apiUrl(baseUrl, "search3", auth +
        "&query=" + encodeURIComponent(String(query || "")) +
        "&artistCount=8&albumCount=20&songCount=40")
}

function genresUrl(baseUrl, auth) {
    return apiUrl(baseUrl, "getGenres", auth)
}

function byYearUrl(baseUrl, auth) {
    return apiUrl(baseUrl, "getAlbumList2", auth +
        "&type=byYear&fromYear=0&toYear=9999&size=500")
}

function songsByGenreUrl(baseUrl, auth, genre) {
    return apiUrl(baseUrl, "getSongsByGenre", auth +
        "&genre=" + encodeURIComponent(String(genre || "")) + "&count=500")
}

function albumsByYearUrl(baseUrl, auth, fromYear, toYear) {
    return apiUrl(baseUrl, "getAlbumList2", auth +
        "&type=byYear&fromYear=" + (fromYear || 0) + "&toYear=" + (toYear || 9999) + "&size=500")
}

function albumTracksUrl(baseUrl, auth, albumId) {
    return apiUrl(baseUrl, "getAlbum", auth + "&id=" + encodeURIComponent(String(albumId || "")))
}

// search3 song-only lookup (provider-op fallback, backfill-style).
function songsSearchUrl(baseUrl, auth, query, count) {
    return apiUrl(baseUrl, "search3", auth +
        "&query=" + encodeURIComponent(String(query || "")) +
        "&artistCount=0&albumCount=0&songCount=" + (count || 100))
}

// getSongsByGenre → song children for m3u building.
function genreSongs(sub) {
    if (!sub || !sub.songsByGenre || !sub.songsByGenre.song)
        return []
    return sub.songsByGenre.song
}

// search3 response → raw song children for m3u building.
function searchSongs(sub) {
    if (!sub || !sub.searchResult3 || !sub.searchResult3.song)
        return []
    return sub.searchResult3.song
}

// getAlbumList2 → album entries for year expansion.
function yearAlbums(sub) {
    if (!sub || !sub.albumList2 || !sub.albumList2.album)
        return []
    return sub.albumList2.album
}

// getAlbum → song children for m3u building.
function albumSongs(sub) {
    if (!sub || !sub.album || !sub.album.song)
        return []
    return sub.album.song
}

function randomAlbumUrl(baseUrl, auth) {
    return apiUrl(baseUrl, "getAlbumList2", auth + "&type=random&size=1")
}

// History backfill: identify an origin-less favorite on the server so its
// cover (and subsonic dispatch identity) resolves. One lookup per item;
// the QML side caps items per run.
function backfillSongUrl(baseUrl, auth, artist, title) {
    return apiUrl(baseUrl, "search3", auth +
        "&query=" + encodeURIComponent(String(artist || "") + " " + String(title || "")) +
        "&artistCount=0&albumCount=0&songCount=5")
}

function backfillAlbumUrl(baseUrl, auth, artist, album) {
    return apiUrl(baseUrl, "search3", auth +
        "&query=" + encodeURIComponent(String(artist || "") + " " + String(album || "")) +
        "&artistCount=0&albumCount=3&songCount=0")
}

function normId(s) {
    return String(s || "").toLowerCase().replace(/[^a-z0-9]/g, "")
}

// First song whose normalized title exactly matches (strict: avoids
// attaching a wrong identity to stale local entries).
function songIdMatch(sub, normTitle) {
    var songs = (sub && sub.searchResult3 && sub.searchResult3.song) || []
    var want = String(normTitle || "")
    if (want.length === 0)
        return null
    for (var i = 0; i < songs.length; i++) {
        if (normId(songs[i].title) === want)
            return {
                "id": songs[i].id || "",
                "coverArt": songs[i].coverArt || "",
                "albumId": songs[i].albumId || ""
            }
    }
    return null
}

// First album whose normalized name exactly matches.
function albumIdMatch(sub, normAlbum) {
    var albums = (sub && sub.searchResult3 && sub.searchResult3.album) || []
    var want = String(normAlbum || "")
    if (want.length === 0)
        return null
    for (var j = 0; j < albums.length; j++) {
        if (normId(albums[j].name) === want)
            return {
                "id": albums[j].id || "",
                "coverArt": albums[j].coverArt || ""
            }
    }
    return null
}

function coverArtUrl(baseUrl, auth, coverArtId, size) {
    return apiUrl(baseUrl, "getCoverArt", auth +
        "&id=" + encodeURIComponent(String(coverArtId || "")) +
        "&size=" + (size || 96))
}

function streamUrl(baseUrl, auth, songId) {
    return apiUrl(baseUrl, "stream", auth + "&id=" + encodeURIComponent(String(songId || "")))
}

function getSubsonic(res) {
    var body = typeof res === "string" ? JSON.parse(res) : res
    var sub = body && body["subsonic-response"]
    if (!sub || sub.status !== "ok")
        return null
    return sub
}

// search3 response → uniform rows (badge = server name).
function searchRows(sub, serverName, serverBadge, query) {
    var out = []
    if (!sub)
        return out
    var q = String(query || "").toLowerCase()
    var i, a
    var artists = (sub.searchResult3 && sub.searchResult3.artist) || []
    for (i = 0; i < artists.length; i++) {
        a = artists[i]
        if (String(a.name).toLowerCase().indexOf(q) < 0)
            continue
        out.push({
            "kind": "subsonic-artist",
            "badge": serverBadge,
            "title": String(a.name),
            "subtitle": (serverName || "Subsonic") + " · artist",
            "artist": String(a.name),
            "coverArt": a.coverArt || "",
            "id": a.id || ""
        })
    }
    var albums = (sub.searchResult3 && sub.searchResult3.album) || []
    for (i = 0; i < albums.length; i++) {
        a = albums[i]
        if (String(a.name).toLowerCase().indexOf(q) < 0 && String(a.artist || "").toLowerCase().indexOf(q) < 0)
            continue
        out.push({
            "kind": "subsonic-album",
            "badge": serverBadge,
            "title": String(a.name),
            "subtitle": String(a.artist || "") + (a.year ? " · " + a.year : "") + " · " + (serverName || "Subsonic"),
            "artist": String(a.artist || ""),
            "album": String(a.name),
            "coverArt": a.coverArt || "",
            "id": a.id || "",
            "year": a.year || 0
        })
    }
    var songs = (sub.searchResult3 && sub.searchResult3.song) || []
    for (i = 0; i < songs.length; i++) {
        a = songs[i]
        if (String(a.title).toLowerCase().indexOf(q) < 0 && String(a.artist || "").toLowerCase().indexOf(q) < 0)
            continue
        out.push({
            "kind": "subsonic-song",
            "badge": serverBadge,
            "title": String(a.title),
            "subtitle": songSubtitle(String(a.artist || ""), String(a.album || ""), (serverName || "Subsonic")),
            "artist": String(a.artist || ""),
            "album": String(a.album || ""),
            "titleField": String(a.title),
            "coverArt": a.coverArt || "",
            "albumId": a.albumId || "",
            "id": a.id || "",
            "duration": a.duration || 0
        })
    }
    return out
}

// getGenres → [{g, n}] (genre rows filtered client-side by Catalog.facetRows).
function genreFacets(sub) {
    if (!sub || !sub.genres || !sub.genres.genre)
        return []
    var out = []
    var arr = sub.genres.genre
    for (var i = 0; i < arr.length; i++)
        out.push({
            "g": String(arr[i].value || arr[i].content || ""),
            "n": arr[i].albumCount || 0
        })
    return out
}

// getAlbumList2(byYear) → [{y, n}] histogram for year/decade rows.
function yearFacets(sub) {
    if (!sub || !sub.albumList2 || !sub.albumList2.album)
        return []
    var counts = {}
    var order = []
    var arr = sub.albumList2.album
    for (var i = 0; i < arr.length; i++) {
        var y = arr[i].year || 0
        if (y <= 0)
            continue
        if (counts[y] === undefined) {
            counts[y] = 0
            order.push(y)
        }
        counts[y]++
    }
    order.sort(function (a, b) { return a - b })
    var out = []
    for (var j = 0; j < order.length; j++)
        out.push({
            "y": order[j],
            "n": counts[order[j]]
        })
    return out
}

// getAlbumList2(random) → single subsonic-album row for "play random album".
function randomAlbumRow(sub, serverName, serverBadge) {
    if (!sub || !sub.albumList2 || !sub.albumList2.album || !sub.albumList2.album.length)
        return null
    var a = sub.albumList2.album[0]
    return {
        "kind": "subsonic-album",
        "badge": serverBadge,
        "title": String(a.name || ""),
        "subtitle": String(a.artist || "") + (a.year ? " · " + a.year : "") + " · " + (serverName || "Subsonic"),
        "artist": String(a.artist || ""),
        "album": String(a.name || ""),
        "coverArt": a.coverArt || "",
        "id": a.id || "",
        "year": a.year || 0
    }
}
