# Music CLI UX Redesign

Smart defaults for common operations, interactive TUI for browsing, machine output for Claude/scripting.

## Design Principles

1. **Bare browsing command = interactive.** Commands that produce lists (`speaker`, `similar`, `suggest`, `volume`, `playlist`) launch TUI mode when invoked with no args. Action commands (`play`, `pause`, `stop`, `now`) keep their current bare behavior.
2. **Args = non-interactive.** Positional args trigger smart parsing, print result, exit.
3. **`--json` = machine output.** Structured JSON for the Claude skill layer. Never shown to humans.
4. **Named flags stay.** `--song`, `--artist`, `--limit` etc. remain for precise scripting control.
5. **Current subcommands become hidden aliases.** `speaker set`, `speaker add`, `speaker remove` still work for backwards compatibility with the skill, but aren't the primary UX.

## Result Cache

Two domain-specific cache files prevent cross-domain index collisions:

- **Songs:** `~/.config/music/last-songs.json`
  - **Written by:** `search`, `similar`, `suggest`, `new-releases`
  - **Read by:** `play <N>`, `add <N>`, `playlist add "Name" 1 3 5`, `playlist create "Name" 1 3 5`
  - **Schema per entry:** `{ index, title, artist, album, catalogId }`

- **Speakers:** `~/.config/music/last-speakers.json`
  - **Written by:** `speaker list`, `speaker` (interactive TUI on exit)
  - **Read by:** `speaker 1 2 5`
  - **Schema per entry:** `{ index, name, selected, volume }`

- **Lifecycle:** Each file is overwritten when its domain produces new results. No history, just last results.
- **Safety:** `play <N>` only reads from `last-songs.json`. `speaker <N>` only reads from `last-speakers.json`. A command never reads from the wrong domain's cache.

## Speaker Commands

| Command | Effect |
|---|---|
| `music speaker` | Interactive TUI: browse speakers, space to toggle, arrows to navigate |
| `music speaker list` | Non-interactive list (scripting/Claude) |
| `music speaker kitchen` | Add kitchen to active speakers |
| `music speaker kitchen 40` | Add kitchen and set its volume to 40 |
| `music speaker kitchen stop` | Remove kitchen from active speakers |
| `music speaker airpods only` | Deselect all, then select only airpods |
| `music speaker 1 2 5` | Add speakers by index from last `speaker list` |

### Positional Parsing Rules

Arguments are parsed left to right:

1. If all args are integers: index references from last `speaker list` results. Add each speaker.
2. Otherwise, last arg is checked for keywords:
   - `stop` -> remove the named speaker (all preceding args = speaker name)
   - `only` -> deselect all speakers, then select only the named speaker
   - Integer (0-100) -> set volume for the named speaker (all preceding args = speaker name)
   - Anything else -> all args joined = speaker name, add to active speakers
3. Speaker names use case-insensitive prefix matching (e.g. `kitchen` matches `Kitchen HomePod`).

### Backwards Compatibility

The current subcommands remain as hidden aliases:
- `music speaker set <name>` -> same as `<name> only`
- `music speaker add <name>` -> same as `<name>`
- `music speaker remove <name>` -> same as `<name> stop`
- `music speaker stop <name>` -> same as `<name> stop`

## Play Command

| Command | Effect |
|---|---|
| `music play` | Resume playback |
| `music play 3` | Play result #3 from last results cache |
| `music play "Working Vibes"` | Play playlist by name |
| `music play "Working Vibes" shuffle` | Play playlist with shuffle enabled |
| `music play --song "name"` | Search library, play first match (existing) |
| `music play --song "name" --artist "artist"` | Search with artist filter (existing) |

### Positional Parsing Rules

1. If single integer arg: look up index from last results cache, play that track.
2. If last arg is `shuffle`: enable shuffle, treat remaining args as playlist name.
3. Otherwise: join all args as playlist name, play it.
4. No args: resume current playback.

Speaker routing is NOT handled by `play`. Use `music speaker kitchen && music play` or let the Claude skill chain commands. This avoids ambiguity between playlist names and speaker names.

## Search / Similar / Discovery

### Non-Interactive (with args or flags)

| Command | Effect |
|---|---|
| `music search house` | Numbered results list |
| `music similar "Song" "Artist"` | Numbered similar tracks |
| `music similar --limit 20` | Non-interactive list with limit |
| `music suggest 5` | Numbered suggestions (count arg forces non-interactive) |
| `music suggest --from "Playlist"` | Suggestions seeded from playlist (flag forces non-interactive) |

All result-producing commands write to the result cache.

### Interactive (bare command, no args)

| Command | Effect |
|---|---|
| `music similar` | Find tracks similar to current song, display in interactive TUI |
| `music suggest` | Fetch suggestions, display in interactive TUI |

Bare `similar` and `suggest` still fetch results (based on current track / listening history), but display them in the interactive browser instead of printing a numbered list. Adding `--limit`, `--json`, or `--from` forces non-interactive output.

### Interactive TUI Controls

- Arrow up/down: navigate results
- Space: select/deselect track (multi-select)
- `p`: play highlighted track
- `a`: add highlighted/selected to library
- `c`: create playlist from selected tracks (prompts for name)
- `q`: quit

### Acting on Last Results (Non-Interactive)

| Command | Effect |
|---|---|
| `music play 3` | Play result #3 |
| `music add 3` | Add result #3 to library |
| `music playlist add "House" 1 3 5` | Add results 1, 3, 5 to playlist |
| `music playlist create "House" 1 3 5` | Create playlist from results |

## Playlist & Library Shortcuts

### Top-Level `add` and `remove`

The existing `music add <query>` command (catalog search + add to library) remains unchanged. The new playlist shortcuts use a `--to` flag to avoid grammar ambiguity.

| Command | Effect |
|---|---|
| `music add house music` | Search catalog for "house music", add to library (existing) |
| `music add 3` | Add result #3 from last songs cache to library (new) |
| `music add --id <catalog-id>` | Add by catalog ID (existing) |
| `music add --to "House"` | Add current song to playlist "House" (new) |
| `music add --to "House" --to "Working Vibes"` | Add current song to both playlists (new) |
| `music add 3 --to "House"` | Add result #3 to playlist "House" (new) |
| `music remove` | Remove current song from current playlist |
| `music remove "House"` | Remove current song from playlist "House" |
| `music remove all` | Remove current song from all playlists |

### `add` Parsing

The `--to` flag is the delimiter between catalog/library operations and playlist operations:
- **No `--to` present:** behaves like current `add` (catalog search or index lookup). Integer = result index from last songs cache, otherwise = search query.
- **`--to` present:** the flag value(s) are playlist names. The positional arg (if any) is what to add: integer = result index, nothing = current song. `--to` can be repeated for multiple playlists.

This avoids reserving natural-language words like "to" and "and" that could appear in playlist names.

### `remove` Parsing

- No args: remove current song from the currently playing playlist.
- Single arg `all`: remove current song from every playlist it appears in.
- Otherwise: args joined as playlist name, remove current song from that playlist.

### Full Playlist Subcommands

These remain unchanged for complex operations:

| Command | Effect |
|---|---|
| `music playlist` | Interactive TUI: browse playlists, enter to see tracks |
| `music playlist list` | Non-interactive list (scripting/Claude) |
| `music playlist create "Name"` | Create empty playlist |
| `music playlist create "Name" 1 3 5` | Create playlist from result indices |
| `music playlist add "Name" 1 3 5` | Add result indices to existing playlist |
| `music playlist tracks "Name"` | List tracks in playlist |
| `music playlist delete "Name"` | Delete playlist |

Existing subcommands (`share`, `temp`, `create-from`, `cleanup`) remain unchanged.

## Volume

| Command | Effect |
|---|---|
| `music volume` | Interactive TUI: visual mixer with per-speaker bars |
| `music volume 40` | Set all active speakers to 40% (existing) |
| `music volume kitchen 40` | Set kitchen to 40% (existing) |
| `music volume up` / `down` | Adjust all speakers by +/-10% (existing) |

### Interactive TUI Controls

- Arrow up/down: select speaker
- Arrow left/right: adjust selected speaker volume by +/-5%
- Number keys: quick-set (e.g. `4` `0` for 40%)
- `q`: quit

### Visual Format

```
Kitchen       [████████████░░░░░░░░] 60%
MacBook Pro   [███░░░░░░░░░░░░░░░░░] 15%
```

## Interactive TUI Architecture

### Approach

No external library. Raw ANSI escape codes + Swift terminal raw mode (`termios`).

### Shared Module: `TerminalUI`

Single module providing three reusable primitives:

1. **ListPicker** — single-select list. Arrow navigate, enter to confirm. Used by: playlist browser.
2. **MultiSelectList** — multi-select with action keys. Arrow navigate, space toggle, action hotkeys. Used by: search/similar results, speaker picker.
3. **VolumeMixer** — per-speaker volume bars. Arrow select, left/right adjust. Used by: volume command.

### Terminal State Management

- On entry: switch to raw mode (`tcgetattr`/`tcsetattr`), hide cursor, enable alternate screen buffer.
- On exit (including Ctrl-C via signal handler): restore original terminal attributes, show cursor, exit alternate screen buffer.
- All TUI views register a cleanup handler to prevent broken terminal state on crashes.

### Activation Rule

Interactive mode activates ONLY when:
1. The command is invoked with no positional arguments AND no flags (except `--json` absence)
2. stdout is a TTY (`isatty(STDOUT_FILENO)`)

If stdout is piped or redirected, fall back to non-interactive output even with no args. This keeps scripting safe.

## Commands Unchanged

These commands have no UX issues and remain as-is:
- `music now` (default command)
- `music pause`
- `music stop`
- `music skip` / `music back`
- `music shuffle <on|off>`
- `music repeat <off|one|all>`
- `music auth` subcommands
- `music mix`
- `music playlist share/temp/create-from/cleanup`

## Migration

- All existing subcommands (`speaker set`, `speaker add`, etc.) remain as hidden aliases.
- `--json` flag behavior is unchanged on all commands.
- The Claude skill continues to use explicit subcommands and `--json` — no skill changes needed.
- Version bump to 1.2.0 after implementation.
