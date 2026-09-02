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
    if (action === "random-album") {
        if (ctx.subsonicRandomM3u) {
            return "if " + cliampRunningExpr() + "; then\n  cliamp load " + shq(ctx.subsonicRandomM3u) + "\nelse\n  " +
                notify("cliamp not running — launch it first for subsonic random") + "\n  exit 1\nfi"
        }
        var findCmd = "find \"$RD\" -maxdepth 1 -type f \\( -name '*.mp3' -o -name '*.flac' -o -name '*.ogg' -o -name '*.m4a' -o -name '*.wav' -o -name '*.opus' \\) -print0 | sort -z | xargs -0 -r -n1 cliamp queue"
        if (ctx.randomDir) {
            return "RD=" + shq(ctx.randomDir) + "\nif " + cliampRunningExpr() + "; then\n  " + findCmd + "\nelse\n  " +
                notify("cliamp not running — launch it first for random album") + "\n  exit 1\nfi"
        }
        // Random local album dir straight out of must's library DB.
        return "DB=\"$HOME/.cache/must/library.db\"\nRD=$(sqlite3 -readonly \"$DB\" \"SELECT path FROM tracks WHERE path != '' ORDER BY RANDOM() LIMIT 1\" 2>/dev/null)\nRD=$(dirname \"$RD\" 2>/dev/null)\nif [ -z \"$RD\" ] || [ ! -d \"$RD\" ]; then\n  " +
            notify("no local albums found for random") + "\n  exit 1\nfi\nif " + cliampRunningExpr() + "; then\n  " + findCmd + "\nelse\n  " +
            notify("cliamp not running — launch it first for random album") + "\n  exit 1\nfi"
    }

    var files = ctx.files || []
    if (files.length === 0 && ctx.expandDir) {
        return "if " + cliampRunningExpr() + "; then\n  find " + shq(ctx.expandDir) + " -maxdepth 1 -type f \\( -name '*.mp3' -o -name '*.flac' -o -name '*.ogg' -o -name '*.m4a' -o -name '*.wav' -o -name '*.opus' \\) -print0 | sort -z | xargs -0 -r -n1 cliamp queue\nelse\n  " +
            notify("cliamp not running — launch it first") + "\n  exit 1\nfi"
    }
    if (files.length === 1) {
        var one = "cliamp queue " + shq(files[0])
        if (action === "play") {
            return "if " + cliampRunningExpr() + "; then\n  " + one + "\nelse\n  " +
                notify("cliamp not running — starting it") + "\n  omarchy-launch-tui cliamp >/dev/null 2>&1 &\n  sleep 1\n  " + one + " || true\nfi"
        }
        return "if " + cliampRunningExpr() + "; then\n  " + one + "\nelse\n  " +
            notify("cliamp not running — enqueue needs a running player") + "\n  exit 1\nfi"
    }
    if (files.length > 0) {
        var body = ""
        for (var i = 0; i < files.length; i++)
            body += "cliamp queue " + shq(files[i]) + "\n"
        return "if " + cliampRunningExpr() + "; then\n" + body + "else\n  " +
            notify("cliamp not running — enqueue needs a running player") + "\n  exit 1\nfi"
    }
    if (ctx.m3uPath) {
        return "if " + cliampRunningExpr() + "; then\n  cliamp load " + shq(ctx.m3uPath) + "\nelse\n  " +
            notify("cliamp not running — launch it first") + "\n  exit 1\nfi"
    }
    return "exit 1"
}
