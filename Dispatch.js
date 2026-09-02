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

function mustBinScript(configOverride) {
    if (configOverride && String(configOverride).length > 0)
        return String(configOverride)
    return "BIN=$(command -v must || true); [ -z \"$BIN\" ] && BIN=\"$HOME/Work/must/must\"; true"
}

// must ctl socket per DOCUMENTATION.md: $XDG_RUNTIME_DIR/must/ctl.sock
function mustRunningExpr() {
    return "[ -S \"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/must/ctl.sock\" ]"
}

function cliampRunningExpr() {
    return "[ -S \"$HOME/.config/cliamp/cliamp.sock\" ]"
}

// Resolver argument for must, per row kind.
function mustResolver(row, configOverride) {
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
        if (action === "random-album") {
            return bin + "\nif " + mustRunningExpr() + "; then\n  \"$BIN\" random\nelse\n  " +
                notify("must not running — launch it first for random album") + "\n  exit 1\nfi"
        }
        if (action === "playshuffle") {
            var psq = row && row.kind !== "action" && row.title ? row.title : (ctx.query || "")
            return bin + "\n\"$BIN\" playshuffle " + shq(psq)
        }
        var res = mustResolver(row, ctx.mustBin)
        if (res.length === 0)
            return "exit 1"
        var verb = action === "play" ? "play" : (action === "enqueue" ? "enqueue" : "enqueue-next")
        var head = bin + "\nif " + mustRunningExpr() + "; then\n  \"$BIN\" " + verb + " " + res + "\nelse\n"
        if (action === "play")
            // must play auto-starts the TUI with the resolver (DOCUMENTATION.md).
            return head + "  \"$BIN\" play " + res + "\nfi"
        return head + "  " + notify("must not running — enqueue needs a running player") +
            "\n  omarchy-launch-tui must >/dev/null 2>&1 &\n  exit 1\nfi"
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
