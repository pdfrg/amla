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
| `/usr/bin/curl` | Subsonic REST (`search3`, `getGenres`, `getAlbumList2`, `getCoverArt`, `stream`) against the server from must's config | credentials via md5 token (see below); `--max-time 5–10` |
| `/usr/bin/sh -c` | glue for multi-step flows (listing temp dirs/playlists, art probing, dispatch scripts) | every interpolated value single-quote wrapped (`shq`) or SQL-quote doubled |
| must binary (config `mustBin`, else `command -v must`) | `play / playshuffle / enqueue / enqueue-next / random / rescan / status` | resolvers built from the selected row; see `Dispatch.js` |
| `/usr/bin/cliamp` (+ `remote call … --wait`) | `status` probe, `url.load`, `track.play/queue`, `queue*` ops | JSON params via env (`AMLA_OP`/`AMLA_PARAMS`/`AMLA_M3U`), never shell-quoted |
| `/usr/share/omarchy/bin/omarchy-launch-tui` | launch must/cliamp TUI when the player isn't running (play actions only) | fixed verbs + quoted resolver |
| `/usr/bin/notify-send` | fallback notices (e.g. "must not running — started it") | static strings only |
| `/usr/bin/{mkdir,rm,ls,find,sed,sort,wc}` | cache/state dir setup, temp-dir listing, art probing | paths single-quote wrapped |

No `sudo`, `pkexec`, `setcap`, package installs, or privilege escalation of
any kind. No compiler, downloader, or runtime dependency beyond the table
plus `jq` (optional, for cliamp insert-next positioning).

## Network

- Only to the Subsonic server configured in `~/.config/must/config.toml`
  (`[subsonic]` url/user/password), and only when `enabled` is set there.
- Auth is Subsonic token auth: `md5(password + per-request salt)` sent as the
  `t=` query param. The password itself never leaves the machine in any form
  except this standard Subsonic hash.
- No telemetry, no other hosts, no listening sockets.

## Files read

- `~/.config/must/config.toml` — `music_dirs`, `temp_dirs`, `[subsonic]`
  credentials (re-read on each popup open).
- `~/.cache/must/library.db` — read-only (`-readonly` flag).
- must temp dirs + playlist dir — directory listings only.
- `~/.config/amla/config.json` — own config (`targetPlayer`, `mustBin`).

## Files written (all under `$HOME`, all documented with undo)

- `~/.config/amla/config.json` — target-player toggle, atomic write.
- `~/.local/state/amla/history.json` — play counts / recency for favorites.
- `~/.cache/amla/art/` — Subsonic cover thumbnails (`size=96`, `Ctrl+R` flushes).
- `$XDG_RUNTIME_DIR/amla/queue.m3u` — staging file for multi-track cliamp dispatch.
- Nothing under `/usr`, `/etc`, `~/.config/hypr/`, or `~/.config/omarchy/` is
  written by the plugin. (The optional `SUPER+M` keybinding below is a manual
  one-line user edit, not plugin code.)

**Removal:** `omarchy plugin remove io.github.pdfrg.amla` (or delete
`~/.config/omarchy/plugins/io.github.pdfrg.amla`), then optionally
`rm -rf ~/.config/amla ~/.local/state/amla ~/.cache/amla` and drop the
keybinding line. No services, timers, or daemons are installed.

## Always-on behavior (`keepLoaded: true`)

- A 3 s MPRIS poll records now-playing metadata into local history only.
- A one-shot ~10 s post-login pre-warm fetches Subsonic facets + empty-state
  art so the first open is fast. No periodic network polling afterwards.

## Known residuals (accepted, documented)

- Child processes inherit the shell environment (Quickshell `Process`); tools
  are absolute-pathed to blunt `PATH` shadowing, and JSON/auth payloads travel
  via env vars rather than argv where practical — but the Subsonic token does
  appear in `curl` argv (visible to same-user `ps`), as with any CLI REST call.
- State files are read/written through Quickshell `FileView` (follows
  symlinks; no `O_NOFOLLOW` primitive exists in QML). Contents are treated as
  data: history entries are only ever rendered as plain text or matched
  against the library, never executed.
