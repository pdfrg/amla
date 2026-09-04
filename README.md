# amla — Omarchy 4 quickshell music launcher

`SUPER + M` opens a searchable popup over your music catalog: local library,
temp/download albums, and subsonic (Navidrome) — artists, albums, songs,
genres, years/decades, playlists. Favorites learn from your play history and
surface as you type. Everything dispatches to the **must** TUI (primary) or
**cliamp** (alternate).

Rebuild of the retired elephant/walker provider (`~/Work/elephant-music-provider`)
as a pure QML plugin for the Omarchy 4 shell. Plan: `PLAN.md`.

## Keys

| Popup | |
|---|---|
| type | filter (debounced FTS search) |
| `Enter` | play · empty query = play random album |
| `Shift+Enter` / `Ctrl+Enter` | enqueue / play next |
| `Alt+Enter` | playshuffle current query |
| `Shift+Alt+Enter` | enqueue a random result |
| `Alt+R` | play random album (local · temp · subsonic) |
| `Alt+1` / `Alt+2` / `Alt+3` | play random local / subsonic / temp album |
| `Ctrl+R` | rescan + refresh facets + flush art cache |
| `Ctrl+T` | toggle target player (persists) |
| `Esc` | clear query / close |

## Install / develop

The repo is the source of truth; `scripts/install.sh` rsyncs it into
`~/.config/omarchy/plugins/mds.amla` and waits for the shell to reload.
`scripts/warm-art-cache.sh` pre-downloads all Navidrome covers
(`~/.cache/amla/art`) so browsing never waits on the network.

## Data

- History/favorites: `~/.local/state/amla/history.json` (learned from
  launcher plays + MPRIS now-playing)
- Subsonic cover cache: `~/.cache/amla/art/` (`Ctrl+R` flushes)
- Plugin config: `~/.config/amla/config.json` (target player, must binary
  override)
- must's library DB is read-only: `~/.cache/must/library.db` (FTS5)
- Requires must ≥ 0.2.3 for subsonic track (`songid`/`albumid`) and
  subsonic genre/year dispatch; older must still plays local catalog,
  subsonic artists/albums, and everything cliamp-side
