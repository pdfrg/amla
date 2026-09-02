// Playback dispatch to must (primary) or cliamp (alternate).
// Pure JS: builds one sh -c script per action; the QML side runs it and
// records history on exit 0.
//
// must resolvers (DOCUMENTATION.md IPC section): /path, playlist:<n>,
// subsonic:<q>, artist:<q>, album:<q>, genre:<q>, year:<y|from-to>, free text.
// must play / playshuffle auto-start the TUI when not running; enqueue does
// not (degrades to launch + notification per plan).
// cliamp v1.63.2 (pinned empirically): no remote subcommand; verbs load
// "Playlist", queue </path/file>, play/pause/next/status; socket at
// ~/.config/cliamp/cliamp.sock.

function shq(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
}

// Shared must-binary-not-found notification fragment (module scope: used by
// mustBinScript's generated scripts).
var NOTIFY_BIN = "notify-send -a amla 'amla' 'must binary not found — install it (e.g. to ~/.local/bin) or set mustBin in ~/.config/amla/config.json' >/dev/null 2>&1 &"

function mustBinScript(configOverride) {
    // Published plugin: no dev-machine paths in code. Resolution order:
    // config override, then PATH. Empty → the script notifies and fails.
    if (configOverride && String(configOverride).length > 0)
        return "BIN=" + shq(String(configOverride)) + "\n[ -x \"$BIN\" ] || BIN=$(command -v must 2>/dev/null || true)\nif [ -z \"$BIN\" ]; then\n  " + NOTIFY_BIN + "\n  exit 1\nfi"
    return "BIN=$(command -v must 2>/dev/null || true)\nif [ -z \"$BIN\" ]; then\n  " + NOTIFY_BIN + "\n  exit 1\nfi"
}

// Liveness probe, not socket existence — must leaves a stale ctl.sock behind
// after a crash, and dialing it just fails.
function mustRunningExpr() {
    return "\"$BIN\" status >/dev/null 2>&1"
}

function cliampRunningExpr() {
    return "[ -S \"$HOME/.config/cliamp/cliamp.sock\" ]"
}

// Resolver argument for must, per row kind.
function mustResolver(row) {
    if (!row)
        return ""
    switch (row.kind) {
    case "song":
    case "playlist":
    case "temp":
        return shq(row.path || row.title || "")
    case "subsonic-song":
        if (row.path && row.path.length > 0)
            return shq(row.path)
        return "subsonic:song:" + shq(row.titleField || row.title)
    case "album":
        return "album:" + shq(row.album || row.title)
    case "subsonic-album":
        return "subsonic:album:" + shq(row.album || row.title)
    case "artist":
        return "artist:" + shq(row.title)
    case "subsonic-artist":
        return "subsonic:artist:" + shq(row.title)
    case "genre":
        return "genre:" + shq(row.title)
    case "year":
        return "year:" + shq(row.title)
    case "decade":
        return "year:" + row.decade + "-" + (row.decade + 9)
    default:
        return ""
    }
}

// One sh -c script performing the action end to end (running check, dispatch,
// launch fallback, notification). exit 0 = success (history records).
function build(action, row, target, ctx) {
    var notify = function (msg) {
        return "notify-send -a amla " + shq("amla") + " " + shq(msg) + " >/dev/null 2>&1 &"
    }
    var bin = mustBinScript(ctx.mustBin)

    if (target === "must") {
        // not running → launch the verb inside a fresh terminal: auto-start
        // needs a TTY (from the plugin's headless Process it fails with
        // "bubbletea: error opening TTY"), and omarchy-launch-tui is a
        // passthrough, so pass the resolved binary path.
        var launchVerb = function (args) {
            return "omarchy-launch-tui \"$BIN\" " + args + " >/dev/null 2>&1 &"
        }
        if (action === "random-album") {
            return bin + "\nif " + mustRunningExpr() + "; then\n  \"$BIN\" random\nelse\n  " + launchVerb("random") + "\nfi"
        }
        if (action === "playshuffle") {
            var psq = row && row.kind !== "action" && row.title ? row.title : (ctx.query || "")
            return bin + "\nif " + mustRunningExpr() + "; then\n  \"$BIN\" playshuffle " + shq(psq) +
                "\nelse\n  " + launchVerb("playshuffle " + shq(psq)) + "\nfi"
        }
        var res = mustResolver(row)
        if (res.length === 0)
            return "exit 1"
        if (action === "play") {
            // not running: ctl `play <path>` auto-starts via resolvePlayQuery,
            // which has NO file-path tier — a path playQuery resolves to nothing
            // (silent empty playlist). Files/dirs instead go as launch args
            // (loadCLIPaths + --play); prefixed resolvers keep the ctl verb.
            var launchArgs
            if ((row.kind === "song" || row.kind === "temp") && row.path)
                launchArgs = shq(row.path) + " --play"
            else if (row.kind === "playlist")
                launchArgs = "play " + shq("playlist:" + String(row.title).replace(/\.(m3u8?|M3U8?)$/, "")) + " --play"
            else
                launchArgs = "play " + res + " --play"
            return bin + "\nif " + mustRunningExpr() + "; then\n  \"$BIN\" play " + res + "\nelse\n  " +
                launchVerb(launchArgs) + "\nfi"
        }
        var verb = action === "enqueue" ? "enqueue" : "enqueue-next"
        return bin + "\nif " + mustRunningExpr() + "; then\n  \"$BIN\" " + verb + " " + res + "\nelse\n  " +
            notify("must not running — started it; try again once it's up") +
            "\n  " + launchVerb("") + "\n  exit 1\nfi"
    }
    // ----- cliamp target -----
    // Empirically pinned on v1.63.2: `queue <file>` appends local files
    // (silent on success); `load <name>` only takes saved playlist names;
    // `cliamp open 'cliamp://play?provider=navidrome&album=<id>'` plays
    // provider content natively; local play = playlist create + load + play.
    var RUNNING = cliampRunningExpr()
    var LAUNCH = "omarchy-launch-tui cliamp"

    if (action === "random-album") {
        // Random local album dir straight out of must's library DB, played
        // through the playlist route (or launch args when not running).
        return "DB=\"$HOME/.cache/must/library.db\"\nRD=$(sqlite3 -readonly \"$DB\" \"SELECT path FROM tracks WHERE path != '' ORDER BY RANDOM() LIMIT 1\" 2>/dev/null)\nRD=$(dirname \"$RD\" 2>/dev/null)\nif [ -z \"$RD\" ] || [ ! -d \"$RD\" ]; then\n  " +
            notify("no local albums found for random") + "\n  exit 1\nfi\nif " + RUNNING + "; then\n  cliamp playlist delete amla-play >/dev/null 2>&1\n  cliamp playlist create amla-play \"$RD\" >/dev/null && cliamp load amla-play >/dev/null && cliamp play >/dev/null\nelse\n  " + LAUNCH + " \"$RD\" --auto-play >/dev/null 2>&1 &\nfi"
    }

    // Local rows: QML passes files=[...] for songs/playlists, expandDir for
    // albums/temp. Subsonic rows arrive as cliamp URIs instead.
    var files = ctx.files || []
    if (files.length === 0 && ctx.expandDir)
        files = ["__DIR__" + ctx.expandDir]

    if (files.length === 1) {
        var f = files[0]
        var isDir = f.indexOf("__DIR__") === 0
        var target = isDir ? f.slice(7) : f
        if (action === "play") {
            var playRoute = "cliamp playlist delete amla-play >/dev/null 2>&1\n  cliamp playlist create amla-play " + shq(target) + " >/dev/null && cliamp load amla-play >/dev/null && cliamp play >/dev/null"
            var playLaunch = isDir ? LAUNCH + " " + shq(target) + " --auto-play >/dev/null 2>&1 &" : LAUNCH + " " + shq(target) + " --auto-play >/dev/null 2>&1 &"
            return "if " + RUNNING + "; then\n  " + playRoute + "\nelse\n  " + playLaunch + "\nfi"
        }
        // enqueue / enqueue-next: queue appends (no insert-next in cliamp CLI).
        return "if " + RUNNING + "; then\n  cliamp queue " + shq(target) + "\nelse\n  " +
            notify("cliamp not running — enqueue needs a running player") + "\n  " + LAUNCH + " >/dev/null 2>&1 &\n  exit 1\nfi"
    }
    if (files.length > 1) {
        var body = ""
        for (var i = 0; i < files.length; i++)
            body += "cliamp queue " + shq(files[i]) + "\n"
        return "if " + RUNNING + "; then\n" + body + "else\n  " +
            notify("cliamp not running — enqueue needs a running player") + "\n  exit 1\nfi"
    }
    if (ctx.uri) {
        var openCmd = "cliamp open " + shq(ctx.uri)
        if (action === "play") {
            return "if " + RUNNING + "; then\n  " + openCmd + "\nelse\n  " + LAUNCH + " open " + shq(ctx.uri) + " >/dev/null 2>&1 &\nfi"
        }
        return "if " + RUNNING + "; then\n  " + openCmd + "\nelse\n  " +
            notify("cliamp not running — enqueue needs a running player") + "\n  " + LAUNCH + " >/dev/null 2>&1 &\n  exit 1\nfi"
    }
    if (ctx.uriLines && ctx.uriLines.length > 0) {
        var ub = ""
        for (var j = 0; j < ctx.uriLines.length; j++)
            ub += "cliamp open " + shq(ctx.uriLines[j]) + "\n"
        return "if " + RUNNING + "; then\n" + ub + "else\n  " +
            notify("cliamp not running — enqueue needs a running player") + "\n  exit 1\nfi"
    }
    return "exit 1"
}
