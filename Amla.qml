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
    // cliamp-native track resolution (provider.album_tracks for an album id,
    // provider.search for an artist name). Results carry cliamp-minted authed
    // stream URLs with metadata + provider_meta, so they feed the standard
    // url.load m3u dispatch with working enqueue-next id-matching. Genre /
    // year still use the REST procs (no provider op covers them).
    // The file is written before the running/not-running branch, so
    // a fresh TUI can launch directly on the full list (cliamp
    // resolves local m3u argv entries itself).
    // QML Process environment may not inherit the shell env
    // (cliamp needs HOME for config resolution, jq/id need no
    // PATH when invoked absolutely): pass through explicitly.

    id: root

    // Injected by omarchy-shell when this plugin is summoned.
    property string omarchyPath: Quickshell.env("OMARCHY_PATH")
    property var shell: null
    property var manifest: null
    property bool opened: false
    property string filterText: ""
    property int selectedIndex: 0
    property var displayModel: []
    property string targetPlayer: "cliamp"
    // Set by pluginConfigFile.onLoaded: until the real config.json has
    // been read, targetPlayer/pluginMustBin/amlaPluginCfg are defaults
    // and must NEVER be saved (a toggle in that window would persist
    // empty mustBin/musicDirs/tempDirs over the user's real settings).
    property bool pluginConfigLoaded: false
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
        "playlists": [],
        "library": []
    })
    // Effective library roots (§12), recomputed by refreshRoots() whenever
    // any config file loads. Sticky must-DB signal: library dir rows show
    // only while the DB is unreachable (file index / DB supersede them).
    property var libraryRoots: ({
        "musicDirs": [],
        "tempDirs": []
    })
    property var amlaPluginCfg: null
    property string cliampInitialDir: ""
    property bool mustDbOk: true
    property var searchRows: []
    property string searchedQuery: ""
    property var subRows: []
    property string subSearchedQuery: ""
    property var subGenres: []
    property var subYears: []
    property var subPlaylists: []
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
    // Effective subsonic creds: must's [subsonic] wins when enabled,
    // else cliamp's [navidrome] (present on every omarchy install).
    // Recomputed in both config loaders (either order); never written.
    property var sub: Config.mustConfig("", "").subsonic
    property var cliampNav: null
    readonly property bool subEnabled: sub.enabled && sub.url.length > 0 && sub.password.length > 0
    property int searchSerial: 0
    property bool searchDirty: false
    readonly property string filesDb: home + "/.cache/amla/files.db"
    readonly property string mustDb: home + "/.cache/must/library.db"
    readonly property string playlistDir: (Quickshell.env("XDG_CACHE_HOME") || home + "/.cache") + "/must/playlists"
    // cliamp playlist dir mirrors cliamp's own resolution
    // (docs/playlists.md): CLIAMP_CONFIG_DIR, then
    // XDG_CONFIG_HOME/cliamp, then ~/.config/cliamp.
    readonly property string cliampPlaylistDir: (Quickshell.env("CLIAMP_CONFIG_DIR") || ((Quickshell.env("XDG_CONFIG_HOME") || home + "/.config") + "/cliamp")) + "/playlists"
    readonly property string artCacheDir: home + "/.cache/amla/art"
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ("/run/user/" + home.split("/").pop())
    property string pluginMustBin: ""
    property var artMap: ({
    })
    readonly property string buildId: "0.5.2060"
    property string pendingSubAction: ""
    property string pendingSubTarget: ""
    // `must --version` output ("" = unknown): capability gating for the
    // native server-playlist resolver (must >= v0.2.4, or dev builds).
    property string mustVersion: ""
    // MPD liveness (§18): -1 unknown (probe unanswered), 0 down, 1 up.
    property int mpdAlive: -1
    // MPD dispatch staging (§18 phase 2): resolve procs and the queue
    // FileView share one pending row/action across async hops.
    property var pendingMpdRow: null
    property string pendingMpdAction: ""
    property bool pendingMpdRandom: false
    // Session upgrade nudge: fired once when falling back on a
    // positively-old must (never for unknown versions, never twice).
    property bool mustNudged: false
    // toml playlist synthesis (§15a): cliamp `playlist show --json` → m3u
    // for must-target plays/enqueues and cliamp-target enqueues (cliamp
    // play uses the native `load` op instead). Set by resolvePlaylistBody,
    // consumed by completePlaylistBody.
    property var pendingPlaylistRow: null
    property string pendingPlaylistAction: ""
    property string pendingPlaylistTarget: ""
    property string pendingPlaylistMode: ""
    property bool randomFallbackLocal: false
    property var pendingSubRow: null
    // Cold subsonic-album play retry (P3): set by dispatchSubsonicCliamp
    // alongside the provider.load_album dispatch; dispatchProc.onExited
    // consumes it — success clears, failure refires via REST getAlbum.
    property var pendingFallbackAlbum: null
    // Batched year/decade expansion state (P1-2nd-pass): remaining album
    // ids + accumulated minimal track objects across proc runs.
    property var yearQueue: []
    property var yearTracks: []
    // Fire-and-forget file-index build (§13): the script upserts by mtime,
    // so repeats are cheap after the cold scan. No timeout — a huge cold
    // build may run minutes; queries keep serving stale rows meanwhile.
    // Auto-triggers (facet/search failures) are rate-limited so overlapping
    // failure events can't stack cold scans; manual refresh forces.
    property double lastIndexBuildMs: 0

    // File-index mode (no must DB, or the debugNoMust simulation): local
    // playback resolves against filesDb.files instead of mustDb.tracks.
    function useFilesIndex() {
        return !root.mustDbOk || root.debugNoMust();
    }

    function localDbPath() {
        return root.useFilesIndex() ? root.filesDb : root.mustDb;
    }

    function localDbTable() {
        return root.useFilesIndex() ? "files" : "tracks";
    }

    function open(_payloadJson) {
        root.cardTop = -1;
        root.filterText = "";
        root.opened = true;
        root.selectedIndex = 0;
        refreshRoots();
        refreshFacets();
        root.probeMustVersion();
        root.probeMpd();
    }

    // IPC freshness probe: omarchy-shell shell call io.github.pdfrg.amla buildInfo ""
    function buildInfo() {
        return root.buildId;
    }

    // Target badge: base name plus state suffixes (no-must simulation,
    // MPD daemon down). mpdAlive -1 (probe unanswered) shows no suffix.
    function targetBadgeText() {
        var t = root.targetPlayer;
        if (root.debugNoMust())
            t += " · no-must";

        if (t === "mpd" && root.mpdAlive === 0)
            t += " · down";

        return t;
    }

    function toggleTargetPlayer() {
        if (!root.pluginConfigLoaded)
            return ;

        // Three-way cycle (cliamp → must → mpd → cliamp): the cliamp→must
        // first step preserves the old two-way muscle memory.
        if (root.targetPlayer === "cliamp")
            root.targetPlayer = "must";
        else if (root.targetPlayer === "must")
            root.targetPlayer = "mpd";
        else
            root.targetPlayer = "cliamp";
        // Dirty keys only (partial object): the merge overlays these
        // onto a fresh disk read, so stale in-memory values for the
        // other owned keys (mustBin, dirs) can never wipe real settings.
        configSaveProc.pending = JSON.stringify({
            "targetPlayer": root.targetPlayer
        });
        configSaveProc.command = ["/bin/cat", root.home + "/.config/amla/config.json"];
        configSaveProc.running = true;
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
            var cached = Catalog.listingRows(root.listing, q, (root.amlaPluginCfg && root.amlaPluginCfg.noiseTokens) || []);
            rows = rows.concat(cached);
            if (root.subEnabled) {
                var subFacets = Catalog.facetRows(root.subGenres, root.subYears, q);
                for (var sfi = 0; sfi < subFacets.length; sfi++) {
                    subFacets[sfi].kind = "subsonic-" + subFacets[sfi].kind;
                    subFacets[sfi].badge = root.sub.serverBadge;
                    // Silent-cap hint: genre plays cap at 500 songs, year /
                    // decade expansion at 100 albums — say so up front.
                    if (subFacets[sfi].kind === "subsonic-genre")
                        subFacets[sfi].subtitle += " · up to 500 songs";
                    else if (subFacets[sfi].kind === "subsonic-year" || subFacets[sfi].kind === "subsonic-decade")
                        subFacets[sfi].subtitle += " · first 100 albums";
                }
                rows = rows.concat(subFacets);
                rows = rows.concat(Subsonic.playlistRows(root.subPlaylists, root.sub.serverBadge, q));
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
        var useFiles = !root.mustDbOk || root.debugNoMust();
        var sql = useFiles ? Catalog.filesSearchSql(q) : Catalog.localSearchSql(q);
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
        searchProc.dbUsed = useFiles ? "files" : "must";
        searchProc.command = ["/usr/bin/timeout", "--kill-after=5", "15", "/usr/bin/sqlite3", "-json", "-readonly", useFiles ? root.filesDb : root.mustDb, sql];
        searchProc.running = true;
        if (root.subEnabled) {
            subSearchProc.query = q;
            subSearchProc.auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
            subSearchProc.command = ["/usr/bin/curl", "-s", "--max-time", "5", Subsonic.search3Url(root.sub.url, subSearchProc.auth, q)];
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
                "subtitle": row.subtitle || "",
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
                "subtitle": row.subtitle || "",
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
                "subtitle": row.subtitle || "",
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
                "display": row.title,
                "subtitle": row.subtitle || ""
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
                "display": row.title,
                "subtitle": row.subtitle || ""
            };
        case "temp":
        case "library":
            return {
                "type": "temp",
                "artist": "",
                "album": "",
                "title": row.title,
                "display": row.title,
                "subtitle": row.subtitle || "",
                "path": row.path || ""
            };
        case "playlist":
        case "subsonic-playlist":
            return {
                "type": "playlist",
                "artist": "",
                "album": "",
                "title": row.title,
                "display": row.title,
                "subtitle": row.subtitle || "",
                "path": row.path || "",
                "subId": row.id || ""
            };
        default:
            return null;
        }
    }

    // Capability probe for must-gated features: one fork per popup
    // open, result cached in mustVersion ("dev" counts as new).
    function probeMustVersion() {
        if (mustVersionProc.running)
            return ;

        mustVersionProc.environment = {
            "PATH": "/usr/bin:/bin",
            "AMLA_MUSTBIN": String(root.pluginMustBin || "")
        };
        mustVersionProc.command = ["/usr/bin/sh", "-c", "B=\"$AMLA_MUSTBIN\"; [ -x \"$B\" ] || B=$(command -v must 2>/dev/null || true); if [ -n \"$B\" ]; then \"$B\" --version 2>/dev/null; fi"];
        mustVersionProc.running = true;
    }

    // MPD liveness probe (§18): one fork per popup open, cached in
    // mpdAlive. mpc reads MPD_HOST/MPD_PORT; empty plugin values fall
    // back to mpc's own localhost:6600.
    // Effective subsonic creds (§18): must > cliamp > amla-owned.
    // Recomputed in all three config loaders (any order). ${VAR}
    // expansion for amla-owned secrets mirrors the cliamp handling.
    function refreshSub() {
        var owned = Config.amlaSubsonic(root.amlaPluginCfg);
        for (var k in owned) {
            if (typeof owned[k] === "string")
                owned[k] = owned[k].replace(/\$\{([^}]+)\}/g, function(m, name) {
                return Quickshell.env(name) || m;
            });

        }
        root.sub = Config.pickSubsonic(root.mustConfig.subsonic, root.cliampNav, owned);
    }

    function probeMpd() {
        if (mpdProbeProc.running)
            return ;

        mpdProbeProc.environment = {
            "PATH": "/usr/bin:/bin",
            "AMLA_MPDHOST": String((root.amlaPluginCfg && root.amlaPluginCfg.mpdHost) || ""),
            "AMLA_MPDPORT": String((root.amlaPluginCfg && root.amlaPluginCfg.mpdPort) || "")
        };
        mpdProbeProc.command = ["/usr/bin/sh", "-c", "command -v mpc >/dev/null 2>&1 || exit 3; [ -n \"$AMLA_MPDHOST\" ] && export MPD_HOST=\"$AMLA_MPDHOST\"; [ -n \"$AMLA_MPDPORT\" ] && export MPD_PORT=\"$AMLA_MPDPORT\"; mpc status >/dev/null 2>&1"];
        mpdProbeProc.running = true;
    }

    function dispatch(row, action) {
        var target = root.targetPlayer;
        var ctx = {
            "mustBin": root.pluginMustBin,
            "query": root.filterText,
            "mpdHost": (root.amlaPluginCfg && root.amlaPluginCfg.mpdHost) || "",
            "mpdPort": (root.amlaPluginCfg && root.amlaPluginCfg.mpdPort) || 0
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
                subRandomProc.command = ["/usr/bin/curl", "-s", "--max-time", "5", Subsonic.randomAlbumUrl(root.sub.url, auth)];
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
            // Album-granular pick (GROUP BY album/artist): a random track's
            // parent dir can span multiple albums depending on library
            // layout, so resolve the exact album through the facet m3u flow.
            randomAlbumProc.command = ["/usr/bin/sh", "-c", "/usr/bin/timeout --kill-after=5 15 /usr/bin/sqlite3 -json -readonly '" + root.localDbPath() + "' \"SELECT album, COALESCE(NULLIF(album_artist,''), artist) AS a FROM " + root.localDbTable() + " WHERE album != '' GROUP BY album, a ORDER BY RANDOM() LIMIT 1\""];
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
                // Full supplied track (not a bare URL): stream URLs carry
                // no tags, so url.load shows the host as title and no
                // duration (cliamp, unlike rmpc, never refreshes stream
                // metadata at play time). duration_secs also clears the
                // realtime flag m3u/url loads set when duration <= 0.
                var meta = {
                };
                if (row.id && String(row.id).length > 0)
                    meta["navidrome.id"] = String(row.id);

                var str = {
                    "path": su,
                    "title": row.titleField || row.title,
                    "artist": row.artist || "",
                    "album": row.album || "",
                    "duration_secs": row.duration || 0,
                    "provider_meta": meta
                };
                if (action === "play" || action === "playshuffle") {
                    // Running: track.play carries split metadata. Cold: the
                    // TUI launches on a single-entry m3u (a bare stream URL
                    // shows the host as title) — prep writes it, same shape
                    // as runSubM3u.
                    var sm = root.subTracksToM3u([{
                        "id": row.id,
                        "artist": row.artist || "",
                        "album": row.album || "",
                        "title": row.titleField || row.title,
                        "duration": row.duration || 0
                    }]);
                    runCliamp(row, action, {
                        "op": "track.play",
                        "params": {
                            "track": str
                        },
                        "clearFirst": true,
                        "m3uBody": sm.body,
                        "launchTarget": Quickshell.env("XDG_RUNTIME_DIR") + "/amla/queue.m3u"
                    });
                } else if (action === "enqueue-next") {
                    runCliamp(row, action, {
                        "op": "track.queue",
                        "params": {
                            "track": str
                        },
                        "insertNext": true
                    });
                } else {
                    // No append-with-metadata op exists ("queue" takes a
                    // bare path, "queue.enqueue" takes an index), so
                    // append goes as a single-entry m3u with a real
                    // EXTINF duration (not -1, which flags realtime).
                    var eauth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
                    var ettl = Subsonic.m3uTitle(row.artist, row.album, row.titleField || row.title);
                    var eu = Subsonic.streamUrl(root.sub.url, eauth, row.id);
                    var em3u = Quickshell.env("XDG_RUNTIME_DIR") + "/amla/queue.m3u";
                    runCliamp(row, action, {
                        "op": "url.load",
                        "params": {
                            "path": em3u,
                            "play": false
                        },
                        "m3uBody": "#EXTM3U\n#EXTINF:" + (row.duration || 0) + "," + ettl + "\n" + eu + "\n"
                    });
                }
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
                if (row.source === "cliamp") {
                    // Native toml load: replaces the live playlist and
                    // starts it in one call (no m3u round-trip). Anything
                    // needing a body (enqueues, playshuffle pre-shuffle)
                    // synthesizes first.
                    if (action === "play") {
                        runCliamp(row, action, {
                            "op": "load",
                            "params": {
                                "playlist": row.title
                            },
                            "plName": row.title
                        });
                        return ;
                    }
                    root.resolvePlaylistBody(row, action);
                    return ;
                }
                if (action === "playshuffle") {
                    // Pre-shuffled body: cliamp's shuffle pins the loaded
                    // head at 0, so file order would fix track 1.
                    root.resolvePlaylistBody(row, action);
                    return ;
                }
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
            if (row.kind === "temp" || row.kind === "library") {
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
                    "PATH": "/usr/bin:/bin",
                    "AMLA_DB": root.localDbPath(),
                    "AMLA_FILESDB": root.filesDb,
                    "AMLA_SQL": Catalog.pathsForKindM3uSql(row.kind, row, action === "playshuffle", root.localDbTable()),
                    "AMLA_SQL_FILES": Catalog.pathsForKindM3uSql(row.kind, row, action === "playshuffle", "files")
                };
                cliampResolveProc.command = ["/usr/bin/sh", "-c", "/usr/bin/mkdir -p \"${XDG_RUNTIME_DIR:-/run/user/$(/usr/bin/id -u)}/amla\" && /usr/bin/timeout --kill-after=5 15 /usr/bin/sqlite3 -readonly \"$AMLA_DB\" \"$AMLA_SQL\" > \"${XDG_RUNTIME_DIR:-/run/user/$(/usr/bin/id -u)}/amla/queue.m3u\"; if [ ! -s \"${XDG_RUNTIME_DIR:-/run/user/$(/usr/bin/id -u)}/amla/queue.m3u\" ] && [ -n \"$AMLA_SQL_FILES\" ] && [ \"$AMLA_DB\" != \"$AMLA_FILESDB\" ]; then /usr/bin/timeout --kill-after=5 15 /usr/bin/sqlite3 -readonly \"$AMLA_FILESDB\" \"$AMLA_SQL_FILES\" > \"${XDG_RUNTIME_DIR:-/run/user/$(/usr/bin/id -u)}/amla/queue.m3u\"; fi; /usr/bin/wc -l < \"${XDG_RUNTIME_DIR:-/run/user/$(/usr/bin/id -u)}/amla/queue.m3u\""];
                cliampResolveProc.running = true;
                return ;
            }
            return ;
        }
        // MPD random-album actions carry no row (playRandom): route
        // before the row-gated branch, mirroring the cliamp shape.
        if (target === "mpd" && String(action || "").indexOf("random-album") === 0) {
            root.dispatchMpdRandom(action);
            return ;
        }
        if (target === "mpd" && row) {
            // Server rows (§18 phase 3): tagged stream URLs over pure
            // REST (no cliamp-daemon dependency).
            if (String(row.kind || "").indexOf("subsonic-") === 0) {
                if (!root.subEnabled) {
                    root.notify("amla: no subsonic server configured — add must [subsonic], cliamp [navidrome], or amla subsonicUrl/User/Pass");
                    return ;
                }
                if (row.kind === "subsonic-song" && row.id) {
                    // Direct: one stream URL + split tags, no REST hop.
                    root.pendingSubAction = action;
                    root.pendingSubRow = row;
                    root.pendingSubTarget = "";
                    root.runMpd(row, action, root.subTracksToMpd([{
                        "id": row.id,
                        "artist": row.artist || "",
                        "album": row.album || "",
                        "title": row.titleField || row.title,
                        "duration": row.duration || 0
                    }]));
                    return ;
                }
                root.pendingSubAction = action;
                root.pendingSubRow = row;
                root.pendingSubTarget = "mpd";
                root.dispatchSubsonicMpd(row, action);
                return ;
            }
            if (row.kind === "song") {
                if (!row.path)
                    return ;

                root.runMpd(row, action, [row.path]);
                return ;
            }
            if (row.kind === "temp" || row.kind === "library" || row.kind === "album" || row.kind === "artist" || row.kind === "genre" || row.kind === "year" || row.kind === "decade") {
                // Facet/dir rows resolve to absolute paths via the local
                // DB (single tier — localDbPath already picks files vs
                // must per useFilesIndex).
                root.pendingMpdAction = action;
                root.pendingMpdRow = row;
                var msql = (row.kind === "temp" || row.kind === "library") ? Catalog.pathsUnderDirSql(row.path, root.localDbTable()) : Catalog.pathsForKindSql(row.kind, row, root.localDbTable());
                mpdResolveProc.environment = {
                    "PATH": "/usr/bin:/bin",
                    "AMLA_DB": root.localDbPath(),
                    "AMLA_SQL": msql
                };
                mpdResolveProc.command = ["/usr/bin/sh", "-c", "/usr/bin/timeout --kill-after=5 15 /usr/bin/sqlite3 -readonly -noheader -list \"$AMLA_DB\" \"$AMLA_SQL\""];
                mpdResolveProc.running = true;
                return ;
            }
            if (row.kind === "playlist") {
                // resolvePlaylistBody writes $R/pl.m3u with dir-resolved
                // absolute paths; completePlaylistBody routes mpd on.
                root.resolvePlaylistBody(row, action);
                return ;
            }
            return ;
        }
        // Native path (must >= v0.2.4, or dev) falls through to
        // Dispatch.build, whose mustResolver emits
        // subsonic:playlist:'<id>'. Older/unknown must takes the
        // compatibility path: fetch the entries over REST and hand
        // must the staged stream-URL m3u by path.
        if (target === "must" && row && row.kind === "subsonic-playlist" && row.id && !Dispatch.mustHasPlaylistResolver(root.mustVersion)) {
            if (!root.mustNudged && Dispatch.mustVersionIsOld(root.mustVersion)) {
                root.mustNudged = true;
                root.notify("amla: server playlists via compatibility mode — upgrade must to v0.2.4+ for native support");
            }
            var compatAuth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
            pendingSubAction = action;
            pendingSubRow = row;
            pendingSubTarget = "must";
            subPlaylistProc.command = ["/usr/bin/curl", "-s", "--max-time", "15", Subsonic.playlistUrl(root.sub.url, compatAuth, row.id)];
            subPlaylistProc.running = true;
            return ;
        }
        if (target === "must" && row && row.kind === "playlist" && (row.source === "cliamp" || row.source === "stray")) {
            // must cannot read cliamp's toml format (and knows stray files only
            // by path, not by saved name): synthesize an m3u
            // first, then dispatch must play/enqueue on the file.
            root.resolvePlaylistBody(row, action);
            return ;
        }
        dispatchProc.script = Dispatch.build(action, row, target, ctx);
        dispatchProc.hist = historyFor(row);
        dispatchProc.command = ["/usr/bin/sh", "-c", dispatchProc.script];
        dispatchProc.running = true;
    }

    // Generic cliamp v2 dispatch: one remote call; op name and params JSON
    // passed via env (nothing is shell-quoted). m3uBody (optional) is written
    // to $XDG_RUNTIME_DIR/amla/queue.m3u before the call.
    // mpd_queue.py ships at plugin top level (same as index-library.py).
    function mpdHelperPath() {
        var u = String(Qt.resolvedUrl("mpd_queue.py"));
        if (u.indexOf("file://") === 0)
            u = u.substring(7);

        return u;
    }

    // Staged-dispatch dedup guard: FileView.setText with byte-identical
    // content skips onSaved, silently dropping re-dispatches (same album
    // re-added, same playshuffle material — only script flags differ).
    // A serial comment keeps every staging unique; "#" lines are m3u
    // comments, ignored by all parsers.
    function stampM3u(body) {
        return String(body || "").replace("#EXTM3U\n", "#EXTM3U\n# serial " + Date.now() + "\n");
    }

    // MPD dispatch (§18 phase 2): catalog paths or prebuilt {uri, tags}
    // entries → staged queue JSON (FileView write, never a giant env
    // var) → helper run. Stream URLs pass through untouched; absolute
    // paths strip to music-relative in the helper. Empty material
    // notifies here so history never records a no-op.
    function runMpd(row, action, items) {
        var tracks = [];
        for (var i = 0; i < (items || []).length; i++) {
            var it = items[i];
            var u = String((it && typeof it === "object" ? it.uri : it) || "").trim();
            if (u.length === 0)
                continue;

            if (u.charAt(0) !== "/" && u.indexOf("://") < 0)
                continue;

            var e = {
                "uri": u
            };
            if (it && typeof it === "object" && it.tags)
                e.tags = it.tags;

            tracks.push(e);
        }
        if (tracks.length === 0) {
            root.notify("amla: nothing playable for '" + ((row && row.title) || action) + "' (MPD)");
            return ;
        }
        root.pendingMpdRow = row;
        root.pendingMpdAction = action;
        mpdQueueFile.setText(JSON.stringify({
            "tracks": tracks,
            "insertNext": action === "enqueue-next",
            "serial": Date.now()
        }));
    }

    // MPD random-album (§18 phase 2): local-only pick. Combined
    // random-album stays local until phase 3 brings server material;
    // random-album-temp expands a temp dir like a temp row.
    function dispatchMpdRandom(action) {
        var scope = action === "random-album" ? "local" : action.substring("random-album-".length);
        if (scope === "temp") {
            var temps = (root.listing && root.listing.temp) || [];
            if (temps.length === 0)
                return ;

            var dir = temps[Math.floor(Math.random() * temps.length)];
            root.pendingMpdAction = "play";
            root.pendingMpdRow = {
                "kind": "temp",
                "title": Catalog.basename(dir),
                "path": dir
            };
            mpdResolveProc.environment = {
                "PATH": "/usr/bin:/bin",
                "AMLA_DB": root.localDbPath(),
                "AMLA_SQL": Catalog.pathsUnderDirSql(dir, root.localDbTable())
            };
            mpdResolveProc.command = ["/usr/bin/sh", "-c", "/usr/bin/timeout --kill-after=5 15 /usr/bin/sqlite3 -readonly -noheader -list \"$AMLA_DB\" \"$AMLA_SQL\""];
            mpdResolveProc.running = true;
            root.cancel();
            return ;
        }
        if (scope === "subsonic") {
            // Server pick: getAlbumList2 random=1, then the MPD album
            // flow (mirrors the cliamp combined-random shape).
            if (!root.subEnabled) {
                root.notify("amla: no subsonic server configured — add must [subsonic], cliamp [navidrome], or amla subsonicUrl/User/Pass");
                return ;
            }
            var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
            root.pendingSubAction = "play";
            root.pendingSubRow = null;
            root.pendingSubTarget = "mpd";
            subRandomProc.command = ["/usr/bin/curl", "-s", "--max-time", "5", Subsonic.randomAlbumUrl(root.sub.url, auth)];
            subRandomProc.running = true;
            root.cancel();
            return ;
        }
        if (scope !== "local")
            return ;

        root.pendingMpdRandom = true;
        randomAlbumProc.command = ["/usr/bin/sh", "-c", "/usr/bin/timeout --kill-after=5 15 /usr/bin/sqlite3 -json -readonly '" + root.localDbPath() + "' \"SELECT album, COALESCE(NULLIF(album_artist,''), artist) AS a FROM " + root.localDbTable() + " WHERE album != '' GROUP BY album, a ORDER BY RANDOM() LIMIT 1\""];
        randomAlbumProc.running = true;
        root.cancel();
    }

    function runCliamp(row, action, ctx) {
        // Alt+Enter playshuffle: same clear-first load as play, then the
        // script switches shuffle explicitly on (ctx.shuffleAfter).
        // Plain play pins shuffle explicitly off (ctx.shuffleOffAfter):
        // cliamp persists shuffle into config.toml, so without this a
        // previous playshuffle would leak into the next play, even across
        // restarts. Enqueue paths leave the running order untouched.
        if (action === "playshuffle") {
            action = "play";
            if (!ctx.params)
                ctx.params = {
            };

            ctx.params.play = true;
            ctx.clearFirst = true;
            ctx.shuffleAfter = true;
        } else if (action === "play") {
            ctx.shuffleOffAfter = true;
        }
        dispatchProc.hist = historyFor(row);
        dispatchProc.script = Dispatch.build(action, row, "cliamp", ctx);
        dispatchProc.environment = {
            "PATH": "/usr/bin:/bin",
            "HOME": root.home,
            "AMLA_OP": String(ctx.op || ""),
            "AMLA_PARAMS": JSON.stringify(ctx.params || {
            }),
            "AMLA_M3U": String(ctx.m3uBody || "")
        };
        dispatchProc.command = ["/usr/bin/sh", "-c", dispatchProc.script];
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
            // EXTINF carries Artist - Album - Title: m3u has no split
            // fields (cliamp takes the whole string as Title), and the
            // real duration (never -1: duration-less URLs flag realtime).
            var ttl = Subsonic.m3uTitle(t.artist, t.album, t.title);
            var dur = t.duration || t.durationSecs || 0;
            body += "#EXTINF:" + dur + "," + ttl + "\n" + u + "\n";
        }
        return {
            "body": body,
            "firstUrl": urls.length > 0 ? urls[0] : ""
        };
    }

    // Fisher-Yates copy: playshuffle pre-shuffles the material itself
    // (cliamp target only) because cliamp's shuffle pins the loaded head
    // at position 0 — without this the first track is always the same.
    function shuffledCopy(arr) {
        var a = (arr || []).slice();
        for (var i = a.length - 1; i > 0; i--) {
            var j = Math.floor(Math.random() * (i + 1));
            var t = a[i];
            a[i] = a[j];
            a[j] = t;
        }
        return a;
    }

    // REST track objects → MPD queue entries: one fresh auth salt per
    // dispatch (shared across its tracks, like the m3u flows), stream
    // URL per id, split metadata tags (stream URLs carry none — the
    // preload half of the old gompd addtagid trick, default-on §18).
    function subTracksToMpd(tracks) {
        var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
        var out = [];
        for (var i = 0; i < (tracks || []).length; i++) {
            var t = tracks[i] || {
            };
            if (!t.id)
                continue;

            out.push({
                "uri": Subsonic.streamUrl(root.sub.url, auth, t.id),
                "tags": {
                    "artist": t.artist || "",
                    "album": t.album || "",
                    "title": t.title || "",
                    "track": t.track || "",
                    "date": t.year || ""
                }
            });
        }
        return out;
    }

    // Album/track ordering for server material: search endpoints return
    // relevance order (albums mixed up), so artist/genre/album/search
    // results sort client-side like the old cache-DB flows did. Server-
    // ordered kinds (playlists, year/decade batches) keep their order.
    function sortSubTracks(tracks) {
        var a = (tracks || []).slice();
        var num = function num(t) {
            return parseInt(t && t.track, 10) || 0;
        };
        a.sort(function(x, y) {
            var ax = String((x && x.album) || ""), ay = String((y && y.album) || "");
            if (ax !== ay)
                return ax < ay ? -1 : 1;

            var nx = num(x), ny = num(y);
            if (nx !== ny)
                return nx - ny;

            var tx = String((x && x.title) || ""), ty = String((y && y.title) || "");
            return tx < ty ? -1 : (tx > ty ? 1 : 0);
        });
        return a;
    }

    // MPD twin of runSubM3u: true when the fetch was armed for MPD
    // (pendingSubTarget), dispatching tagged stream URLs through runMpd
    // (playshuffle rides random mode on an ordered queue — no shuffle).
    // Clears the target flag; false lets the caller continue cliamp.
    function runSubMpd(tracks, fallbackAction) {
        if (root.pendingSubTarget !== "mpd")
            return false;

        root.pendingSubTarget = "";
        // Stale-flag guard: a failed fetch leaves the flag set while the
        // user moves on — never hijack another target's completion.
        if (root.targetPlayer !== "mpd")
            return false;

        var action = root.pendingSubAction || fallbackAction;
        var kind = root.pendingSubRow && root.pendingSubRow.kind;
        var list = (kind === "subsonic-playlist" || kind === "subsonic-year" || kind === "subsonic-decade") ? tracks : root.sortSubTracks(tracks);
        root.runMpd(root.pendingSubRow, action, root.subTracksToMpd(list));
        return true;
    }

    // MPD twin of dispatchSubsonicCliamp: same REST endpoints through
    // the shared procs; completions route via pendingSubTarget to
    // tagged stream URLs. No cliamp-daemon dependency, no provider ops.
    function dispatchSubsonicMpd(row, action) {
        var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
        if (row.kind === "subsonic-album" && row.id && String(row.id).length > 0) {
            subFallbackProc.command = ["/usr/bin/curl", "-s", "--max-time", "10", Subsonic.albumTracksUrl(root.sub.url, auth, row.id)];
            subFallbackProc.running = true;
        } else if (row.kind === "subsonic-artist") {
            subFallbackProc.command = ["/usr/bin/curl", "-s", "--max-time", "10", Subsonic.songsSearchUrl(root.sub.url, auth, row.title, 100)];
            subFallbackProc.running = true;
        } else if (row.kind === "subsonic-genre") {
            subGenreProc.command = ["/usr/bin/curl", "-s", "--max-time", "10", Subsonic.songsByGenreUrl(root.sub.url, auth, row.title)];
            subGenreProc.running = true;
        } else if (row.kind === "subsonic-year" || row.kind === "subsonic-decade") {
            var fromYear = row.kind === "subsonic-decade" ? row.decade : (row.year || parseInt(row.title, 10) || 0);
            var toYear = row.kind === "subsonic-decade" ? row.decade + 9 : fromYear;
            subYearListProc.command = ["/usr/bin/curl", "-s", "--max-time", "10", Subsonic.albumsByYearUrl(root.sub.url, auth, fromYear, toYear)];
            subYearListProc.running = true;
        } else if (row.kind === "subsonic-playlist" && row.id) {
            subPlaylistProc.command = ["/usr/bin/curl", "-s", "--max-time", "15", Subsonic.playlistUrl(root.sub.url, auth, row.id)];
            subPlaylistProc.running = true;
        } else {
            // Id-less album row (e.g. from history): REST search over
            // "artist album", mirroring subProviderFallback.
            var q = ((row.artist || "") + " " + (row.album || row.title)).trim();
            subFallbackProc.command = ["/usr/bin/curl", "-s", "--max-time", "10", Subsonic.songsSearchUrl(root.sub.url, auth, q, 100)];
            subFallbackProc.running = true;
        }
    }

    function runSubM3u(tracks, fallbackAction) {
        if (root.runSubMpd(tracks, fallbackAction))
            return ;

        var action = root.pendingSubAction || fallbackAction;
        var list = action === "playshuffle" ? root.shuffledCopy(tracks) : tracks;
        var m = root.subTracksToM3u(list);
        if (m.firstUrl.length === 0)
            return ;

        var m3u = Quickshell.env("XDG_RUNTIME_DIR") + "/amla/queue.m3u";
        root.runCliamp(root.pendingSubRow, action, {
            "op": "url.load",
            "params": {
                "path": m3u,
                "play": action === "play"
            },
            "clearFirst": action === "play",
            "insertNext": action === "enqueue-next",
            "m3uBody": m.body,
            "launchTarget": m3u
        });
    }

    function notify(msg) {
        notifyProc.environment = {
            "PATH": "/usr/bin:/bin",
            "AMLA_MSG": String(msg || "")
        };
        notifyProc.command = ["/usr/bin/sh", "-c", "/usr/bin/notify-send -a amla 'amla' \"$AMLA_MSG\" >/dev/null 2>&1 &"];
        notifyProc.running = true;
    }

    // Playlist → m3u body (§15a): mode toml synthesizes via cliamp
    // `playlist show --json` (authoritative [[track]] + [[dir]] + ~ +
    // env expansion); mode file cats a must m3u verbatim. Local files go
    // as bare paths (cliamp tag-probes them: full metadata + album
    // grouping, which a wholesale EXTINF title would destroy); http
    // entries keep EXTINF duration/title (untaggable streams — a bare
    // URL renders as the bare host). Completion routes must-target to
    // Dispatch via ctx.resolvedM3u, cliamp-target to url.load + m3u —
    // pre-shuffled for playshuffle (cliamp pins the loaded head at 0).
    function resolvePlaylistBody(row, action) {
        if (playlistResolveProc.running)
            return ;

        var mode = row.source === "cliamp" ? "toml" : "file";
        root.pendingPlaylistRow = row;
        root.pendingPlaylistAction = action;
        root.pendingPlaylistTarget = root.targetPlayer;
        root.pendingPlaylistMode = mode;
        playlistResolveProc.environment = {
            "PATH": "/usr/bin:/bin",
            "AMLA_PL_MODE": mode,
            "AMLA_PL_NAME": String(row.title || ""),
            "AMLA_PL_PATH": String(row.path || ""),
            "AMLA_HOME": root.home,
            "AMLA_XDG_CONFIG_HOME": Quickshell.env("XDG_CONFIG_HOME") || "",
            "AMLA_CLIAMP_CONFIG_DIR": Quickshell.env("CLIAMP_CONFIG_DIR") || ""
        };
        playlistResolveProc.command = ["/usr/bin/sh", "-c", "export HOME=\"$AMLA_HOME\"; [ -n \"$AMLA_XDG_CONFIG_HOME\" ] && export XDG_CONFIG_HOME=\"$AMLA_XDG_CONFIG_HOME\"; [ -n \"$AMLA_CLIAMP_CONFIG_DIR\" ] && export CLIAMP_CONFIG_DIR=\"$AMLA_CLIAMP_CONFIG_DIR\"; R=\"${XDG_RUNTIME_DIR:-/run/user/$(/usr/bin/id -u)}/amla\"; /usr/bin/mkdir -p \"$R\"; if [ \"$AMLA_PL_MODE\" = file ]; then /usr/bin/python3 -c 'import os,sys\nd=sys.argv[1]\ndef f(l):\n s=l.rstrip(chr(10))\n return s if (not s or s[:1]==chr(35) or s[:1]==chr(47) or chr(58)+chr(47)*2 in s) else os.path.normpath(os.path.join(d,s))\nsys.stdout.write(chr(10).join(map(f,sys.stdin))+chr(10))' \"$(/usr/bin/dirname \"$AMLA_PL_PATH\")\" < \"$AMLA_PL_PATH\" | /usr/bin/tee \"$R/pl.m3u\"; else [ -x /usr/bin/jq ] || exit 3; R=\"${XDG_RUNTIME_DIR:-/run/user/$(/usr/bin/id -u)}/amla\"; /usr/bin/mkdir -p \"$R\"; /usr/bin/cliamp playlist show \"$AMLA_PL_NAME\" --json 2>/dev/null | /usr/bin/jq -r '\"#EXTM3U\", (.[] | if (.path | startswith(\"http\")) then \"#EXTINF:\\(.duration_secs // 0),\\(if (.artist // \"\") != \"\" then \"\\(.artist) - \\(.title)\" else (.title // .path) end)\\n\\(.path)\" else .path end)' | /usr/bin/tee \"$R/pl.m3u\"; fi"];
        playlistResolveProc.running = true;
    }

    function completePlaylistBody(text) {
        var row = root.pendingPlaylistRow;
        var action = root.pendingPlaylistAction || "play";
        var target = root.pendingPlaylistTarget || "cliamp";
        root.pendingPlaylistRow = null;
        if (!row) {
            root.notify("amla: playlist resolution lost its row — try again");
            return ;
        }
        var body = String(text || "").trim();
        if (body.length === 0 || body === "#EXTM3U") {
            root.notify("amla: could not read playlist '" + row.title + "'" + (root.pendingPlaylistMode === "toml" ? " (needs cliamp + jq)" : "") + " or it is empty");
            return ;
        }
        if (action === "playshuffle" && target === "cliamp")
            body = Catalog.shuffleM3uBody(body);

        if (target === "must") {
            var ctx = {
                "mustBin": root.pluginMustBin,
                "query": root.filterText,
                "resolvedM3u": Quickshell.env("XDG_RUNTIME_DIR") + "/amla/pl.m3u"
            };
            dispatchProc.hist = historyFor(row);
            dispatchProc.script = Dispatch.build(action, row, target, ctx);
            dispatchProc.command = ["/usr/bin/sh", "-c", dispatchProc.script];
            dispatchProc.running = true;
            return ;
        }
        if (target === "mpd") {
            // Local entries only: resolvePlaylistBody already normalized
            // relative entries against the m3u dir; server/stream
            // entries wait for phase 3. Daemon shuffles playshuffle.
            var lines = body.split("\n");
            var ppaths = [];
            for (var pi = 0; pi < lines.length; pi++) {
                var pl = lines[pi].trim();
                if (pl.length === 0 || pl.charAt(0) === "#" || pl.indexOf("://") >= 0)
                    continue;

                ppaths.push(pl);
            }
            root.runMpd(row, action, ppaths);
            return ;
        }
        var m3u = Quickshell.env("XDG_RUNTIME_DIR") + "/amla/queue.m3u";
        // playshuffle passes through: runCliamp rewrites it to a
        // clear-first play + shuffleAfter (same as the facet flows).
        var started = action === "play" || action === "playshuffle";
        root.runCliamp(row, action, {
            "op": "url.load",
            "params": {
                "path": m3u,
                "play": started
            },
            "clearFirst": started,
            "insertNext": action === "enqueue-next",
            "m3uBody": body,
            "launchTarget": m3u
        });
    }

    // cliamp + subsonic album/artist: REST → track list → stream URLs.
    function dispatchSubsonicCliamp(row, action) {
        if (row.kind === "subsonic-album" && action === "playshuffle" && row.id && String(row.id).length > 0) {
            // Playshuffle skips the native provider load: cliamp's shuffle
            // pins the loaded head at position 0, so album track 1 would
            // always start. REST getAlbum → runSubM3u instead, which
            // pre-shuffles the m3u (same shape as the cold-play retry).
            pendingSubAction = action;
            pendingSubRow = row;
            var shufAuth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
            subFallbackProc.command = ["/usr/bin/curl", "-s", "--max-time", "10", Subsonic.albumTracksUrl(root.sub.url, shufAuth, row.id)];
            subFallbackProc.running = true;
            return ;
        }
        if (row.kind === "subsonic-album" && action === "play" && row.id && String(row.id).length > 0) {
            // Native provider load: replaces the live playlist and starts
            // playback in one call (no REST round-trip, no m3u). Cold
            // (stopped player) it cannot work — the script exits quietly
            // (coldSilent) and dispatchProc's onExited retries via REST
            // getAlbum → stream-URL m3u → TUI launch on the file, so the
            // player opens with music instead of an empty queue + retry.
            pendingFallbackAlbum = row;
            runCliamp(row, action, {
                "op": "provider.load_album",
                "params": {
                    "provider": "navidrome",
                    "album": row.id
                },
                "coldSilent": true
            });
            return ;
        }
        if (row.kind === "subsonic-album" && row.id && String(row.id).length > 0) {
            // Enqueue paths (play is provider.load_album above): resolve
            // cliamp-minted track URLs natively — full metadata plus
            // provider_meta, so enqueue-next id-matching works.
            pendingSubAction = action;
            pendingSubRow = row;
            subCliampTracksProc.environment = {
                "PATH": "/usr/bin:/bin",
                "HOME": root.home,
                "AMLA_POP": "provider.album_tracks",
                "AMLA_PPARAMS": JSON.stringify({
                    "provider": "navidrome",
                    "album": row.id,
                    "limit": 200
                })
            };
            subCliampTracksProc.command = ["/usr/bin/sh", "-c", "/usr/bin/cliamp remote call \"$AMLA_POP\" --params \"$AMLA_PPARAMS\" --wait"];
            subCliampTracksProc.running = true;
            return ;
        }
        if (row.kind === "subsonic-artist") {
            // Same search semantics as the old REST path (song matches),
            // but the URLs come from cliamp with provider identity attached.
            pendingSubAction = action;
            pendingSubRow = row;
            subCliampTracksProc.environment = {
                "PATH": "/usr/bin:/bin",
                "HOME": root.home,
                "AMLA_POP": "provider.search",
                "AMLA_PPARAMS": JSON.stringify({
                    "provider": "navidrome",
                    "query": row.title,
                    "limit": 100
                })
            };
            subCliampTracksProc.command = ["/usr/bin/sh", "-c", "/usr/bin/cliamp remote call \"$AMLA_POP\" --params \"$AMLA_PPARAMS\" --wait"];
            subCliampTracksProc.running = true;
            return ;
        }
        var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
        pendingSubAction = action;
        pendingSubRow = row;
        if (row.kind === "subsonic-genre") {
            subGenreProc.command = ["/usr/bin/curl", "-s", "--max-time", "10", Subsonic.songsByGenreUrl(root.sub.url, auth, row.title)];
            subGenreProc.running = true;
        } else if (row.kind === "subsonic-year" || row.kind === "subsonic-decade") {
            var fromYear = row.kind === "subsonic-decade" ? row.decade : (row.year || parseInt(row.title, 10) || 0);
            var toYear = row.kind === "subsonic-decade" ? row.decade + 9 : fromYear;
            subYearListProc.command = ["/usr/bin/curl", "-s", "--max-time", "10", Subsonic.albumsByYearUrl(root.sub.url, auth, fromYear, toYear)];
            subYearListProc.running = true;
        } else if (row.kind === "subsonic-playlist" && row.id) {
            // Server-side playlist: one getPlaylist hop, then the shared
            // file handoff (never a giant env body) — the write completion
            // dispatches to whichever target armed the fetch.
            pendingSubAction = action;
            pendingSubRow = row;
            subPlaylistProc.command = ["/usr/bin/curl", "-s", "--max-time", "15", Subsonic.playlistUrl(root.sub.url, auth, row.id)];
            subPlaylistProc.running = true;
        } else {
            // Id-less album row (e.g. from history): provider.search over
            // "artist album" resolves its tracks without REST.
            var q = ((row.artist || "") + " " + (row.album || row.title)).trim();
            subCliampTracksProc.environment = {
                "PATH": "/usr/bin:/bin",
                "HOME": root.home,
                "AMLA_POP": "provider.search",
                "AMLA_PPARAMS": JSON.stringify({
                    "provider": "navidrome",
                    "query": q,
                    "limit": 100
                })
            };
            subCliampTracksProc.command = ["/usr/bin/sh", "-c", "/usr/bin/cliamp remote call \"$AMLA_POP\" --params \"$AMLA_PPARAMS\" --wait"];
            subCliampTracksProc.running = true;
        }
    }

    // Provider-op fallback (P3): subCliampTracksProc reached no daemon.
    // Re-resolve the same row over plain REST, then runSubM3u dispatches
    // a stream-URL m3u — which plays cold (TUI launch on the file) or
    // notifies "needs running" for enqueue, exactly like local rows.
    function subProviderFallback() {
        var row = root.pendingSubRow;
        if (!row || subFallbackProc.running)
            return ;

        var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
        var url = "";
        if (row.kind === "subsonic-album" && row.id) {
            url = Subsonic.albumTracksUrl(root.sub.url, auth, row.id);
        } else if (row.kind === "subsonic-artist") {
            url = Subsonic.songsSearchUrl(root.sub.url, auth, row.title, 100);
        } else {
            var q = ((row.artist || "") + " " + (row.album || row.title)).trim();
            url = Subsonic.songsSearchUrl(root.sub.url, auth, q, 100);
        }
        if (!url)
            return ;

        subFallbackProc.command = ["/usr/bin/curl", "-s", "--max-time", "10", url];
        subFallbackProc.running = true;
    }

    // One indexed lookup per new MPRIS track: backfill the file path the
    // player never reports, so artwork (and future lookups) resolve.
    // Normalized title (Artist-prefix stripped) matches recordPlay's key.
    function resolveMprisPath(key, artist, album, title) {
        if (mprisPathProc.running)
            return ;

        mprisPathProc.lookupKey = key;
        mprisPathProc.environment = {
            "PATH": "/usr/bin:/bin",
            "AMLA_DB": root.localDbPath(),
            "AMLA_SQL": Catalog.trackPathSql(artist, album, History.stripArtistPrefix(artist, title), root.localDbTable())
        };
        mprisPathProc.command = ["/usr/bin/sh", "-c", "/usr/bin/timeout --kill-after=5 15 /usr/bin/sqlite3 -readonly \"$AMLA_DB\" \"$AMLA_SQL\""];
        mprisPathProc.running = true;
    }

    // Match path-less history items to temp album dirs (client-side, over
    // the cached listing) so their art resolves; persists artDir on hits.
    function matchTempArtDirs() {
        var temps = ((root.listing && root.listing.temp) || []).concat((root.listing && root.listing.library) || []);
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
        subBackfillProc.command = ["/usr/bin/curl", "-s", "--max-time", "5", url];
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
        backfillPathsProc.command = ["/usr/bin/timeout", "--kill-after=5", "15", "/usr/bin/sqlite3", "-json", "-readonly", root.localDbPath(), Catalog.backfillPathsSql(missing, root.localDbTable())];
        backfillPathsProc.running = true;
    }

    // Effective library roots (§12): amla config wins, else cliamp
    // initial_directory → must music_dirs → ~/Music for music, must
    // temp_dirs for temp. Recomputed whenever any config file loads.
    function refreshRoots() {
        root.libraryRoots = Config.resolveRoots(root.amlaPluginCfg, root.cliampInitialDir, root.mustConfig, root.home);
        refreshListings();
    }

    // Test hook (§19): "debugNoMust": true in config.json simulates a
    // must-less machine without touching the real DB.
    function debugNoMust() {
        return (root.amlaPluginCfg && root.amlaPluginCfg.debugNoMust) === true;
    }

    // The indexer ships inside the plugin dir (top level, not scripts/ —
    // install.sh excludes scripts/). resolvedUrl keeps working in the dev
    // checkout, the rsynced install, and a marketplace layout.
    function indexerPath() {
        var u = String(Qt.resolvedUrl("index-library.py"));
        if (u.indexOf("file://") === 0)
            u = u.substring(7);

        return u;
    }

    function maybeBuildIndex(force, reason) {
        if (indexBuildProc.running)
            return ;

        if (!force && Date.now() - root.lastIndexBuildMs < 120000)
            return ;

        var roots = root.libraryRoots.musicDirs || [];
        if (roots.length === 0)
            return ;

        var cmd = ["/usr/bin/python3", root.indexerPath(), "--db", root.filesDb, "--tagger", "auto"];
        var pc = root.amlaPluginCfg || {
        };
        // Bucket words: one flag per word (dir names may contain commas);
        // trimmed, empties dropped — the indexer lowercases for matching.
        var bw = (pc.bucketWords || []).map(function(w) {
            return String(w).trim();
        }).filter(function(w) {
            return w.length > 0;
        });
        for (var bwi = 0; bwi < bw.length; bwi++) cmd.push("--extra-buckets", bw[bwi])
        // Noise tokens: same one-flag-per-token transport (a regex may
        // contain commas); trimmed, empties dropped.
        var nt = (pc.noiseTokens || []).map(function(w) {
            return String(w).trim();
        }).filter(function(w) {
            return w.length > 0;
        });
        for (var nti = 0; nti < nt.length; nti++) cmd.push("--extra-noise", nt[nti])
        console.log("[amla] index build (" + (reason || "auto") + "): " + cmd.join(" "));
        indexBuildProc.command = cmd.concat(roots);
        indexBuildProc.running = true;
    }

    function runFilesFacets() {
        if (facetProc.running)
            return ;

        facetProc.mode = "files";
        facetProc.command = ["/usr/bin/timeout", "--kill-after=5", "15", "/usr/bin/sqlite3", "-json", "-readonly", root.filesDb, Catalog.filesFacetSql()];
        facetProc.running = true;
    }

    function refreshListings() {
        listingProc.command = ["/usr/bin/sh", "-c", Catalog.listingCommand(root.libraryRoots.tempDirs, root.playlistDir, root.libraryRoots.musicDirs, root.cliampPlaylistDir)];
        listingProc.running = true;
    }

    function refreshFacets() {
        // A query already in flight owns the completion handler (and the
        // mode flag); re-arming mid-flight kills it and its nonzero exit
        // would masquerade as a missing DB. Its completion rebuilds.
        if (facetProc.running)
            return ;

        if (root.debugNoMust()) {
            // No-must simulation: local facets come from the file index.
            // Subsonic facets still load when creds exist (e.g. cliamp's
            // [navidrome]) — a real must-less box with a configured
            // server has them, so the hook must not suppress them.
            root.mustDbOk = false;
            root.runFilesFacets();
            root.maybeBuildIndex(false, "debug-no-must");
        } else {
            facetProc.mode = "must";
            facetProc.command = ["/usr/bin/timeout", "--kill-after=5", "15", "/usr/bin/sqlite3", "-json", "-readonly", root.mustDb, Catalog.facetSql()];
            facetProc.running = true;
        }
        if (root.subEnabled) {
            var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
            subFacetProc.command = ["/usr/bin/sh", "-c", "/usr/bin/curl -s --max-time 5 '" + Subsonic.genresUrl(root.sub.url, auth) + "'; echo ---AMLASPLIT---; /usr/bin/curl -s --max-time 10 '" + Subsonic.byYearUrl(root.sub.url, auth) + "'; echo ---AMLASPLIT---; /usr/bin/curl -s --max-time 10 '" + Subsonic.playlistsUrl(root.sub.url, auth) + "'"];
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
        if (!root.mustDbOk || root.debugNoMust()) {
            root.runFilesFacets();
            root.maybeBuildIndex(true, "manual-refresh");
        }
        artMap = ({
        });
        flushArtProc.command = ["/usr/bin/sh", "-c", "/usr/bin/rm -rf " + Catalog.shq(root.artCacheDir) + "; mkdir -p " + Catalog.shq(root.artCacheDir)];
        flushArtProc.running = true;
        rescanProc.command = ["/usr/bin/sh", "-c", Dispatch.mustBinScript(root.pluginMustBin) + "\nif " + Dispatch.mustRunningExpr() + "; then \"$BIN\" rescan; fi"];
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
        History.recordPlay("song", artist, album, title, title, "", null, Catalog.songSubtitle(artist, album, ""));
        historyFile.setText(History.serialize());
        root.backfillHistoryPaths();
    }

    // One expansion batch (~12 getAlbum calls): chains the next run from
    // subYearExpandProc's handler until the queue drains, then the write
    // proc dispatches the file.
    function fireYearBatch() {
        if (root.yearQueue.length === 0)
            return ;

        var ids = root.yearQueue.splice(0, 12);
        var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
        var parts = [];
        for (var i = 0; i < ids.length; i++) parts.push("/usr/bin/curl -s --max-time 10 '" + Subsonic.albumTracksUrl(root.sub.url, auth, ids[i]) + "'; echo ---AMLAYEAR---")
        subYearExpandProc.command = ["/usr/bin/sh", "-c", "/usr/bin/mkdir -p '" + root.runtimeDir + "/amla' && " + parts.join("; ")];
        subYearExpandProc.running = true;
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
                if (!rows.length || !rows[0].album)
                    return ;

                // Album-granular pick: resolve the exact album through the
                // facet m3u flow (a random track's parent dir can span
                // multiple albums depending on library layout).
                var picked = {
                    "kind": "album",
                    "title": rows[0].album,
                    "album": rows[0].album,
                    "artist": rows[0].a || ""
                };
                // MPD random-album: resolve the pick through the MPD
                // path flow instead of the cliamp m3u flow below.
                if (root.pendingMpdRandom) {
                    root.pendingMpdRandom = false;
                    root.pendingMpdAction = "play";
                    root.pendingMpdRow = picked;
                    mpdResolveProc.environment = {
                        "PATH": "/usr/bin:/bin",
                        "AMLA_DB": root.localDbPath(),
                        "AMLA_SQL": Catalog.pathsForKindSql("album", picked, root.localDbTable())
                    };
                    mpdResolveProc.command = ["/usr/bin/sh", "-c", "/usr/bin/timeout --kill-after=5 15 /usr/bin/sqlite3 -readonly -noheader -list \"$AMLA_DB\" \"$AMLA_SQL\""];
                    mpdResolveProc.running = true;
                    return ;
                }
                root.pendingSubAction = "play";
                root.pendingSubRow = picked;
                cliampResolveProc.environment = {
                    "PATH": "/usr/bin:/bin",
                    "AMLA_DB": root.localDbPath(),
                    "AMLA_FILESDB": root.filesDb,
                    "AMLA_SQL": Catalog.pathsForKindM3uSql("album", picked, false, root.localDbTable()),
                    "AMLA_SQL_FILES": Catalog.pathsForKindM3uSql("album", picked, false, "files")
                };
                cliampResolveProc.command = ["/usr/bin/sh", "-c", "/usr/bin/mkdir -p \"${XDG_RUNTIME_DIR:-/run/user/$(/usr/bin/id -u)}/amla\" && /usr/bin/timeout --kill-after=5 15 /usr/bin/sqlite3 -readonly \"$AMLA_DB\" \"$AMLA_SQL\" > \"${XDG_RUNTIME_DIR:-/run/user/$(/usr/bin/id -u)}/amla/queue.m3u\"; if [ ! -s \"${XDG_RUNTIME_DIR:-/run/user/$(/usr/bin/id -u)}/amla/queue.m3u\" ] && [ -n \"$AMLA_SQL_FILES\" ] && [ \"$AMLA_DB\" != \"$AMLA_FILESDB\" ]; then /usr/bin/timeout --kill-after=5 15 /usr/bin/sqlite3 -readonly \"$AMLA_FILESDB\" \"$AMLA_SQL_FILES\" > \"${XDG_RUNTIME_DIR:-/run/user/$(/usr/bin/id -u)}/amla/queue.m3u\"; fi; /usr/bin/wc -l < \"${XDG_RUNTIME_DIR:-/run/user/$(/usr/bin/id -u)}/amla/queue.m3u\""];
                cliampResolveProc.running = true;
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
        property string dbUsed: "must"

        onExited: function(exitCode) {
            if (exitCode === 0 && searchProc.dbUsed === "must")
                root.mustDbOk = true;

            // must query failed (DB gone) → flip to the file index once,
            // then retry this query against it. Files failures stay local
            // (no loop): stale/empty rows until the next build.
            var failedMust = exitCode !== 0 && searchProc.dbUsed === "must";
            if (failedMust) {
                console.log("[amla] must search failed (exit " + exitCode + "), using file index");
                root.mustDbOk = false;
                root.runFilesFacets();
                root.maybeBuildIndex(false, "search-fail");
            }
            if (root.searchDirty) {
                root.searchDirty = false;
                root.requestSearch();
            } else if (failedMust) {
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
        id: playlistResolveProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.completePlaylistBody(text);
            }
        }

    }

    Process {
        id: notifyProc
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
                try {
                    var pl = Subsonic.getSubsonic(parts[2] || "");
                    if (pl)
                        root.subPlaylists = Subsonic.playlistList(pl);

                } catch (e) {
                }
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

            artProc.command = ["/usr/bin/sh", "-c", Catalog.artProbeCommand(jobs)];
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
                    // An MPD-scoped pick degrades to a local MPD pick.
                    if (root.pendingSubTarget === "mpd") {
                        // MPD-scoped pick, server unreachable: degrade to
                        // a local MPD pick via the shared firing below.
                        root.pendingSubTarget = "";
                        root.pendingMpdRandom = true;
                        root.randomFallbackLocal = true;
                    }
                    if (root.randomFallbackLocal) {
                        root.randomFallbackLocal = false;
                        randomAlbumProc.command = ["/usr/bin/sh", "-c", "/usr/bin/timeout --kill-after=5 15 /usr/bin/sqlite3 -json -readonly '" + root.localDbPath() + "' \"SELECT album, COALESCE(NULLIF(album_artist,''), artist) AS a FROM " + root.localDbTable() + " WHERE album != '' GROUP BY album, a ORDER BY RANDOM() LIMIT 1\""];
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
                // MPD-scoped random: the REST album flow, not cliamp's.
                if (root.pendingSubTarget === "mpd") {
                    root.pendingSubAction = "play";
                    root.pendingSubRow = pseudoRow;
                    root.dispatchSubsonicMpd(pseudoRow, "play");
                    return ;
                }
                root.dispatchSubsonicCliamp(pseudoRow, "play");
            }
        }

    }

    Process {
        id: subGenreProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var sub = Subsonic.getSubsonic(String(text || ""));
                var songs = Subsonic.genreSongs(sub);
                if (songs.length >= 500)
                    root.notify("amla: genre '" + (root.pendingSubRow ? root.pendingSubRow.title : "") + "' capped at first 500 songs");

                root.runSubM3u(songs, "enqueue");
            }
        }

    }

    // Year/decade expansion is two hops: album list first, then one getAlbum
    // per album. Fetched in small batches (~12 albums, ~200 KB stdout each):
    // a full decade is ~1.2 MB, which dies somewhere between the QML
    // stdout collector and the dispatch env handoff while single years
    // pass through. Accumulated as minimal track objects, then the m3u is
    // written straight to disk (no giant env var) and url.load takes the
    // file path — the same file-handoff shape as cliampResolveProc.
    Process {
        id: subYearListProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var sub = Subsonic.getSubsonic(String(text || ""));
                var allAlbums = Subsonic.yearAlbums(sub);
                if (allAlbums.length > 100)
                    root.notify("amla: " + (root.pendingSubRow ? root.pendingSubRow.title : "year") + " capped at first 100 of " + allAlbums.length + " albums");

                var albums = allAlbums.slice(0, 100);
                if (albums.length === 0)
                    return ;

                root.yearQueue = [];
                for (var i = 0; i < albums.length; i++) root.yearQueue.push(albums[i].id)
                root.yearTracks = [];
                root.fireYearBatch();
            }
        }

    }

    Process {
        id: subYearExpandProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var chunks = String(text || "").split("---AMLAYEAR---");
                for (var i = 0; i < chunks.length; i++) {
                    var sub = null;
                    try {
                        sub = Subsonic.getSubsonic(chunks[i]);
                    } catch (e) {
                        sub = null;
                    }
                    var songs = Subsonic.albumSongs(sub);
                    for (var j = 0; j < songs.length; j++) {
                        var s = songs[j];
                        root.yearTracks.push({
                            "id": s.id || "",
                            "artist": s.artist || "",
                            "album": s.album || "",
                            "title": s.title || "",
                            "duration": s.duration || 0,
                            "track": s.track || "",
                            "year": s.year || ""
                        });
                    }
                }
                if (root.yearQueue.length > 0) {
                    root.fireYearBatch();
                    return ;
                }
                if (root.yearTracks.length === 0)
                    return ;

                // MPD target: tagged stream URLs straight through runMpd
                // (its own staging carries the dedup serial) — no m3u.
                if (root.runSubMpd(root.yearTracks, "enqueue"))
                    return ;

                // FileView write (not a shell printf): a ~190 KB command
                // string never completes under quickshell Process, while
                // setText has no such ceiling. Playshuffle pre-shuffles
                // (cliamp pins the loaded head at position 0).
                var yearList = root.pendingSubAction === "playshuffle" ? root.shuffledCopy(root.yearTracks) : root.yearTracks;
                var m = root.subTracksToM3u(yearList);
                if (m.firstUrl.length === 0)
                    return ;

                yearM3uFile.setText(root.stampM3u(m.body));
            }
        }

    }

    // Completion of the batched year/decade write: dispatch the file.
    // url.load takes the path with no m3uBody (never a giant env var).
    FileView {
        id: yearM3uFile

        path: root.runtimeDir + "/amla/queue.m3u"
        atomicWrites: true
        watchChanges: false
        printErrors: false
        onSaved: {
            var action = root.pendingSubAction || "enqueue";
            var file = root.runtimeDir + "/amla/queue.m3u";
            root.runCliamp(root.pendingSubRow, action, {
                "op": "url.load",
                "params": {
                    "path": file,
                    "play": action === "play"
                },
                "clearFirst": action === "play",
                "insertNext": action === "enqueue-next",
                "launchTarget": file
            });
        }
        onSaveFailed: function(error) {
            console.log("[amla] year/decade m3u write failed: " + error);
        }
    }

    // Server-side playlist expansion (cliamp target, plus the must
    // compatibility fallback; new must resolves natively via
    // subsonic:playlist:<id>): getPlaylist entries →
    // stream-URL m3u written straight to disk (a big server list would
    // die in the dispatch env handoff). Playshuffle pre-shuffles
    // (cliamp pins the loaded head at 0).
    Process {
        id: subPlaylistProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var sub = Subsonic.getSubsonic(String(text || ""));
                var entries = Subsonic.playlistSongs(sub);
                if (entries.length === 0) {
                    root.notify("amla: playlist '" + (root.pendingSubRow ? root.pendingSubRow.title : "") + "' has no playable entries");
                    return ;
                }
                // MPD target: tagged stream URLs, no pre-shuffle (the
                // daemon shuffles server-side).
                if (root.runSubMpd(entries, "enqueue"))
                    return ;

                var list = root.pendingSubAction === "playshuffle" ? root.shuffledCopy(entries) : entries;
                subPlaylistFile.setText(root.stampM3u(root.subTracksToM3u(list).body));
            }
        }

    }

    FileView {
        id: subPlaylistFile

        path: root.runtimeDir + "/amla/subpl.m3u"
        atomicWrites: true
        watchChanges: false
        printErrors: false
        onSaved: {
            var action = root.pendingSubAction || "enqueue";
            var file = root.runtimeDir + "/amla/subpl.m3u";
            if (root.pendingSubTarget === "must") {
                var compatCtx = {
                    "mustBin": root.pluginMustBin,
                    "query": root.filterText,
                    "resolvedM3u": file
                };
                dispatchProc.hist = historyFor(root.pendingSubRow);
                dispatchProc.script = Dispatch.build(action, root.pendingSubRow, "must", compatCtx);
                dispatchProc.command = ["/usr/bin/sh", "-c", dispatchProc.script];
                dispatchProc.running = true;
                return ;
            }
            root.runCliamp(root.pendingSubRow, action, {
                "op": "url.load",
                "params": {
                    "path": file,
                    "play": action === "play"
                },
                "clearFirst": action === "play",
                "insertNext": action === "enqueue-next",
                "launchTarget": file
            });
        }
        onSaveFailed: function(error) {
            console.log("[amla] server playlist m3u write failed: " + error);
        }
    }

    // must capability probe (see probeMustVersion): stdout is the raw
    // `must --version` line, cached in mustVersion; empty when no
    // binary (unknown => compatibility fallbacks, never a nag).
    Process {
        id: mustVersionProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.mustVersion = String(text || "").trim();
            }
        }

    }

    // MPD probe result: exit 0 (mpc reached the daemon) => up, anything
    // else (no binary, connection refused) => down.
    Process {
        id: mpdProbeProc

        onExited: function(exitCode) {
            root.mpdAlive = exitCode === 0 ? 1 : 0;
        }
    }

    // MPD facet/dir resolution (§18 phase 2): sqlite emits one absolute
    // path per line; runMpd stages and dispatches (empty → notify).
    Process {
        id: mpdResolveProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                if (!root.pendingMpdRow)
                    return ;

                var paths = [];
                var lines = String(text || "").split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var l = lines[i].trim();
                    if (l.length > 0)
                        paths.push(l);

                }
                root.runMpd(root.pendingMpdRow, root.pendingMpdAction || "enqueue", paths);
            }
        }

    }

    // MPD queue staging (§18 phase 2): FileView write (never a giant env
    // var) → helper dispatch. History records on exit 0, same as the
    // other targets.
    FileView {
        id: mpdQueueFile

        path: root.runtimeDir + "/amla/mpd_queue.json"
        atomicWrites: true
        watchChanges: false
        printErrors: false
        onSaved: {
            var ctx = {
                "mustBin": root.pluginMustBin,
                "query": root.filterText,
                "mpdHost": (root.amlaPluginCfg && root.amlaPluginCfg.mpdHost) || "",
                "mpdPort": (root.amlaPluginCfg && root.amlaPluginCfg.mpdPort) || 0,
                "helper": root.mpdHelperPath(),
                "queueFile": root.runtimeDir + "/amla/mpd_queue.json",
                "stripPrefixes": (root.libraryRoots && root.libraryRoots.musicDirs) || []
            };
            dispatchProc.hist = historyFor(root.pendingMpdRow);
            dispatchProc.script = Dispatch.build(root.pendingMpdAction || "play", root.pendingMpdRow, "mpd", ctx);
            dispatchProc.command = ["/usr/bin/sh", "-c", dispatchProc.script];
            dispatchProc.running = true;
        }
        onSaveFailed: function(error) {
            console.log("[amla] mpd queue write failed: " + error);
        }
    }

    Process {
        id: subCliampTracksProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var tracks = [];
                try {
                    var d = JSON.parse(String(text || ""));
                    var list = (d && d.job && d.job.result && d.job.result.tracks) || [];
                    for (var i = 0; i < list.length; i++) {
                        if (list[i] && list[i].path)
                            tracks.push(list[i]);

                    }
                } catch (e) {
                    // Daemon down (or any non-JSON reply): the provider op
                    // never reached a player — retry via plain REST below
                    // instead of failing silently (fixes.txt notes 2/3: no
                    // playback AND no "needs running" notification).
                    root.subProviderFallback();
                    return ;
                }
                if (tracks.length === 0) {
                    root.subProviderFallback();
                    return ;
                }
                var action = root.pendingSubAction || "enqueue";
                var ordered = action === "playshuffle" ? root.shuffledCopy(tracks) : tracks;
                var body = "#EXTM3U\n";
                for (var j = 0; j < ordered.length; j++) body += "#EXTINF:" + (ordered[j].duration || ordered[j].durationSecs || 0) + "," + Subsonic.m3uTitle(ordered[j].artist, ordered[j].album, ordered[j].title) + "\n" + ordered[j].path + "\n"
                var m3u = Quickshell.env("XDG_RUNTIME_DIR") + "/amla/queue.m3u";
                root.runCliamp(root.pendingSubRow, action, {
                    "op": "url.load",
                    "params": {
                        "path": m3u,
                        "play": action === "play"
                    },
                    "clearFirst": action === "play",
                    "insertNext": action === "enqueue-next",
                    "m3uBody": body,
                    "launchTarget": ordered[0].path
                });
            }
        }

    }

    // Plain-REST retry for provider ops that reached no daemon (P3) and
    // for cold provider.load_album (via dispatchProc.onExited). Shapes
    // Navidrome children, then the shared m3u dispatch (cold plays via
    // TUI launch on the file; cold enqueue notifies like local rows).
    Process {
        id: subFallbackProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var row = root.pendingSubRow;
                if (!row)
                    return ;

                var sub = Subsonic.getSubsonic(String(text || ""));
                var tracks = row.kind === "subsonic-album" ? Subsonic.albumSongs(sub) : Subsonic.searchSongs(sub);
                if (tracks.length === 0)
                    return ;

                root.runSubM3u(tracks, "enqueue");
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
            // Cold provider.load_album never reaches a player: retry the
            // album via REST (stream-URL m3u → TUI launch on the file).
            var fb = root.pendingFallbackAlbum;
            root.pendingFallbackAlbum = null;
            if (exitCode !== 0 && fb) {
                root.pendingSubAction = "play";
                root.pendingSubRow = fb;
                var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
                subFallbackProc.command = ["/usr/bin/curl", "-s", "--max-time", "10", Subsonic.albumTracksUrl(root.sub.url, auth, fb.id)];
                subFallbackProc.running = true;
                return ;
            }
            if (exitCode !== 0 || !dispatchProc.hist)
                return ;

            var h = dispatchProc.hist;
            History.recordPlay(h.type, h.artist, h.album, h.title, h.display, h.path || "", {
                "coverArt": h.coverArt || "",
                "subId": h.subId || ""
            }, h.subtitle || "");
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

        property string mode: "must"

        onExited: function(exitCode) {
            if (facetProc.mode === "must") {
                if (exitCode === 0) {
                    root.mustDbOk = true;
                } else {
                    // must absent → the file index becomes the local
                    // backend: facet it and (re)build it.
                    console.log("[amla] must facet failed (exit " + exitCode + "), using file index");
                    root.mustDbOk = false;
                    root.runFilesFacets();
                    root.maybeBuildIndex(false, "facet-fail");
                }
            } else {
                root.mustDbOk = false;
            }
        }

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                // Drop stale completions: a slow query from the previous
                // backend must not overwrite the current one's facets.
                var wantFiles = !root.mustDbOk || root.debugNoMust();
                if ((facetProc.mode === "files") !== wantFiles)
                    return ;

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

    // File-index build completion: refresh facets over the new rows and
    // re-run the live query so song rows pop in without retyping.
    Process {
        id: indexBuildProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                console.log("[amla] index build done: " + String(text || "").slice(0, 300));
                root.lastIndexBuildMs = Date.now();
                root.runFilesFacets();
                if (root.filterText.length > 0)
                    root.requestSearch();
                else
                    root.rebuildDisplay();
            }
        }

    }

    // Config save merge: FileView watchChanges does not refire on external
    // edits, so in-memory amlaPluginCfg may predate keys added outside the
    // shell. Every save re-reads the file and overlays only the dirty keys
    // (configSaveProc.pending is a partial object); everything else keeps
    // its on-disk value, so neither hand edits nor stale in-memory state
    // can be clobbered. A missing/unreadable file degrades to writing the
    // dirty keys.
    Process {
        id: configSaveProc

        property string pending: ""

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var disk = {
                };
                try {
                    disk = JSON.parse(String(text || ""));
                } catch (e) {
                }
                var dirty = JSON.parse(configSaveProc.pending);
                for (var k in dirty) {
                    if (dirty[k] !== undefined)
                        disk[k] = dirty[k];

                }
                pluginConfigFile.setText(JSON.stringify(disk, null, 2) + "\n");
            }
        }

    }

    // amla's XDG dirs (config/state/cache) must exist before first write.
    Process {
        id: dirSetup

        command: ["/usr/bin/sh", "-c", "/usr/bin/mkdir -p ~/.config/amla ~/.local/state/amla ~/.cache/amla/art"]
        running: true
    }

    // amla-owned file index (§13): schema created idempotently at startup;
    // the tag builder (later slice) only ever INSERTs into it.
    Process {
        id: filesDbSetup

        environment: {
            "AMLA_DB": root.filesDb,
            "AMLA_SCHEMA": Catalog.filesDbSchema()
        }
        command: ["/usr/bin/sh", "-c", "/usr/bin/mkdir -p \"${AMLA_DB%/*}\" && /usr/bin/sqlite3 \"$AMLA_DB\" \"$AMLA_SCHEMA\""]
        running: true
    }

    FileView {
        id: cliampConfigFile

        path: root.home + "/.config/cliamp/config.toml"
        watchChanges: true
        printErrors: false
        onLoaded: {
            root.cliampInitialDir = Config.parseCliampConfig(text(), root.home).initialDirectory;
            var nav = Config.cliampSubsonic(text());
            // cliamp allows ${VAR} indirection for secrets: expand from
            // the shell environment so token-based setups authenticate.
            for (var k in nav) {
                if (typeof nav[k] === "string")
                    nav[k] = nav[k].replace(/\$\{([^}]+)\}/g, function(m, name) {
                    return Quickshell.env(name) || m;
                });

            }
            root.cliampNav = nav;
            root.refreshSub();
            refreshRoots();
        }
    }

    FileView {
        id: mustConfigFile

        path: root.home + "/.config/must/config.toml"
        watchChanges: true
        printErrors: false
        onLoaded: {
            root.mustConfig = Config.mustConfig(text(), root.home);
            root.refreshSub();
            refreshRoots();
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
            root.amlaPluginCfg = pc;
            root.targetPlayer = pc.targetPlayer;
            root.pluginMustBin = pc.mustBin || "";
            root.pluginConfigLoaded = true;
            root.refreshSub();
            if (pc.debugNoMust)
                root.mustDbOk = false;

            refreshRoots();
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
                        textFormat: Text.PlainText
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

                            // Debug affordance: the badge declares the
                            // must-less simulation ONLY when the debug flag is
                            // set. Genuine no-must installs read plain `cliamp`.
                            text: root.targetBadgeText()
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
                                    textFormat: Text.PlainText
                                    color: index === root.selectedIndex ? Color.menu.selectedText : Color.menu.text
                                    font.family: Style.font.menuFamily
                                    font.pixelSize: Style.font.heading
                                    font.weight: Font.Medium
                                    elide: Text.ElideRight
                                    width: parent.width
                                }

                                Text {
                                    text: modelData.subtitle
                                    textFormat: Text.PlainText
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
                                textFormat: Text.PlainText
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
