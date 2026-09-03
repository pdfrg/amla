// Playback dispatch to must (primary) or cliamp (alternate).
// Pure JS: builds one sh -c script per action; the QML side runs it and
// records history on exit 0.
//
// must resolvers (DOCUMENTATION.md IPC section): /path, playlist:<n>,
// subsonic:<q>, artist:<q>, album:<q>, genre:<q>, year:<y|from-to>, free text.
// must play / playshuffle auto-start the TUI when not running; enqueue does
// not (degrades to launch + notification per plan).
// cliamp v2.0.1 (docs + pinned empirically): V2 IPC via `cliamp remote call
// <op> --params <json> --wait` against ~/.config/cliamp/cliamp.sock.
// url.load resolves a directory (recursive scan, embedded tags), an .m3u
// (relative paths resolved from the file), or a single URL; "play": true
// starts the appended material. track.play plays a supplied track,
// track.queue queues one next, queue appends one path. Op names and params
// are passed through env (AMLA_OP/AMLA_PARAMS/AMLA_M3U) — no shell quoting.

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

    // ----- cliamp target (v2 IPC) -----
    // The QML side sets AMLA_OP, AMLA_PARAMS (JSON) and, for multi-item m3u
    // dispatches, AMLA_M3U (m3u body written to $XDG_RUNTIME_DIR/amla/queue.m3u
    // before the call). ctx.launchTarget is the path/URL handed to a fresh TUI
    // when cliamp is not running (play actions only).
    var RUNNING = cliampRunningExpr()
    var LAUNCH = "omarchy-launch-tui cliamp"
    var RUNTIME_DIR = "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    var runOp = "cliamp remote call \"$AMLA_OP\" --params \"$AMLA_PARAMS\" --wait >/dev/null 2>&1"
    // Play replaces the live playlist (url.load / track.play only append),
    // so clear first. Newline-chained: the load still runs if the clear
    // errors (e.g. empty queue). Enqueue / enqueue-next append by design.
    if (ctx.clearFirst)
        runOp = "cliamp remote call \"queue.clear\" --params \"{}\" --wait >/dev/null 2>&1\n  " + runOp
    var prep = ""
    if (ctx.m3uBody)
        prep = "mkdir -p \"" + RUNTIME_DIR + "/amla\" && printf '%s' \"$AMLA_M3U\" > \"" + RUNTIME_DIR + "/amla/queue.m3u\"\n  "
    var launch
    if (action === "play")
        launch = "  " + LAUNCH + " " + shq(String(ctx.launchTarget || "")) + " --auto-play >/dev/null 2>&1 &"
    else
        launch = "  " + notify("cliamp not running — enqueue needs a running player") + "\n  " + LAUNCH + " >/dev/null 2>&1 &\n  exit 1"
    return "if " + RUNNING + "; then\n  " + prep + runOp + "\nelse\n" + launch + "\nfi"
}
