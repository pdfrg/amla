// Playback dispatch to must (primary) or cliamp (alternate).
// Pure JS: builds one sh -c script per action; the QML side runs it and
// records history on exit 0.
//
// must resolvers (DOCUMENTATION.md IPC section): /path, playlist:<n>,
// subsonic:<q>, artist:<q>, album:<q>, genre:<q>, year:<y|from-to>, free text.
// must play / playshuffle auto-start the TUI when not running; enqueue does
// not (degrades to launch + notification per plan).
// cliamp v2.0.1 (docs + pinned empirically): V2 IPC via `/usr/bin/cliamp remote call
// <op> --params <json> --wait` against ~/.config/cliamp/cliamp.sock.
// url.load resolves a directory (recursive scan, embedded tags), an .m3u
// (relative paths resolved from the file), or a single URL; "play": true
// starts the appended material. track.play appends a supplied track and
// plays it, track.queue appends one with metadata (single-song
// enqueue-next, then moved after the current track), queue appends one bare
// path, queue.clear / queue.list / queue.move
// implement clear-first play and must-style insert-next (jq required for
// the latter, graceful append fallback without it). Op names and params
// are passed through env (AMLA_OP/AMLA_PARAMS/AMLA_M3U) — no shell quoting.

function shq(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
}

// Shared must-binary-not-found notification fragment (module scope: used by
// mustBinScript's generated scripts).
var NOTIFY_BIN = "/usr/bin/notify-send -a amla 'amla' 'must binary not found — install it (e.g. to ~/.local/bin) or set mustBin in ~/.config/amla/config.json' >/dev/null 2>&1 &"

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
    return "/usr/bin/cliamp status >/dev/null 2>&1"
}

// Resolver argument for must, per row kind.
function mustResolver(row) {
    if (!row)
        return ""
    switch (row.kind) {
    case "song":
    case "playlist":
    case "temp":
    case "library":
        return shq(row.path || row.title || "")
    case "subsonic-song":
        if (row.id && String(row.id).length > 0)
            return "subsonic:songid:" + shq(row.id)
        if (row.path && row.path.length > 0)
            return shq(row.path)
        return "subsonic:song:" + shq(row.titleField || row.title)
    case "album":
        return "album:" + shq(row.album || row.title)
    case "subsonic-album":
        if (row.id && String(row.id).length > 0)
            return "subsonic:albumid:" + shq(row.id)
        return "subsonic:album:" + shq(row.album || row.title)
    case "artist":
        return "artist:" + shq(row.title)
    case "subsonic-artist":
        return "subsonic:artist:" + shq(row.title)
    case "genre":
        return "genre:" + shq(row.title)
    case "subsonic-genre":
        return "subsonic:genre:" + shq(row.title)
    case "year":
        return "year:" + shq(row.title)
    case "subsonic-year":
        return "subsonic:year:" + shq(row.title)
    case "decade":
        return "year:" + row.decade + "-" + (row.decade + 9)
    case "subsonic-decade":
        return "subsonic:year:" + row.decade + "-" + (row.decade + 9)
    default:
        return ""
    }
}

// One sh -c script performing the action end to end (running check, dispatch,
// launch fallback, notification). exit 0 = success (history records).
function build(action, row, target, ctx) {
    var notify = function (msg) {
        return "/usr/bin/notify-send -a amla " + shq("amla") + " " + shq(msg) + " >/dev/null 2>&1 &"
    }
    var bin = mustBinScript(ctx.mustBin)

    if (target === "must") {
        // not running → launch the verb inside a fresh terminal: auto-start
        // needs a TTY (from the plugin's headless Process it fails with
        // "bubbletea: error opening TTY"), and omarchy-launch-tui is a
        // passthrough, so pass the resolved binary path.
        var launchVerb = function (args) {
            return "/usr/share/omarchy/bin/omarchy-launch-tui --app-id=must.large \"$BIN\" " + args + " >/dev/null 2>&1 &"
        }
        if (action === "random-album" || action === "random-album-local" || action === "random-album-subsonic" || action === "random-album-temp") {
            var scope = action === "random-album" ? "" : action.substring("random-album-".length)
            var randArgs = scope.length > 0 ? "random " + scope : "random"
            return bin + "\nif " + mustRunningExpr() + "; then\n  \"$BIN\" " + randArgs + "\nelse\n  " + launchVerb(randArgs) + "\nfi"
        }
        if (action === "playshuffle") {
            var psq = row && row.kind !== "action" && row.title ? row.title : (ctx.query || "")
            // Playlist rows shuffle their own contents: must's ctlPlay
            // shuffles whatever it resolves, so hand it the playlist
            // resolver (saved name) or the synthesized m3u (toml source)
            // instead of a free-text query, which would FTS-miss.
            var psArgs = "playshuffle " + shq(psq)
            if (row && (row.kind === "playlist" || row.kind === "subsonic-playlist")) {
                if (ctx.resolvedM3u)
                    psArgs = "playshuffle " + shq(ctx.resolvedM3u)
                else if (row.kind === "playlist" && row.source !== "cliamp")
                    psArgs = "playshuffle " + shq("playlist:" + String(row.title).replace(/\.(m3u8?|M3U8?)$/, ""))
            }
            return bin + "\nif " + mustRunningExpr() + "; then\n  \"$BIN\" " + psArgs +
                "\nelse\n  " + launchVerb(psArgs) + "\nfi"
        }
        var res = mustResolver(row)
        // toml playlists reach must as a synthesized m3u (must cannot
        // read cliamp's format); the QML side resolves it first.
        if (row && (row.kind === "playlist" || row.kind === "subsonic-playlist") && ctx.resolvedM3u)
            res = shq(ctx.resolvedM3u)
        if (res.length === 0)
            return "exit 1"
        if (action === "play") {
            // not running: ctl `play <path>` auto-starts via resolvePlayQuery,
            // which has NO file-path tier — a path playQuery resolves to nothing
            // (silent empty playlist). Files/dirs instead go as launch args
            // (loadCLIPaths + --play); prefixed resolvers keep the ctl verb.
            var launchArgs
            if (ctx.resolvedM3u && (row.kind === "playlist" || row.kind === "subsonic-playlist"))
                launchArgs = shq(ctx.resolvedM3u) + " --play"
            else if ((row.kind === "song" || row.kind === "temp" || row.kind === "library") && row.path)
                launchArgs = shq(row.path) + " --play"
            else if (row.kind === "playlist")
                launchArgs = "play " + shq("playlist:" + String(row.title).replace(/\.(m3u8?|M3U8?)$/, "")) + " --play"
            else
                launchArgs = "play " + res + " --play"
            // Pin shuffle explicitly off after a running play: must persists
            // shuffle in its state file and ctlPlay keeps it, so a previous
            // playshuffle would otherwise leak into this play, even across
            // restarts. Play's own status decides history. Cold launch needs
            // nothing: auto-start builds shuffleMode from the verb
            // (playshuffle/--shuffle → on, plain play → off).
            return bin + "\nif " + mustRunningExpr() + "; then\n  \"$BIN\" play " + res + "\n  ST=$?\n  \"$BIN\" shuffle off >/dev/null 2>&1\n  exit $ST\nelse\n  " +
                launchVerb(launchArgs) + "\nfi"
        }
        var verb = action === "enqueue" ? "enqueue" : "enqueue-next"
        return bin + "\nif " + mustRunningExpr() + "; then\n  \"$BIN\" " + verb + " " + res + "\nelse\n  " +
            notify("must not running — started it; try again once it's up") +
            "\n  " + launchVerb("") + "\n  exit 1\nfi"
    }

    // ----- cliamp target (v2 IPC) -----
    // Requires cliamp v2+ (`remote call` IPC). Older v1 binaries lack the
    // `remote` subcommand, so probe for it up front and notify instead of
    // failing silently: the catalog stays browsable, playback just needs
    // v2 (or must via Ctrl+T). The QML side sets AMLA_OP, AMLA_PARAMS (JSON) and, for multi-item m3u
    // dispatches, AMLA_M3U (m3u body written to $XDG_RUNTIME_DIR/amla/queue.m3u
    // before the call). ctx.launchTarget is the path/URL handed to a fresh TUI
    // when cliamp is not running (play actions only).
    var RUNNING = cliampRunningExpr()
    var LAUNCH = "/usr/share/omarchy/bin/omarchy-launch-tui cliamp"
    var RUNTIME_DIR = "${XDG_RUNTIME_DIR:-/run/user/$(/usr/bin/id -u)}"
    var runOp = "/usr/bin/cliamp remote call \"$AMLA_OP\" --params \"$AMLA_PARAMS\" --wait >/dev/null 2>&1"
    // Play replaces the live playlist (url.load / track.play only append),
    // so clear first. Newline-chained: the load still runs if the clear
    // errors (e.g. empty queue). Enqueue / enqueue-next append by design.
    if (ctx.clearFirst)
        runOp = "/usr/bin/cliamp remote call \"queue.clear\" --params \"{}\" --wait >/dev/null 2>&1\n  " + runOp
    // must-style insert-next: snapshot the current track (navidrome id when
    // present, else path) and the queue length, append via the op, then move
    // the appended range to right after the current track (ascending moves
    // preserve order). Id match survives salted stream-URL re-mints (each
    // dispatch mints fresh auth salts, so exact path match fails for
    // subsonic); path match covers local files. queue.list's own index only
    // reflects load/play ops, so match against the post-load list instead.
    // No jq, or no match (stopped) → plain append. Enqueue appends by
    // design (no flag). The load op's own status is the script's exit
    // status, so history only records real plays.
    if (ctx.insertNext) {
        runOp = "if [ -x /usr/bin/jq ] || command -v jq >/dev/null 2>&1; then SNAP=$(/usr/bin/cliamp remote call \"runtime.snapshot\" --params '{}' --wait 2>/dev/null)\n    P=$(printf '%s' \"$SNAP\" | /usr/bin/jq -r '.snapshot.track.path // empty')\n    SUBID=$(printf '%s' \"$SNAP\" | /usr/bin/jq -r '.snapshot.track.provider_meta.\"navidrome.id\" // empty')\n    N0=$(/usr/bin/cliamp remote call \"queue.list\" --params '{\"limit\":1}' --wait 2>/dev/null | /usr/bin/jq -r '.job.result.total // 0')\n  else P=\"\"\n    SUBID=\"\"\n    N0=0\n  fi\n  " + runOp +
            "\n  OP_STATUS=$?\n  CUR=\"\"\n  if [ -n \"$SUBID\" ]; then CUR=$(/usr/bin/cliamp remote call \"queue.list\" --params '{\"limit\":5000}' --wait 2>/dev/null | /usr/bin/jq -r --arg id \"$SUBID\" '.job.result.tracks | to_entries | map(select(.value.provider_meta.\"navidrome.id\" == $id)) | .[0].key // empty')\n  elif [ -n \"$P\" ]; then CUR=$(/usr/bin/cliamp remote call \"queue.list\" --params '{\"limit\":5000}' --wait 2>/dev/null | /usr/bin/jq -r --arg p \"$P\" '.job.result.tracks | to_entries | map(select(.value.path == $p)) | .[0].key // empty')\n  fi\n  if [ -n \"$CUR\" ]; then\n    N1=$(/usr/bin/cliamp remote call \"queue.list\" --params '{\"limit\":1}' --wait 2>/dev/null | /usr/bin/jq -r '.job.result.total // 0')\n    T=$((CUR + 1))\n    I=$((N0 + 0))\n    N1=$((N1 + 0))\n    while [ \"$I\" -lt \"$N1\" ]; do\n      /usr/bin/cliamp remote call \"queue.move\" --params \"{\\\"index\\\":$I,\\\"to\\\":$T}\" --wait >/dev/null 2>&1\n      I=$((I + 1))\n      T=$((T + 1))\n    done\n  fi\n  exit $OP_STATUS"
    }
    // playshuffle: the load above replaced the playlist; switch shuffle
    // explicitly on (not a toggle) so the fresh material plays shuffled.
    // The load's own status (not shuffle's) is what history records.
    if (ctx.shuffleAfter)
        runOp += "\n  OP_STATUS=$?\n  /usr/bin/cliamp remote call \"shuffle\" --params '{\"name\":\"on\"}' --wait >/dev/null 2>&1\n  exit $OP_STATUS"
    // Plain play means in-order: cliamp persists shuffle to config.toml on
    // every toggle, so a leftover shuffle=on would otherwise survive
    // restarts and shuffle the next play. Idempotent (op only toggles when
    // needed); load status still decides history. Enqueue paths never set
    // this — they must not disturb the running order.
    else if (ctx.shuffleOffAfter)
        runOp += "\n  OP_STATUS=$?\n  /usr/bin/cliamp remote call \"shuffle\" --params '{\"name\":\"off\"}' --wait >/dev/null 2>&1\n  exit $OP_STATUS"
    var prep = ""
    if (ctx.m3uBody)
        prep = "/usr/bin/mkdir -p \"" + RUNTIME_DIR + "/amla\" && printf '%s' \"$AMLA_M3U\" > \"" + RUNTIME_DIR + "/amla/queue.m3u\"\n  "
    // Capability guard first (before any m3u prep): missing binary, or v1
    // without `remote`. Notifies and fails so history never records a no-op.
    var guard = "if [ ! -x /usr/bin/cliamp ] && ! command -v cliamp >/dev/null 2>&1; then\n  " + notify("amla: cliamp not found — install it (check options with yay -Ss cliamp) or press Ctrl+T for must") + "\n  exit 1\nfi\nif ! /usr/bin/cliamp remote --help >/dev/null 2>&1 && ! cliamp remote --help >/dev/null 2>&1; then\n  " + notify("amla: cliamp v2+ required for playback — upgrade cliamp (check options with yay -Ss cliamp). Catalog still browsable; or press Ctrl+T for must") + "\n  exit 1\nfi\n"
    var launch
    if (action === "play" && ctx.plName)
        // Native toml load: the cold TUI opens directly on the named
        // playlist (--shuffle/--no-shuffle mirrors the running path's
        // explicit pin, since cliamp persists shuffle to config.toml).
        launch = "  " + LAUNCH + " --playlist " + shq(String(ctx.plName)) + " --auto-play " + (ctx.shuffleAfter ? "--shuffle" : "--no-shuffle") + " >/dev/null 2>&1 &"
    else if (action === "play" && String(ctx.launchTarget || "").length > 0)
        // --no-shuffle: cold launch must not inherit persisted shuffle=on
        // from config.toml (see shuffleOffAfter above for the running case).
        // Cold playshuffle (ctx.shuffleAfter) launches shuffled instead.
        launch = "  " + LAUNCH + " " + shq(String(ctx.launchTarget || "")) + " --auto-play " + (ctx.shuffleAfter ? "--shuffle" : "--no-shuffle") + " >/dev/null 2>&1 &"
    else if (action === "play" && ctx.coldSilent)
        // Caller handles the cold case itself (QML fallback fetching
        // playable material first): fail quietly so no bare player
        // opens and no misleading notification fires before the retry.
        launch = "  exit 1"
    else if (action === "play")
        // Native provider loads have no path/URL to hand a fresh TUI (e.g.
        // provider.load_album): start it bare and ask for a retry, mirroring
        // the must enqueue fallback. No history (exit 1).
        launch = "  " + notify("/usr/bin/cliamp not running — started it; try again once it's up") + "\n  " + LAUNCH + " >/dev/null 2>&1 &\n  exit 1"
    else
        // Enqueue / enqueue-next with a stopped player: notify only, do NOT
        // launch. A cold launch seeds the queue with the startup provider
        // (radio), so auto-opening would either strand the item appended to
        // radio stations or need a retry dance. must keeps its launch+retry
        // fallback (its playlist persists); cliamp stays closed until the
        // user starts it with play / playshuffle / random-album.
        launch = "  " + notify("cliamp not running — enqueue needs a running player; use play to start it") + "\n  exit 1"
    // The m3u (when any) is written before the branch, so a not-running play
    // can launch the TUI directly on the file — cliamp resolves local m3u
    // argv entries itself. Facet paths whose file already exists (sqlite
    // resolve) pass no m3uBody and are unaffected.
    return guard + prep + "if " + RUNNING + "; then\n  " + runOp + "\nelse\n" + launch + "\nfi"
}
