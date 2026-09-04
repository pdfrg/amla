# <img src="icon.png" width="64" align="left"> amla — advanced music launcher

Searchable music launcher plugin for Omarchy 4 (Quattro): `SUPER + M` opens a popup
over your catalog — local library, temp/download albums, and Subsonic
(Navidrome): artists, albums, songs, genres, years/decades, playlists.
Favorites learn from your play history and surface as you type. Dispatches to
**cliamp** (default) or **must** (see below). Pure QML plugin, MIT licensed.

![amla launcher popup](preview.jpg)

## Players: cliamp or must (either one, or try both)

- **cliamp** ships with Omarchy and works out of the box — amla targets it by
  default (requires cliamp v2+ for the `url.load` / `track.*` / `queue.*` IPC
  ops; v1 CLIs differ and are not supported). Play, enqueue, and play-next
  all work; multi-item lists go through generated m3us.
- **[must - music TUI](https://github.com/pdfrg/must)** (≥ 0.2.3) is worth a look:
  library search and browser, album art, artist art, and artist galleries
  (in the terminal), artist bios, and vim-style keybindings. It needs a Go toolchain
  to build, but amla's must support runs deepest — native catalog resolvers,
  playshuffle, scoped random, rescan — because the two were developed
  together. Set it as your target with `Ctrl+T` inside the popup.

A Subsonic/Navidrome server is optional — configure it in must and amla
searches it too; without it amla is local-only and never touches the network.

Standard tools used under the hood: `sqlite3`, `curl`, `notify-send`
(`jq` optional, improves cliamp play-next positioning).

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
- `scripts/warm-art-cache.sh` is optional: it pre-downloads all Navidrome
  covers into `~/.cache/amla/art` so browsing never waits on the network —
  without it, thumbnails simply load on demand when the popup opens

Capabilities, network use, and trust boundaries are disclosed in
[`SECURITY.md`](SECURITY.md).

## Roadmap

- **MPD support** (play/enqueue via `mpc`, Subsonic items through generated
  stream-URL m3us with `#EXTINF` titles — no bridge daemon needed)

## Removal

```sh
omarchy plugin remove io.github.pdfrg.amla
rm -rf ~/.config/amla ~/.local/state/amla ~/.cache/amla   # optional: own state
```

then delete the `SUPER + M` line from `~/.config/hypr/bindings.lua`. No
services, timers, or daemons are installed, so nothing else lingers.

## Credits

Search-palette concept inspired by [Launchy](https://www.launchy.net).

## License

MIT — see [`LICENSE`](LICENSE).
