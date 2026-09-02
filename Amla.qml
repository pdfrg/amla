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
    readonly property real rowHeight: Style.space(44)
    readonly property int maxRows: 14
    readonly property bool emptyQuery: filterText.length === 0
    // Popup chrome, mirroring the omarchy menu card.
    readonly property color background: Color.menu.background
    readonly property color scrim: Color.menu.scrim
    readonly property real cornerRadius: Style.cornerRadius
    readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
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
    readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
    readonly property var mprisActive: {
        var best = null;
        var list = mprisPlayers;
        for (var i = 0; i < list.length; i++) {
            var p = list[i];
            if (!p || p.playbackState !== Mpris.PlaybackState.Playing)
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
    readonly property string buildId: "0.4.0-catalog"
    property string pendingSubAction: ""
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
            "targetPlayer": root.targetPlayer
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
            if (favs[key] !== undefined)
                score = History.scoreOf(favs[key]) * 1000;

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
            var cached = Catalog.localRows([], root.listing, q);
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
                var locals = Catalog.localRows(root.searchRows, root.listing, q);
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
        var key = row.kind.indexOf("subsonic-") === 0 ? Catalog.subArtCacheFile(row.coverArt || row.id, root.artCacheDir) : Catalog.artDirFor(row);
        var f = artMap[key];
        return f || "";
    }

    function artJobs() {
        var seen = {
        };
        var jobs = [];
        for (var i = 0; i < root.displayModel.length; i++) {
            var row = root.displayModel[i];
            var job = null;
            if (row.kind.indexOf("subsonic-") === 0) {
                var cache = Catalog.subArtCacheFile(row.coverArt || row.id, root.artCacheDir);
                if (cache.length > 0 && root.subEnabled) {
                    var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
                    job = {
                        "dir": Catalog.artDirFor(row) || cache,
                        "out": cache,
                        "url": Subsonic.coverArtUrl(root.sub.url, auth, row.coverArt || row.id, 96)
                    };
                }
            } else {
                var dir = Catalog.artDirFor(row);
                if (dir.length > 0)
                    job = {
                    "dir": dir,
                    "out": ""
                };

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
        if (row.kind === "action" && row.action === "random-album")
            action = "random-album";

        if (!action)
            action = "play";

        dispatch(row, action);
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
                "path": row.path || ""
            };
        case "album":
        case "subsonic-album":
            return {
                "type": "album",
                "artist": row.artist || "",
                "album": row.album || row.title,
                "title": "",
                "display": row.title,
                "path": row.albumPath || ""
            };
        case "artist":
        case "subsonic-artist":
            return {
                "type": "artist",
                "artist": "",
                "album": "",
                "title": row.title,
                "display": row.title,
                "path": row.path || ""
            };
        case "genre":
            return {
                "type": "genre",
                "artist": "",
                "album": "",
                "title": row.title,
                "display": row.title
            };
        case "year":
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
        if (target === "cliamp" && action === "random-album" && root.subEnabled) {
            var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
            pendingSubAction = "play";
            pendingSubRow = null;
            subRandomProc.command = ["curl", "-s", "--max-time", "5", Subsonic.randomAlbumUrl(root.sub.url, auth)];
            subRandomProc.running = true;
            return ;
        }
        if (target === "cliamp" && row && row.kind.indexOf("subsonic-") === 0 && action !== "random-album") {
            dispatchSubsonicCliamp(row, action);
            return ;
        }
        if (target === "cliamp" && row) {
            if (row.kind === "song" || row.kind === "playlist") {
                ctx.files = [row.path];
            } else if (row.kind === "temp") {
                ctx.expandDir = row.path;
            } else if (row.kind === "album") {
                ctx.expandDir = row.albumPath || "";
                if (!ctx.expandDir)
                    ctx.files = [];

            }
        }
        dispatchProc.script = Dispatch.build(action, row, target, ctx);
        dispatchProc.hist = historyFor(row);
        dispatchProc.command = ["sh", "-c", dispatchProc.script];
        dispatchProc.running = true;
    }

    // cliamp + subsonic rows: fetch tracks, write an m3u of stream URLs, load it.
    function dispatchSubsonicCliamp(row, action) {
        var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
        pendingSubAction = action;
        pendingSubRow = row;
        if (row.kind === "subsonic-song") {
            writeSubsonicM3u([{
                "id": row.id,
                "artist": row.artist,
                "title": row.titleField || row.title,
                "duration": row.duration || 0
            }]);
            return ;
        }
        subAlbumProc.command = ["curl", "-s", "--max-time", "5", Subsonic.apiUrl(root.sub.url, "getAlbum", auth + "&id=" + encodeURIComponent(row.id))];
        subAlbumProc.running = true;
    }

    function writeSubsonicM3u(tracks) {
        var lines = ["#EXTM3U"];
        for (var i = 0; i < tracks.length; i++) {
            var t = tracks[i];
            lines.push("#EXTINF:" + (t.duration || -1) + "," + (t.artist || "") + " - " + (t.title || ""));
            var auth = Subsonic.authParams(root.sub.username, root.sub.password, Md5.randomSalt());
            lines.push(Subsonic.streamUrl(root.sub.url, auth, t.id));
        }
        m3uFile.path = root.runtimeDir + "/amla/sub-" + Date.now() + ".m3u";
        pendingM3uText = lines.join("\n") + "\n";
        m3uFile.setText(pendingM3uText);
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
        var now = Date.now();
        if (key === root.lastRecordedKey && now - root.lastRecordedMs < 15000)
            return ;

        root.lastRecordedKey = key;
        root.lastRecordedMs = now;
        History.recordPlay("song", artist, album, title, title, "");
        historyFile.setText(History.serialize());
    }

    onFilterTextChanged: searchDebounce.restart()
    onDisplayModelChanged: root.selectedIndex = 0
    Component.onCompleted: rebuildDisplay()

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

    FileView {
        id: m3uFile

        watchChanges: false
        printErrors: false
    }

    Timer {
        id: m3uDispatchTimer

        interval: 200
        onTriggered: {
            dispatchProc.script = Dispatch.build(root.pendingSubAction, root.pendingSubRow, "cliamp", {
                "m3uPath": m3uFile.path,
                "mustBin": root.pluginMustBin
            });
            dispatchProc.command = ["sh", "-c", dispatchProc.script];
            dispatchProc.running = true;
        }
    }

    Connections {
        function onTextChanged() {
            if (root.pendingM3uText.length > 0 && m3uFile.text() === root.pendingM3uText) {
                root.pendingM3uText = "";
                m3uDispatchTimer.restart();
            }
        }

        target: m3uFile
    }

    Process {
        id: subRandomProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var sub = Subsonic.getSubsonic(String(text || ""));
                var alb = (sub && sub.albumList2 && sub.albumList2.album && sub.albumList2.album[0]) || null;
                if (!alb)
                    return ;

                root.pendingSubRow = {
                    "kind": "subsonic-album",
                    "id": alb.id || "",
                    "album": alb.name || "",
                    "artist": alb.artist || "",
                    "title": alb.name || ""
                };
                root.dispatchSubsonicCliamp(root.pendingSubRow, "play");
            }
        }

    }

    Process {
        id: subAlbumProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var sub = Subsonic.getSubsonic(String(text || ""));
                var tracks = (sub && sub.album && sub.album.song) || [];
                root.writeSubsonicM3u(tracks);
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
            History.recordPlay(h.type, h.artist, h.album, h.title, h.display, h.path || "");
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
                            root.dispatch(null, "random-album");
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
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        id: filterDisplay

                        text: root.filterText.length > 0 ? root.filterText : "type to search"
                        color: root.filterText.length > 0 ? Color.menu.text : Color.muted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
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

                    delegate: Rectangle {
                        required property var modelData
                        required property int index

                        width: resultList.width
                        height: root.rowHeight
                        radius: Style.cornerRadius
                        color: index === root.selectedIndex ? Color.menu.selectedBackground : (rowHover.hovered ? Style.hoverFillFor(Color.menu.text, Color.menu.selectedText, Color.urgent) : "transparent")

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
                                    text: ""
                                    color: Color.muted
                                    font.family: Style.font.menuFamily
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
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.body
                                    elide: Text.ElideRight
                                    width: parent.width
                                }

                                Text {
                                    text: modelData.subtitle
                                    color: Color.muted
                                    font.family: Style.font.family
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
                    text: "enter: play   shift+enter: enqueue   ctrl+enter: play next   alt+r: random album   ctrl+t: player   esc: close"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    visible: root.displayModel.length > 0
                }

            }

        }

    }

}
