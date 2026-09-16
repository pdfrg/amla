# SECURITY.md — amla capability and trust-boundary disclosure

amla (`io.github.pdfrg.amla`) is a Quickshell `menu` plugin. Like all Omarchy
plugins it runs **unsandboxed inside the long-running shell process with your
user permissions**. This file lists everything it can do, so reviewers and
users don't have to take that on faith.

## Subprocesses (all one-shot, none detached except noted)

Every tool is invoked by **absolute path**. `sqlite3` one-shots are wrapped
in `/usr/bin/timeout --kill-after=5 15`; `curl` calls carry `--max-time`.
Metadata-bearing `Text` sinks render as `Text.PlainText`.

| Tool | Purpose | Input shaping |
|---|---|---|
| `/usr/bin/sqlite3 -readonly` | read-only queries over must's `library.db` (FTS5 + aggregates) | user query → FTS `MATCH` (quotes doubled) / `LIKE` (wildcards escaped); never writes |
| `/usr/bin/curl` | Subsonic REST (`search3`, `getGenres`, `getAlbumList2`, `getCoverArt`) against the server from must's config | **POST**: auth + params travel in the form body, fed from a private env var into curl's stdin — never in argv and never in the URL; `--max-time 5–10` + `--max-filesize` (2 MiB JSON endpoints, 1 MiB cover art) so a faulty server can't flood the pipe |
| `/usr/bin/python3 <plugindir>/subsonic_broker.py` | **the stream broker**: holds the Subsonic credentials so players never see them. Serves `GET\|HEAD /<32-hex capability>/s/<songId>` (and `/<capability>/health?t=<token>`, this instance's own identity check) on 127.0.0.1, and proxies to `/rest/stream` with auth in a POST body | two route shapes only, with strict prefix compare, id charset/length (`[A-Za-z0-9._-]{1,64}`), no query strings on the stream route, GET/HEAD only; same-origin-only redirects (≤3 hops); 1 GiB response cap and 20 s upstream timeout; Range forwarded (206); Subsonic error payloads surfaced as 502 rather than streamed as audio; **at most 8 concurrent streams** with excess refused immediately (503) and a write deadline for stalled readers; single instance enforced by an exclusive lock whose type/owner are checked and whose mode is repaired to 0600; state written through a random `O_CREAT\|O_EXCL\|O_NOFOLLOW` same-directory temporary, fsynced, renamed via a directory fd, and refused if the destination is not a regular file we own; state *read* (by `--read-state`) bounded, no-follow, regular-file/owner/0600 checked; no request logging |
| `/usr/bin/sh -c` | glue for multi-step flows (listing temp dirs/playlists, art probing, dispatch scripts) | every interpolated value single-quote wrapped (`shq`) or SQL-quote doubled |
| must binary (config `mustBin`, else `command -v must`) | `play / playshuffle / enqueue / enqueue-next / random / rescan / status` | resolvers built from the selected row; see `Dispatch.js` |
| `/usr/bin/cliamp` (+ `remote call … --wait`) | `status` probe, `url.load`, `track.play/queue`, `queue*` ops | JSON params via env (`AMLA_OP`/`AMLA_PARAMS`/`AMLA_M3U`), never shell-quoted |
| `/usr/bin/mpc` | MPD reachability probe (`status` only — queueing goes through the helper below, since `mpc` over TCP cannot touch local files) | host/port from plugin config, else its own `localhost:6600` default |
| `/usr/bin/python3 <plugindir>/mpd_queue.py` | MPD queue updates over one TCP connection (`clear`, `addid` + position, `addtagid`, `random`, `shuffle`, `play`) | staged `$XDG_RUNTIME_DIR/amla/mpd_queue.json` (argv: host/port/queue-file/strip-prefixes/flags); absolute paths strip to music-relative via longest configured music-root prefix, stream URLs pass through |
| `/usr/share/omarchy/bin/omarchy-launch-tui` | launch must/cliamp TUI when the player isn't running (play actions only) | fixed verbs + quoted resolver |
| `/usr/bin/notify-send` | fallback notices (e.g. "must not running — started it") | static strings only |
| `/usr/bin/python3 <plugindir>/index-library.py` | background tag scan over the music roots into amla's own `files.db` (mutagen → ffprobe → filename ladder, one run at a time, incremental; no timeout — a cold scan of a huge library runs minutes) | roots passed as argv (visible to same-user `ps`, same residual as below); tags parsed from file bytes, never executed |
| `ffprobe` (bare name, only if the user installed it) | tag reader rung inside the script above: `-v quiet -print_format json -show_format <path>`, per-file 30 s timeout | **not** absolute-pathed — resolved via `PATH`, so the shell-env residual below applies fully; JSON output parsed, never executed |
| `/usr/bin/{mkdir,rm,ls,find,sed,sort,wc}` | cache/state dir setup, temp-dir listing, art probing | paths single-quote wrapped |
| `scripts/warm-art-cache.sh` (manual, user-run, never auto-executed) | pre-downloads Navidrome covers into `~/.cache/amla/art` | reads must `[subsonic]` creds, token auth like the plugin |
| `<plugindir>/rmpc_art.py` (runs under rmpc, never spawned by amla) | `album_art.custom_loader` hook: Subsonic stream covers for rmpc | song id parsed from `$FILE` stream URL; creds mirror pickSubsonic (must → cliamp → amla-owned), sent as **POST form bodies** (never in URLs); same-origin redirect policy (≤3 hops, blocks cross-origin token leaks), Content-Type checked before reading, Content-Length pre-check + streaming MAX+1 caps (256 KiB JSON, 10 MiB images), header-parsed dimension cap 4096px; always exits 0, `fallback` on any failure |

No `sudo`, `pkexec`, `setcap`, package installs, or privilege escalation of
any kind. No compiler, downloader, or runtime dependency beyond the table
plus `jq` (optional, for cliamp insert-next positioning) and the optional,
user-installed tag readers `python-mutagen` / `ffmpeg` — amla only detects
them read-only and never installs anything.

## Network

- Only to the Subsonic server resolved must `[subsonic]` → cliamp
  `[navidrome]` → amla's own `subsonicUrl/User/Pass` (first URL wins;
  must additionally requires `enabled`), and only for Subsonic rows,
  facets, and artwork.
- Auth is Subsonic token auth: `md5(password + client-chosen salt)`. That
  value is password-equivalent (the server just recomputes it, so a captured
  `u`/`t`/`s` triple is replayable indefinitely), which is why amla keeps it
  out of argv, out of request URLs, and out of every URL handed to a player.
  The password itself never leaves the machine in any form except this
  standard Subsonic hash.
- The stream broker (below) binds **127.0.0.1 on an ephemeral port** -- the
  only listening socket amla owns. It accepts three things: its own
  unguessable 32-hex path prefix, one `s/<songId>` segment, and GET/HEAD.
  Everything else is refused.
- No telemetry, no other hosts.

## Files read

- `~/.config/amla/config.json` — own config (`targetPlayer`, `mustBin`,
  `musicDirs`, `tempDirs`, `bucketWords`, `noiseTokens`, `mpdHost/Port`,
  `subsonicUrl/User/Pass`, `debugNoMust`). Re-read at shell start
  (external edits need a restart).
- `~/.config/cliamp/config.toml` — `initial_directory` (music-root hint)
  and `[navidrome]` credentials (URL counts as enabled; `${VAR}` expanded).
- `~/.config/must/config.toml` — `music_dirs`, `temp_dirs`, `[subsonic]`
  credentials (re-read on each popup open).
- `~/.cache/must/library.db` — read-only (`-readonly` flag).
- must temp dirs + playlist dir — directory listings only.
- Music roots (audio files) — tag bytes read by the index builder; filenames
  parsed for artist/album/title on the zero-dependency tier.

## Files written (all under `$HOME`, all documented with undo)

- `~/.config/amla/config.json` — target-player toggle, atomic write.
- `~/.local/state/amla/history.json` — play counts / recency for favorites.
- `~/.cache/amla/art/` — Subsonic cover thumbnails (`size=96`, `Ctrl+R` flushes).
- `~/.cache/amla/files.db*` — amla-owned file index (songs + FTS5, WAL mode).
- `~/.cache/amla/broker.json` — the stream broker's `{pid, port, prefix,
  token}` (0600; `token` is a per-start identity value for the readiness
  probe, not a credential), plus `broker.json.lock` (0600, exclusive-lock
  file). No credentials: the helper reads those from the spawn environment
  only.
- `$XDG_RUNTIME_DIR/amla/` — owner-only (0700) staging dir, `umask 077` on
  shell writes. It holds dispatch handoff files that can contain Subsonic
  stream URLs (password-equivalent while they live), on tmpfs:
  `queue.m3u` (multi-track cliamp), `mpd_queue.json` (MPD track URIs + tags +
  per-dispatch serial), `subpl.m3u` (server playlists).
- Nothing under `/usr`, `/etc`, `~/.config/hypr/`, or `~/.config/omarchy/` is
  written by the plugin. (The optional `SUPER+M` keybinding below is a manual
  one-line user edit, not plugin code.)

**Removal:** `omarchy plugin remove io.github.pdfrg.amla` (or delete
`~/.config/omarchy/plugins/io.github.pdfrg.amla`), then optionally
`rm -rf ~/.config/amla ~/.local/state/amla ~/.cache/amla` and drop the
keybinding line. One user-scope helper runs while you are logged in (the
stream broker below); it exits with the session and installs nothing.

## Always-on behavior (`keepLoaded: true`)

- A 3 s MPRIS poll records now-playing metadata into local history only.
- A one-shot ~10 s post-login pre-warm fetches Subsonic facets + empty-state
  art so the first open is fast. No periodic network polling afterwards.
- With no must DB present, the first popup open (or pre-warm) also triggers
  a background `index-library.py` run to build the file index.
- The **stream broker** is spawned when Subsonic credentials are known (at
  load, and again on demand) and kept alive for the session by a 60 s
  liveness probe, because players hold its URLs in queues that outlive a
  single dispatch. It does no work while idle (blocking accept, zero CPU) and
  exits with the session. It reuses the port and capability recorded in
  `~/.cache/amla/broker.json` so URLs already queued by a player keep
  resolving across a respawn; if that port is taken it falls back to a fresh
  one and says so.

## Known residuals (accepted, documented)

- Secrets travel through the process **environment**, never argv:
  `/proc/<pid>/cmdline` is world-readable, while `/proc/<pid>/environ` is
  readable only by the same user (and root). amla's own Subsonic calls POST
  their auth body from an env var into `curl`'s stdin, so the token appears in
  neither argv nor the request URL. Tools are absolute-pathed to blunt `PATH`
  shadowing.
- Players never receive a Subsonic stream URL. They receive a broker URL
  (`http://127.0.0.1:<port>/<capability>/s/<id>`) built by `subsonic_broker.py`,
  so the credential stays in the helper's memory (and in the plugin's private
  env when the helper is spawned) instead of landing in MPD's queue/state file,
  cliamp's queue/`resume.json`, or either player's log.
- Residual: that broker URL **is** a capability. MPD persists it (queue and
  state file, mode 0644 by MPD's own default) and logs it, so another local
  user who reads those files could stream that one song through the broker
  while it runs. Bounded: loopback only, one song id, no account credential,
  nothing reusable offline, and dead once the helper exits. Clearing the
  broker's routing would gain nothing (there is no mapping table — the route
  *is* the song id, and nothing else is accepted).
- Residual: MPD's own queue and state file may still contain direct Subsonic
  URLs from before this broker existed. Those are ordinary queued entries to
  MPD; `mpc clear` removes them.
- State files are read/written through Quickshell `FileView` (follows
  symlinks; no `O_NOFOLLOW` primitive exists in QML). Contents are treated as
  data: history entries are only ever rendered as plain text or matched
  against the library, never executed.
