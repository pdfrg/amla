import "Catalog.js" as Catalog
import "Config.js" as Config
import "Dispatch.js" as Dispatch
import "History.js" as History
import "Md5.js" as Md5
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Wayland
import "Subsonic.js" as Subsonic
import qs.Commons
import qs.Ui

Item {
    // must-style insert-next: append one path, Dispatch moves
    // it after the current track (track.queue is cliamp's
    // play-next stack with return-to-position semantics).

    id: root

    // Injected by omarchy-shell when this plugin is summoned.
    property string omarchyPath: Quickshell.env("OMARCHY_PATH")
    property var shell: null
    property var manifest: null
    property bool opened: false
    property string filterText: ""
    property int selectedIndex: 0
    property var displayModel: []
    property string targetPlayer: "must"
    property var mustConfig: Config.mustConfig("", Quickshell.env("HOME") || "")
    readonly property string home: Quickshell.env("HOME") || ""
    readonly property int cardWidth: 680
    readonly property real rowHeight: Style.space(58)
    readonly property int maxRows: 14
    readonly property bool emptyQuery: filterText.length === 0
    // Popup chrome, mirroring the omarchy menu card.
    readonly property color background: Color.menu.background
    readonly property color scrim: Color.menu.scrim
    readonly property real cornerRadius: Style.cornerRadius
    readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
    readonly property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", Color.menu.selectedBorder, 0)
    // Card top freezes on the first search keystroke so the card grows
    // downward instead of re-centering on every resize (menu pattern).
    property int cardTop: -1
    readonly property int centeredTop: Math.max(Style.gapsOut, Math.round((panel.height - card.height) / 2))
    readonly property int effectiveCardTop: cardTop >= 0 ? cardTop : centeredTop
    // ----- catalog state (see Catalog.js) -----
    property var facetGenres: []
    property var facetYears: []
    property var listing: ({
        "temp": [],
        "playlists": []
    })
    property var searchRows: []
    property string searchedQuery: ""
    property var subRows: []
    property string subSearchedQuery: ""
    property var subGenres: []
    property var subYears: []
    // ----- play history (MPRIS watcher + dispatch recording) -----
    property string lastRecordedKey: ""
    property double lastRecordedMs: 0
    // Stability gate: a key must survive two consecutive polls before it
    // counts. Players update title/artist/album non-atomically on track
    // change, and a 3 s poll can snapshot the mixed transitional state.
    property string mprisPendingKey: ""
    readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
    readonly property var mprisActive: {
        var best = null;
        var list = mprisPlayers;
        for (var i = 0; i < list.length; i++) {
            var p = list[i];
            if (!p || p.playbackState !== MprisPlaybackState.Playing)
                continue;

            if (best === null)
                best = p;

        }
        return best;
    }
    readonly property var sub: mustConfig.subsonic
    readonly property bool subEnabled: sub.enabled && sub.url.length > 0 && sub.password.length > 0
    property int searchSerial: 0
    property bool searchDirty: false
    readonly property string mustDb: home + "/.cache/must/library.db"
    readonly property string playlistDir: home + "/.cache/must/playlists"
    readonly property string artCacheDir: home + "/.cache/amla/art"
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ("/run/user/" + home.split("/").pop())
    property string pluginMustBin: ""
    property var artMap: ({
    })
    readonly property string buildId: "0.5.0227"
    property string pendingSubAction: ""
    property bool randomFallbackLocal: false
    property var pendingSubRow: null

    function open(_payloadJson) {
        root.cardTop = -1;
        root.filterText = "";
        root.opened = true;
        root.selectedIndex = 0;
        refreshListings();
        refreshFacets();
    }

    // IPC freshness probe: omarchy-shell shell call mds.amla buildInfo ""
    function buildInfo() {
        return root.buildId;
    }

    function toggleTargetPlayer() {
        root.targetPlayer = root.targetPlayer === "must" ? "cliamp" : "must";
        pluginConfigFile.setText(Config.serializePluginConfig({
            "targetPlayer": root.targetPlayer,
            "mustBin": root.pluginMustBin
        }));
    }

    function close() {
        root.cancel();
    }

    function cancel() {
        root.opened = false;
    }

    function ping() {
        return "ok";
    }

    function select(delta) {
        if (root.displayModel.length === 0)
            return ;

        var next = root.selectedIndex + delta;
        root.selectedIndex = Math.max(0, Math.min(root.displayModel.length - 1, next));
    }

    // ----- result building -----
    function freezeCardTop() {
        if (panel.visible && cardTop < 0 && root.filterText.length > 0)
            cardTop = effectiveCardTop;

    }

    // ----- result building -----
    function scoredRows(rows, query) {
        var out = [];
        var favs = History.favoriteIndex();
        for (var i = 0; i < rows.length; i++) {
            var key = History.rowKey(rows[i]);
            var score = 0;
            if (favs[key] !== undefined) {
                score = History.scoreOf(favs[key]) * 1000;
                rows[i].star = true;
            }
            out.push({
                "row": rows[i],
                "favScore": score,
                "order": i
            });
        }
        return out;
    }

    function rebuildDisplay() {
        var q = root.filterText;
        var rows = [];
        if (q.length === 0) {
            rows = History.emptyStateRows(root.mustConfig, root.listing);
        } else {
            rows = Catalog.facetRows(root.facetGenres, root.facetYears, q);
            var cached = Catalog.listingRows(root.listing, q);
            rows = rows.concat(cached);
            if (root.subEnabled) {
                var subFacets = Catalog.facetRows(root.subGenres, root.subYears, q);
                for (var sfi = 0; sfi < subFacets.length; sfi++) {
                    subFacets[sfi].kind = "subsonic-" + subFacets[sfi].kind;
                    subFacets[sfi].badge = root.sub.serverBadge;
                }
                rows = rows.concat(subFacets);
            }
            if (root.searchedQuery === q) {
                var locals = Catalog.localDbRows(root.searchRows);
                rows = locals.concat(rows);
            }
            if (root.subSearchedQuery === q)
                rows = rows.concat(root.subRows);

        }
        root.displayModel = Catalog.mergeRanked(scoredRows(rows, q), 60);
        artSchedule.restart();
    }

    // ----- artwork (plan step 6) -----
    function artFor(row) {
        if (row.kind.indexOf("subsonic-") === 0) {
            var cache = Catalog.subArtCacheFile(Catalog.subArtId(row), root.artCacheDir);
            return artMap[cache] || "";
        }
        var dirs = Catalog.artDirsFor(row);
        for (var di = 0; di < dirs.length; di++) {
            if (artMap[dirs[di]])
                return artMap[dirs[di]];

        }
        return "";
    }

    function artJobs() {
        var seen = {
        };
        var jobs = [];
        for (var i = 0; i < root.displayModel.length; i++) {
            var row = root.displayModel[i];
            var job = null;
            if (row.kind.indexOf("subsonic-") === 0) {
                var cache = Catalog.subArtCacheFile(Catalog.subArtId(row), root.artCacheDir);
                if (cache.length > 0 && root.subEnabled) {
                    var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
                    job = {
                        "dir": Catalog.artDirFor(row) || cache,
                        "out": cache,
                        "url": Subsonic.coverArtUrl(root.sub.url, auth, Catalog.subArtId(row), 96)
                    };
                }
            } else {
                var dirs = Catalog.artDirsFor(row);
                for (var dji = 0; dji < dirs.length; dji++) {
                    var dkey = dirs[dji] + "|";
                    if (!seen[dkey]) {
                        seen[dkey] = true;
                        jobs.push({
                            "dir": dirs[dji],
                            "out": ""
                        });
                    }
                }
            }
            if (job && !seen[job.dir + "|" + job.out]) {
                seen[job.dir + "|" + job.out] = true;
                jobs.push(job);
            }
        }
        return jobs;
    }

    function requestSearch() {
        var q = root.filterText;
        var sql = Catalog.localSearchSql(q);
        if (sql.length === 0) {
            root.searchRows = [];
            root.searchedQuery = "";
            rebuildDisplay();
            return ;
        }
        if (searchProc.running) {
            root.searchDirty = true;
            return ;
        }
        searchProc.query = q;
        searchProc.command = ["sqlite3", "-json", root.mustDb, sql];
        searchProc.running = true;
        if (root.subEnabled) {
            subSearchProc.query = q;
            subSearchProc.auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
            subSearchProc.command = ["curl", "-s", "--max-time", "5", Subsonic.search3Url(root.sub.url, subSearchProc.auth, q)];
            subSearchProc.running = true;
        }
    }

    function activate(index, action) {
        if (index < 0 || index >= root.displayModel.length)
            return ;

        var row = root.displayModel[index];
        if (row.kind === "action" && String(row.action || "").indexOf("random-album") === 0)
            action = row.action;

        if (!action)
            action = "play";

        dispatch(row, action);
        // play / play-next / random dismiss the popup; enqueue stays open
        // for queueing more without re-summoning.
        if (action !== "enqueue")
            root.cancel();

    }

    // Uniform source pick for combined random (mirrors must's random).
    function pickRandomSource() {
        var cands = ["local"];
        if (((root.listing && root.listing.temp) || []).length > 0)
            cands.push("temp");

        if (root.subEnabled)
            cands.push("subsonic");

        return cands[Math.floor(Math.random() * cands.length)];
    }

    function playRandom(scope) {
        dispatch(null, scope && scope.length > 0 ? "random-album-" + scope : "random-album");
        root.cancel();
    }

    function historyFor(row) {
        if (!row)
            return null;

        switch (row.kind) {
        case "song":
        case "subsonic-song":
            return {
                "type": "song",
                "artist": row.artist || "",
                "album": row.album || "",
                "title": row.titleField || row.title,
                "display": row.title,
                "path": row.path || "",
                "coverArt": row.coverArt || "",
                "subId": row.id || ""
            };
        case "album":
        case "subsonic-album":
            return {
                "type": "album",
                "artist": row.artist || "",
                "album": row.album || row.title,
                "title": "",
                "display": row.title,
                "path": row.albumPath || "",
                "coverArt": row.coverArt || "",
                "subId": row.id || ""
            };
        case "artist":
        case "subsonic-artist":
            return {
                "type": "artist",
                "artist": "",
                "album": "",
                "title": row.title,
                "display": row.title,
                "path": row.path || "",
                "coverArt": row.coverArt || "",
                "subId": row.id || ""
            };
        case "genre":
        case "subsonic-genre":
            return {
                "type": "genre",
                "artist": "",
                "album": "",
                "title": row.title,
                "display": row.title
            };
        case "year":
        case "decade":
        case "subsonic-year":
        case "subsonic-decade":
            return {
                "type": "year",
                "artist": "",
                "album": "",
                "title": row.title,
                "display": row.title
            };
        case "temp":
            return {
                "type": "temp",
                "artist": "",
                "album": "",
                "title": row.title,
                "display": row.title,
                "path": row.path || ""
            };
        case "playlist":
            return {
                "type": "playlist",
                "artist": "",
                "album": "",
                "title": row.title,
                "display": row.title,
                "path": row.path || ""
            };
        default:
            return null;
        }
    }

    function dispatch(row, action) {
        var target = root.targetPlayer;
        var ctx = {
            "mustBin": root.pluginMustBin,
            "query": root.filterText
        };
        if (target === "cliamp" && String(action || "").indexOf("random-album") === 0) {
            // Combined mirrors must's server-side `random`: a uniform pick
            // among the available sources per invocation (not a fixed
            // subsonic preference; temp joins the pool when listed).
            var scope = action === "random-album" ? root.pickRandomSource() : action.substring("random-album-".length);
            if (scope === "subsonic" && root.subEnabled) {
                var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
                pendingSubAction = "play";
                pendingSubRow = null;
                root.randomFallbackLocal = action === "random-album";
                subRandomProc.command = ["curl", "-s", "--max-time", "5", Subsonic.randomAlbumUrl(root.sub.url, auth)];
                subRandomProc.running = true;
                root.cancel();
                return ;
            }
            if (action === "random-album-temp") {
                var temps = (root.listing && root.listing.temp) || [];
                if (temps.length === 0)
                    return ;

                var dir = temps[Math.floor(Math.random() * temps.length)];
                var pseudoTemp = {
                    "kind": "temp",
                    "title": Catalog.basename(dir),
                    "path": dir
                };
                root.runCliamp(pseudoTemp, "play", {
                    "op": "url.load",
                    "params": {
                        "path": dir,
                        "play": true
                    },
                    "clearFirst": true,
                    "launchTarget": dir
                });
                root.cancel();
                return ;
            }
            randomAlbumProc.command = ["sh", "-c", "sqlite3 -json '" + root.mustDb + "' \"SELECT path FROM tracks WHERE path != '' ORDER BY RANDOM() LIMIT 1\""];
            randomAlbumProc.running = true;
            root.cancel();
            return ;
        }
        if (target === "cliamp" && row) {
            if (row.kind.indexOf("subsonic-") === 0) {
                // cliamp v2 has a native navidrome provider, but the launcher
                // owns the REST queries — route everything through stream
                // URLs (song direct; album/artist via REST procs → m3u →
                // url.load).
                if (row.kind !== "subsonic-song") {
                    dispatchSubsonicCliamp(row, action);
                    return ;
                }
                var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
                var su = Subsonic.streamUrl(root.sub.url, auth, row.id);
                runCliamp(row, action, {
                    "op": "url.load",
                    "params": {
                        "path": su,
                        "play": action === "play"
                    },
                    "clearFirst": action === "play",
                    "insertNext": action === "enqueue-next",
                    "launchTarget": su
                });
                return ;
            }
            if (row.kind === "song") {
                var tr = {
                    "path": row.path,
                    "title": row.titleField || row.title,
                    "artist": row.artist || "",
                    "album": row.album || ""
                };
                if (action === "play" || action === "playshuffle")
                    runCliamp(row, action, {
                    "op": "track.play",
                    "params": {
                        "track": tr
                    },
                    "clearFirst": true,
                    "launchTarget": row.path
                });
                else if (action === "enqueue-next")
                    runCliamp(row, action, {
                    "op": "track.queue",
                    "params": {
                        "track": tr
                    },
                    "insertNext": true
                });
                else
                    runCliamp(row, action, {
                    "op": "queue",
                    "params": {
                        "path": row.path
                    }
                });
                return ;
            }
            if (row.kind === "playlist") {
                // url.load resolves the m3u (relative paths from its dir).
                runCliamp(row, action, {
                    "op": "url.load",
                    "params": {
                        "path": row.path,
                        "play": action === "play"
                    },
                    "clearFirst": action === "play",
                    "insertNext": action === "enqueue-next",
                    "launchTarget": row.path
                });
                return ;
            }
            if (row.kind === "temp") {
                runCliamp(row, action, {
                    "op": "url.load",
                    "params": {
                        "path": row.path,
                        "play": action === "play"
                    },
                    "clearFirst": action === "play",
                    "insertNext": action === "enqueue-next",
                    "launchTarget": row.path
                });
                return ;
            }
            if (row.kind === "album" || row.kind === "artist" || row.kind === "genre" || row.kind === "year" || row.kind === "decade") {
                // cliamp has no library search — resolve an m3u body via must's DB.
                pendingSubAction = action;
                pendingSubRow = row;
                cliampResolveProc.environment = {
                    "AMLA_DB": root.mustDb,
                    "AMLA_SQL": Catalog.pathsForKindM3uSql(row.kind, row)
                };
                cliampResolveProc.command = ["sh", "-c", "mkdir -p \"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/amla\" && sqlite3 -readonly \"$AMLA_DB\" \"$AMLA_SQL\" > \"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/amla/queue.m3u\" && wc -l < \"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/amla/queue.m3u\""];
                cliampResolveProc.running = true;
                return ;
            }
            return ;
        }
        dispatchProc.script = Dispatch.build(action, row, target, ctx);
        dispatchProc.hist = historyFor(row);
        dispatchProc.command = ["sh", "-c", dispatchProc.script];
        dispatchProc.running = true;
    }

    // Generic cliamp v2 dispatch: one remote call; op name and params JSON
    // passed via env (nothing is shell-quoted). m3uBody (optional) is written
    // to $XDG_RUNTIME_DIR/amla/queue.m3u before the call.
    function runCliamp(row, action, ctx) {
        // Alt+Enter playshuffle: same clear-first load as play, then the
        // script switches shuffle explicitly on (ctx.shuffleAfter).
        if (action === "playshuffle") {
            action = "play";
            if (!ctx.params)
                ctx.params = {
            };

            ctx.params.play = true;
            ctx.clearFirst = true;
            ctx.shuffleAfter = true;
        }
        dispatchProc.hist = historyFor(row);
        dispatchProc.script = Dispatch.build(action, row, "cliamp", ctx);
        dispatchProc.environment = {
            "AMLA_OP": String(ctx.op || ""),
            "AMLA_PARAMS": JSON.stringify(ctx.params || {
            }),
            "AMLA_M3U": String(ctx.m3uBody || "")
        };
        dispatchProc.command = ["sh", "-c", dispatchProc.script];
        dispatchProc.running = true;
    }

    // Track children → stream-URL m3u dispatch (shared by all subsonic →
    // cliamp multi-track completions). fallbackAction preserves each
    // caller's historical default (album: enqueue, artist: play).
    function subTracksToM3u(tracks) {
        var urls = [];
        var body = "#EXTM3U\n";
        for (var i = 0; i < tracks.length; i++) {
            var t = tracks[i];
            var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
            var u = Subsonic.streamUrl(root.sub.url, auth, t.id);
            urls.push(u);
            body += "#EXTINF:-1," + (t.artist || "") + " - " + (t.title || "") + "\n" + u + "\n";
        }
        return {
            "body": body,
            "firstUrl": urls.length > 0 ? urls[0] : ""
        };
    }

    function runSubM3u(tracks, fallbackAction) {
        var m = root.subTracksToM3u(tracks);
        if (m.firstUrl.length === 0)
            return ;

        var action = root.pendingSubAction || fallbackAction;
        root.runCliamp(root.pendingSubRow, action, {
            "op": "url.load",
            "params": {
                "path": Quickshell.env("XDG_RUNTIME_DIR") + "/amla/queue.m3u",
                "play": action === "play"
            },
            "clearFirst": action === "play",
            "insertNext": action === "enqueue-next",
            "m3uBody": m.body,
            "launchTarget": m.firstUrl
        });
    }

    // cliamp + subsonic album/artist: REST → track list → stream URLs.
    function dispatchSubsonicCliamp(row, action) {
        var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
        pendingSubAction = action;
        pendingSubRow = row;
        if (row.kind === "subsonic-artist") {
            subArtistProc.command = ["curl", "-s", "--max-time", "5", Subsonic.apiUrl(root.sub.url, "search3", auth + "&query=" + encodeURIComponent(row.title) + "&artistCount=1&albumCount=0&songCount=30")];
            subArtistProc.running = true;
        } else if (row.kind === "subsonic-genre") {
            subGenreProc.command = ["curl", "-s", "--max-time", "10", Subsonic.songsByGenreUrl(root.sub.url, auth, row.title)];
            subGenreProc.running = true;
        } else if (row.kind === "subsonic-year" || row.kind === "subsonic-decade") {
            var fromYear = row.kind === "subsonic-decade" ? row.decade : (row.year || parseInt(row.title, 10) || 0);
            var toYear = row.kind === "subsonic-decade" ? row.decade + 9 : fromYear;
            subYearListProc.command = ["curl", "-s", "--max-time", "10", Subsonic.albumsByYearUrl(root.sub.url, auth, fromYear, toYear)];
            subYearListProc.running = true;
        } else {
            subAlbumProc.command = ["curl", "-s", "--max-time", "5", Subsonic.apiUrl(root.sub.url, "getAlbum", auth + "&id=" + encodeURIComponent(row.id))];
            subAlbumProc.running = true;
        }
    }

    // One indexed lookup per new MPRIS track: backfill the file path the
    // player never reports, so artwork (and future lookups) resolve.
    // Normalized title (Artist-prefix stripped) matches recordPlay's key.
    function resolveMprisPath(key, artist, album, title) {
        if (mprisPathProc.running)
            return ;

        mprisPathProc.lookupKey = key;
        mprisPathProc.environment = {
            "AMLA_DB": root.mustDb,
            "AMLA_SQL": Catalog.trackPathSql(artist, album, History.stripArtistPrefix(artist, title))
        };
        mprisPathProc.command = ["sh", "-c", "sqlite3 -readonly \"$AMLA_DB\" \"$AMLA_SQL\""];
        mprisPathProc.running = true;
    }

    // Match path-less history items to temp album dirs (client-side, over
    // the cached listing) so their art resolves; persists artDir on hits.
    function matchTempArtDirs() {
        var temps = (root.listing && root.listing.temp) || [];
        if (temps.length === 0)
            return ;

        if (History.matchTempDirs(temps) > 0) {
            historyFile.setText(History.serialize());
            rebuildDisplay();
        }
    }

    // One batched lookup resolving file paths for history items that lack
    // them (MPRIS records, older entries) so song/album art can resolve.
    // Subsonic-origin items are skipped (History.itemsMissingPaths): their
    // art comes from the cover cache, and a local path would change dispatch.
    // Server backfill: identify origin-less leftovers (usually subsonic
    // tracks must played directly, which MPRIS records without an origin)
    // so their covers resolve. One search3 per item, 5 per run; strict
    // exact-title matching, leftovers retry on the next open/record.
    function pumpSubBackfill() {
        if (!root.subEnabled || subBackfillProc.running)
            return ;

        if (!subBackfillProc.queue || subBackfillProc.queue.length === 0) {
            // Unidentified favorites first (no cover at all), then songs
            // already identified but still pointing at per-song artwork.
            var missing = History.itemsMissingPaths(40).concat(History.itemsMissingAlbumId(40));
            if (missing.length === 0)
                return ;

            var q = [];
            for (var i = 0; i < missing.length && q.length < 5; i++) {
                var m = missing[i];
                q.push({
                    "key": m.key,
                    "stype": m.type,
                    "artist": m.artist,
                    "album": m.album,
                    "title": m.title,
                    "norm": History.normKey(m.type === "album" ? m.album : m.title)
                });
            }
            if (q.length === 0)
                return ;

            subBackfillProc.queue = q;
        }
        var next = subBackfillProc.queue.shift();
        var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
        subBackfillProc.current = next;
        var url = next.stype === "album" ? Subsonic.backfillAlbumUrl(root.sub.url, auth, next.artist, next.album) : Subsonic.backfillSongUrl(root.sub.url, auth, next.artist, next.title);
        subBackfillProc.command = ["curl", "-s", "--max-time", "5", url];
        subBackfillProc.running = true;
    }

    function backfillHistoryPaths() {
        if (backfillPathsProc.running)
            return ;

        root.matchTempArtDirs();
        var missing = History.itemsMissingPaths(40);
        if (missing.length === 0) {
            root.pumpSubBackfill();
            return ;
        }
        backfillPathsProc.command = ["sqlite3", "-json", "-readonly", root.mustDb, Catalog.backfillPathsSql(missing)];
        backfillPathsProc.running = true;
    }

    function refreshListings() {
        listingProc.command = ["sh", "-c", Catalog.listingCommand(root.mustConfig.tempDirs, root.playlistDir)];
        listingProc.running = true;
    }

    function refreshFacets() {
        facetProc.command = ["sqlite3", "-json", root.mustDb, Catalog.facetSql()];
        facetProc.running = true;
        if (root.subEnabled) {
            var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
            subFacetProc.command = ["sh", "-c", "curl -s --max-time 5 '" + Subsonic.genresUrl(root.sub.url, auth) + "'; echo ---AMLASPLIT---; curl -s --max-time 10 '" + Subsonic.byYearUrl(root.sub.url, auth) + "'"];
            subFacetProc.running = true;
        }
    }

    function refresh() {
        refreshCatalog();
        return "ok";
    }

    function refreshCatalog() {
        refreshListings();
        refreshFacets();
        artMap = ({
        });
        flushArtProc.command = ["sh", "-c", "rm -rf " + Catalog.shq(root.artCacheDir) + "; mkdir -p " + Catalog.shq(root.artCacheDir)];
        flushArtProc.running = true;
        rescanProc.command = ["sh", "-c", Dispatch.mustBinScript(root.pluginMustBin) + "\nif " + Dispatch.mustRunningExpr() + "; then \"$BIN\" rescan; fi"];
        rescanProc.running = true;
    }

    function enqueueRandom() {
        var songs = [];
        for (var i = 0; i < root.displayModel.length; i++) {
            var k = root.displayModel[i].kind;
            if (k === "song" || k === "subsonic-song")
                songs.push(root.displayModel[i]);

        }
        if (songs.length === 0)
            return ;

        var row = songs[Math.floor(Math.random() * songs.length)];
        dispatch(row, "enqueue");
    }

    function recordMprisPlay() {
        var p = root.mprisActive;
        if (!p)
            return ;

        var title = String(p.trackTitle || "").trim();
        var artist = String(p.trackArtist || "").trim();
        var album = String(p.trackAlbum || "").trim();
        if (title.length === 0 || artist.length === 0)
            return ;

        var key = History.keyFor("song", artist, album, title);
        if (key !== root.mprisPendingKey) {
            root.mprisPendingKey = key;
            root.resolveMprisPath(key, artist, album, title);
            return ;
        }
        var now = Date.now();
        if (key === root.lastRecordedKey && now - root.lastRecordedMs < 15000)
            return ;

        root.lastRecordedKey = key;
        root.lastRecordedMs = now;
        History.recordPlay("song", artist, album, title, title, "");
        historyFile.setText(History.serialize());
        root.backfillHistoryPaths();
    }

    onFilterTextChanged: searchDebounce.restart()
    onDisplayModelChanged: root.selectedIndex = 0
    Component.onCompleted: rebuildDisplay()

    Process {
        id: randomAlbumProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var rows = [];
                try {
                    rows = JSON.parse(String(text || "[]"));
                } catch (e) {
                    return ;
                }
                if (!rows.length || !rows[0].path)
                    return ;

                var dir = Catalog.parentDir(String(rows[0].path));
                if (!dir || dir.length === 0)
                    return ;

                var pseudoRow = {
                    "kind": "temp",
                    "title": Catalog.basename(dir),
                    "path": dir
                };
                root.runCliamp(pseudoRow, "play", {
                    "op": "url.load",
                    "params": {
                        "path": dir,
                        "play": true
                    },
                    "clearFirst": true,
                    "launchTarget": dir
                });
            }
        }

    }

    // Session-start pre-warm (plan step 10): keepLoaded mounts the plugin at
    // shell start; ~10 s later refresh listings/facets and the empty-screen
    // art so the first popup open skips all spawns and network waits.
    Timer {
        id: preWarmTimer

        interval: 10000
        running: true
        repeat: false
        onTriggered: {
            root.refreshListings();
            root.refreshFacets();
            root.rebuildDisplay();
            artSchedule.restart();
        }
    }

    Timer {
        id: mprisWatcher

        interval: 3000
        running: true
        repeat: true
        onTriggered: root.recordMprisPlay()
    }

    Timer {
        id: searchDebounce

        interval: 120
        onTriggered: {
            root.requestSearch();
            root.rebuildDisplay();
        }
    }

    Process {
        id: searchProc

        property string query: ""

        onExited: {
            if (root.searchDirty) {
                root.searchDirty = false;
                root.requestSearch();
            }
        }

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.searchRows = Catalog.parseSqliteJson(text);
                root.searchedQuery = searchProc.query;
                root.rebuildDisplay();
            }
        }

    }

    Process {
        id: listingProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.listing = Catalog.parseListing(text);
                root.matchTempArtDirs();
                root.rebuildDisplay();
            }
        }

    }

    Process {
        id: subSearchProc

        property string query: ""
        property string auth: ""

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var sub = Subsonic.getSubsonic(String(text || ""));
                root.subRows = Subsonic.searchRows(sub, root.sub.serverName, root.sub.serverBadge, subSearchProc.query);
                root.subSearchedQuery = subSearchProc.query;
                root.rebuildDisplay();
            }
        }

    }

    Process {
        id: subFacetProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var parts = String(text || "").split("---AMLASPLIT---");
                var g = Subsonic.getSubsonic(parts[0] || "");
                var y = Subsonic.getSubsonic(parts[1] || "");
                root.subGenres = Subsonic.genreFacets(g);
                root.subYears = Subsonic.yearFacets(y);
                root.rebuildDisplay();
            }
        }

    }

    Timer {
        id: artSchedule

        interval: 60
        onTriggered: {
            var jobs = root.artJobs();
            if (jobs.length === 0 || artProc.running)
                return ;

            artProc.command = ["sh", "-c", Catalog.artProbeCommand(jobs)];
            artProc.running = true;
        }
    }

    Process {
        id: artProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                console.log("[artdbg] art out: " + String(text || "").slice(0, 200));
                var found = Catalog.parseArtOutput(String(text || ""));
                var merged = {
                };
                for (var k in root.artMap) merged[k] = root.artMap[k]
                for (var k2 in found) merged[k2] = found[k2]
                root.artMap = merged;
            }
        }

    }

    Process {
        id: subRandomProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var sub = Subsonic.getSubsonic(String(text || ""));
                var alb = (sub && sub.albumList2 && sub.albumList2.album && sub.albumList2.album[0]) || null;
                if (!alb) {
                    // Combined pick hit an unreachable server: degrade to
                    // local (mirrors must trying the next source). Scoped
                    // subsonic requests stay silent — nothing else applies.
                    if (root.randomFallbackLocal) {
                        root.randomFallbackLocal = false;
                        randomAlbumProc.command = ["sh", "-c", "sqlite3 -json '" + root.mustDb + "' \"SELECT path FROM tracks WHERE path != '' ORDER BY RANDOM() LIMIT 1\""];
                        randomAlbumProc.running = true;
                    }
                    return ;
                }
                root.randomFallbackLocal = false;
                var pseudoRow = {
                    "kind": "subsonic-album",
                    "id": alb.id || "",
                    "album": alb.name || "",
                    "artist": alb.artist || "",
                    "title": alb.name || ""
                };
                root.dispatchSubsonicCliamp(pseudoRow, "play");
            }
        }

    }

    Process {
        id: subAlbumProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var sub = Subsonic.getSubsonic(String(text || ""));
                root.runSubM3u(Subsonic.albumSongs(sub), "enqueue");
            }
        }

    }

    Process {
        id: subGenreProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var sub = Subsonic.getSubsonic(String(text || ""));
                root.runSubM3u(Subsonic.genreSongs(sub), "enqueue");
            }
        }

    }

    // Year/decade expansion is two hops: album list first, then one getAlbum
    // per album (capped: a decade can span hundreds). Parts split on
    // ---AMLAYEAR--- and parse independently so one bad album skips cleanly.
    Process {
        id: subYearListProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var sub = Subsonic.getSubsonic(String(text || ""));
                var albums = Subsonic.yearAlbums(sub).slice(0, 40);
                if (albums.length === 0)
                    return ;

                var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
                var parts = [];
                for (var i = 0; i < albums.length; i++) parts.push("curl -s --max-time 10 '" + Subsonic.albumTracksUrl(root.sub.url, auth, albums[i].id) + "'; echo ---AMLAYEAR---")
                subYearExpandProc.command = ["sh", "-c", parts.join(" ")];
                subYearExpandProc.running = true;
            }
        }

    }

    Process {
        id: subYearExpandProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var tracks = [];
                var chunks = String(text || "").split("---AMLAYEAR---");
                for (var i = 0; i < chunks.length; i++) {
                    var sub = null;
                    try {
                        sub = Subsonic.getSubsonic(chunks[i]);
                    } catch (e) {
                        sub = null;
                    }
                    var songs = Subsonic.albumSongs(sub);
                    for (var j = 0; j < songs.length; j++) tracks.push(songs[j])
                }
                root.runSubM3u(tracks, "enqueue");
            }
        }

    }

    Process {
        id: subArtistProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var sub = Subsonic.getSubsonic(String(text || ""));
                var songs = (sub && sub.searchResult3 && sub.searchResult3.song) || [];
                root.runSubM3u(songs, "play");
            }
        }

    }

    // Backfills the file path for a confirmed MPRIS track (keyed exactly,
    // so a late result for a skipped track cannot corrupt the new one).
    Process {
        id: mprisPathProc

        property string lookupKey: ""

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                if (History.setPath(mprisPathProc.lookupKey, String(text || ""))) {
                    historyFile.setText(History.serialize());
                    rebuildDisplay();
                }
            }
        }

    }

    Process {
        id: subBackfillProc

        property var queue: []
        property var current: null

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var item = subBackfillProc.current;
                subBackfillProc.current = null;
                if (item) {
                    var sub = Subsonic.getSubsonic(String(text || ""));
                    var found = item.stype === "album" ? (sub && Subsonic.albumIdMatch(sub, item.norm)) : (sub && Subsonic.songIdMatch(sub, item.norm));
                    if (found && found.id) {
                        if (History.setSubId(item.key, found.id, found.coverArt, found.albumId)) {
                            historyFile.setText(History.serialize());
                            rebuildDisplay();
                        } else if (!found.albumId && History.markAlbumIdChecked(item.key)) {
                            historyFile.setText(History.serialize());
                        }
                    }
                }
                root.pumpSubBackfill();
            }
        }

    }

    Process {
        id: backfillPathsProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var rows = [];
                try {
                    rows = JSON.parse(String(text || "[]"));
                } catch (e) {
                    return ;
                }
                if (History.applyPathBackfill(rows) > 0) {
                    historyFile.setText(History.serialize());
                    rebuildDisplay();
                }
                root.pumpSubBackfill();
            }
        }

    }

    Process {
        id: cliampResolveProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var n = parseInt(String(text).trim() || "0");
                if (n <= 0)
                    return ;

                var action = root.pendingSubAction || "play";
                var m3u = Quickshell.env("XDG_RUNTIME_DIR") + "/amla/queue.m3u";
                root.runCliamp(root.pendingSubRow, action, {
                    "op": "url.load",
                    "params": {
                        "path": m3u,
                        "play": action === "play"
                    },
                    "clearFirst": action === "play",
                    "insertNext": action === "enqueue-next",
                    "launchTarget": m3u
                });
            }
        }

    }

    Process {
        id: dispatchProc

        property string script: ""
        property var hist: null

        onExited: function(exitCode) {
            if (exitCode !== 0 || !dispatchProc.hist)
                return ;

            var h = dispatchProc.hist;
            History.recordPlay(h.type, h.artist, h.album, h.title, h.display, h.path || "", {
                "coverArt": h.coverArt || "",
                "subId": h.subId || ""
            });
            historyFile.setText(History.serialize());
            rebuildDisplay();
        }

        stdout: StdioCollector {
            waitForEnd: true
        }

    }

    Process {
        id: flushArtProc

        stdout: StdioCollector {
            waitForEnd: true
        }

    }

    Process {
        id: rescanProc

        stdout: StdioCollector {
            waitForEnd: true
        }

    }

    Process {
        id: facetProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var all = Catalog.parseSqliteJson(text);
                root.facetGenres = all.filter(function(r) {
                    return r.g !== undefined;
                });
                root.facetYears = all.filter(function(r) {
                    return r.y !== undefined;
                });
                root.rebuildDisplay();
            }
        }

    }

    // amla's XDG dirs (config/state/cache) must exist before first write.
    Process {
        id: dirSetup

        command: ["sh", "-c", "mkdir -p ~/.config/amla ~/.local/state/amla ~/.cache/amla/art"]
        running: true
    }

    FileView {
        id: mustConfigFile

        path: root.home + "/.config/must/config.toml"
        watchChanges: true
        printErrors: false
        onLoaded: {
            root.mustConfig = Config.mustConfig(text(), root.home);
            refreshListings();
            // History may have loaded first while subEnabled was still
            // false — retry the server backfill now that creds exist.
            root.pumpSubBackfill();
        }
    }

    FileView {
        id: historyFile

        path: root.home + "/.local/state/amla/history.json"
        watchChanges: false
        printErrors: false
        onLoaded: {
            History.load(text());
            rebuildDisplay();
            backfillHistoryPaths();
        }
    }

    FileView {
        id: pluginConfigFile

        path: root.home + "/.config/amla/config.json"
        watchChanges: true
        printErrors: false
        onLoaded: {
            var pc = Config.parsePluginConfig(text());
            root.targetPlayer = pc.targetPlayer;
            root.pluginMustBin = pc.mustBin || "";
        }
    }

    PanelWindow {
        id: panel

        visible: root.opened
        color: "transparent"
        WlrLayershell.namespace: "omarchy-amla"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        Rectangle {
            anchors.fill: parent
            color: root.scrim
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.cancel()
        }

        BorderSurface {
            id: card

            width: root.cardWidth
            height: Math.min(content.implicitHeight + padding * 2, panel.height - 2 * Style.gapsOut)
            radius: root.cornerRadius
            anchors.horizontalCenter: parent.horizontalCenter
            y: root.effectiveCardTop
            color: root.background
            borderSpec: root.borderSpec
            padding: Style.space(12)

            MouseArea {
                anchors.fill: parent
                onClicked: function() {
                }
            }

            Column {
                id: content

                anchors.fill: parent
                anchors.margins: card.padding
                spacing: Style.space(8)

                Item {
                    id: keyCatcher

                    focus: true
                    Keys.priority: Keys.BeforeItem
                    Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Escape) {
                            if (root.filterText)
                                root.filterText = "";
                            else
                                root.cancel();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
                            root.select(-1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
                            root.select(1);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_PageUp) {
                            root.select(-6);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_PageDown) {
                            root.select(6);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Home && root.displayModel.length > 0) {
                            root.selectedIndex = 0;
                            event.accepted = true;
                        } else if (event.key === Qt.Key_End && root.displayModel.length > 0) {
                            root.selectedIndex = root.displayModel.length - 1;
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            if (event.modifiers & Qt.AltModifier) {
                                if (event.modifiers & Qt.ShiftModifier)
                                    root.enqueueRandom();
                                else
                                    root.activate(root.selectedIndex, "playshuffle");
                            } else if (event.modifiers & Qt.ControlModifier)
                                root.activate(root.selectedIndex, "enqueue-next");
                            else if (event.modifiers & Qt.ShiftModifier)
                                root.activate(root.selectedIndex, "enqueue");
                            else
                                root.activate(root.selectedIndex, "play");
                            event.accepted = true;
                        } else if (event.key === Qt.Key_R && (event.modifiers & Qt.AltModifier)) {
                            root.playRandom("");
                            event.accepted = true;
                        } else if ((event.key === Qt.Key_1 || event.key === Qt.Key_2 || event.key === Qt.Key_3) && (event.modifiers & Qt.AltModifier)) {
                            root.playRandom(event.key === Qt.Key_1 ? "local" : (event.key === Qt.Key_2 ? "subsonic" : "temp"));
                            event.accepted = true;
                        } else if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
                            root.refreshCatalog();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_T && (event.modifiers & Qt.ControlModifier)) {
                            root.toggleTargetPlayer();
                            event.accepted = true;
                        } else if ((event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) && root.filterText.length > 0) {
                            root.filterText = root.filterText.slice(0, -1);
                            event.accepted = true;
                        } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
                            root.filterText += event.text;
                            event.accepted = true;
                        }
                    }
                }

                // Filter line: prompt, typed query, target badge.
                Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Text {
                        text: ">"
                        color: Color.menu.selectedText
                        font.family: Style.font.menuFamily
                        font.pixelSize: Style.font.heading
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        id: filterDisplay

                        text: root.filterText.length > 0 ? root.filterText : "type to search"
                        color: root.filterText.length > 0 ? Color.menu.text : Color.muted
                        font.family: Style.font.menuFamily
                        font.pixelSize: Style.font.heading
                        font.italic: root.filterText.length === 0
                        elide: Text.ElideRight
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - parent.spacing * 2 - targetBadge.width - 60
                    }

                    Rectangle {
                        id: targetBadge

                        radius: Style.cornerRadius
                        color: Color.menu.selectedBackground
                        width: badgeLabel.implicitWidth + Style.space(12)
                        height: badgeLabel.implicitHeight + Style.space(4)
                        anchors.verticalCenter: parent.verticalCenter

                        Text {
                            id: badgeLabel

                            text: root.targetPlayer
                            color: Color.menu.selectedText
                            font.family: Style.font.family
                            font.pixelSize: Style.font.bodySmall
                            anchors.centerIn: parent
                        }

                    }

                }

                // Results.
                ListView {
                    id: resultList

                    width: parent.width
                    height: Math.min(root.maxRows * root.rowHeight, count * root.rowHeight)
                    clip: true
                    interactive: false
                    model: root.displayModel
                    currentIndex: root.selectedIndex
                    onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

                    delegate: BorderSurface {
                        required property var modelData
                        required property int index

                        width: resultList.width
                        height: root.rowHeight
                        radius: Style.cornerRadius
                        color: index === root.selectedIndex ? Color.menu.selectedBackground : (rowHover.hovered ? Style.hoverFillFor(Color.menu.text, Color.menu.selectedText, Color.urgent) : "transparent")
                        borderSpec: index === root.selectedIndex ? root.selectedBorderSpec : Border.none()

                        MouseArea {
                            id: rowHover

                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: {
                                root.selectedIndex = index;
                                root.freezeCardTop();
                            }
                            onDoubleClicked: root.activate(index)
                        }

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: Style.space(8)
                            anchors.rightMargin: Style.space(8)
                            spacing: Style.space(10)

                            // Thumbnail: album art from disk probe / subsonic cache.
                            Rectangle {
                                id: thumbBox

                                width: root.rowHeight - Style.space(10)
                                height: width
                                radius: Style.cornerRadius
                                color: Style.normalFillFor(Color.menu.text, Color.menu.selectedText)
                                anchors.verticalCenter: parent.verticalCenter
                                clip: true

                                Image {
                                    anchors.fill: parent
                                    asynchronous: true
                                    sourceSize.width: 80
                                    sourceSize.height: 80
                                    fillMode: Image.PreserveAspectCrop
                                    visible: root.artFor(modelData) !== ""
                                    source: root.artFor(modelData) === "" ? "" : "file://" + root.artFor(modelData)
                                }

                                Text {
                                    anchors.centerIn: parent
                                    text: modelData.kind === "artist" ? "\uf007" : "♪"
                                    color: Color.muted
                                    font.family: modelData.kind === "artist" ? "JetBrainsMono Nerd Font" : Style.font.menuFamily
                                    font.pixelSize: Style.font.icon
                                    visible: root.artFor(modelData) === ""
                                }

                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - parent.spacing * 3 - thumbBox.width - badgeText.implicitWidth - starText.implicitWidth
                                spacing: 0

                                Text {
                                    text: modelData.title
                                    color: index === root.selectedIndex ? Color.menu.selectedText : Color.menu.text
                                    font.family: Style.font.menuFamily
                                    font.pixelSize: Style.font.heading
                                    font.weight: Font.Medium
                                    elide: Text.ElideRight
                                    width: parent.width
                                }

                                Text {
                                    text: modelData.subtitle
                                    color: Color.menu.text
                                    opacity: 0.52
                                    font.family: Style.font.menuFamily
                                    font.pixelSize: Style.font.bodySmall
                                    elide: Text.ElideRight
                                    width: parent.width
                                    visible: modelData.subtitle.length > 0
                                }

                            }

                            Text {
                                id: starText

                                text: "★"
                                color: Color.menu.selectedText
                                font.pixelSize: Style.font.body
                                visible: modelData.star === true
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Text {
                                id: badgeText

                                text: modelData.badge
                                color: Color.muted
                                font.family: Style.font.family
                                font.pixelSize: Style.font.bodySmall
                                visible: modelData.badge.length > 0
                                anchors.verticalCenter: parent.verticalCenter
                            }

                        }

                    }

                }

                Text {
                    text: root.displayModel.length === 0 && !root.emptyQuery ? "no results" : ""
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    visible: text.length > 0
                }

                // Hint bar.
                Rectangle {
                    width: parent.width
                    height: 1
                    color: Qt.alpha(Color.menu.text, 0.15)
                    visible: root.displayModel.length > 0
                }

                Text {
                    text: "enter: play   shift+enter: enqueue   ctrl+enter: play next   alt+r: random   alt+1/2/3: local/subsonic/temp   ctrl+t: player"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                    width: parent.width
                    visible: root.displayModel.length > 0
                }

            }

        }

    }

}
