# Amla — searchable music launcher for the Omarchy shell

`SUPER + M` opens a searchable popup over your music catalog: local library,
temp/download albums, and Subsonic (Navidrome) — artists, albums, songs,
genres, years/decades, playlists. Favorites learn from your play history and
surface as you type. Everything dispatches to the **must** TUI (primary) or
**cliamp** (alternate). Pure QML plugin, MIT licensed.

## Requirements

- Omarchy 4 (Quattro shell) + Quickshell 0.3
- **must** ≥ 0.2.3 (local catalog, temp albums, playlists; provides
  `~/.cache/must/library.db`, scanned at least once)
- **cliamp v2+** (only needed for the cliamp target: IPC ops `url.load`,
  `track.play/queue`, `queue.*`; v1 CLIs differ and are not supported)
- Standard tools: `sqlite3`, `curl`, `notify-send` (`jq` optional, improves
  cliamp play-next positioning)
- A Subsonic/Navidrome server is optional — configure it in must; without it
  Amla is local-only and never touches the network

## Install

From the Omarchy plugin marketplace, or manually:

```sh
omarchy plugin add https://github.com/pdfrg/amla
```

then bind a key (add to `~/.config/hypr/bindings.lua`):

```lua
o.bind("SUPER + M", "Amla", "omarchy-shell shell toggle io.github.pdfrg.amla")
```

and check `hyprctl configerrors` is clean. To update: `omarchy plugin update
io.github.pdfrg.amla` (or pull + reinstall from source).

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

## Data & state

- History/favorites: `~/.local/state/amla/history.json` (learned from
  launcher plays + MPRIS now-playing)
- Subsonic cover cache: `~/.cache/amla/art/` (`Ctrl+R` flushes)
- Plugin config: `~/.config/amla/config.json` (`targetPlayer`, `mustBin` override)
- must's library DB is read-only: `~/.cache/must/library.db` (FTS5)
- `scripts/warm-art-cache.sh` pre-downloads all Navidrome covers
  (`~/.cache/amla/art`) so browsing never waits on the network

Capabilities, network use, and trust boundaries are disclosed in
[`SECURITY.md`](SECURITY.md).

## Removal

```sh
omarchy plugin remove io.github.pdfrg.amla
rm -rf ~/.config/amla ~/.local/state/amla ~/.cache/amla   # optional: own state
```

then delete the `SUPER + M` line from `~/.config/hypr/bindings.lua`. No
services, timers, or daemons are installed, so nothing else lingers.

## License

MIT — see [`LICENSE`](LICENSE).
