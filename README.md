# Apple Music for Claude Code

```
     ___              __        __  ___         _
    / _ | ___  ___   / /__     /  |/  /_ _____ (_)___
   / __ |/ _ \/ _ \ / / -_)   / /|_/ / // (_-</ / __/
  /_/ |_/ .__/ .__/_/\__/   /_/  /_/\_,_/___/_/\__/
       /_/  /_/
                         for Claude Code
```

Control Apple Music, AirPlay speakers, and AirPods — right from your terminal. Just say what you want.

```
  ┌──────────────────────────────────────────────────────────────┐
  │                                                              │
  │   > play radiohead kid a                                     │
  │                                                              │
  │   Playing Kid A from the top — Everything In Its Right       │
  │   Place. Shuffle's off so it plays in album order.           │
  │                                                              │
  │   > add living room speaker                                  │
  │                                                              │
  │   Living Room added — playing on Kitchen and Living Room.    │
  │                                                              │
  │   > search Bohemian Rhapsody                                 │
  │                                                              │
  │   1. Bohemian Rhapsody — Queen [Greatest Hits]               │
  │   2. Bohemian Rhapsody — Queen [A Night at the Opera]        │
  │                                                              │
  └──────────────────────────────────────────────────────────────┘
```

## Install

```
/plugin marketplace add anthonymaley/music
/plugin install music
/reload-plugins
```

To update:

```
/plugin update music
```

### Ceol CLI (optional, unlocks catalog features)

```bash
cd tools/ceol && scripts/install.sh
```

This builds the `ceol` Swift CLI and symlinks it to `~/.local/bin/ceol`. Without it, all playback/speaker/volume commands still work via raw AppleScript. With it, you also get catalog search, library management, playlists via API, and music discovery.

To unlock catalog and library features, set up Apple Music API auth:

```bash
ceol auth setup     # guided setup: key ID, team ID, .p8 key
ceol auth           # opens browser to get user token
```

## What you can do

```
  ╔══════════════════╦═══════════════════════════════════════════╗
  ║  Playback        ║  play, pause, skip, stop, shuffle,       ║
  ║                  ║  repeat, resume                          ║
  ╠══════════════════╬═══════════════════════════════════════════╣
  ║  Playlists       ║  list all, play by name, browse tracks,  ║
  ║                  ║  create, delete, add/remove tracks       ║
  ╠══════════════════╬═══════════════════════════════════════════╣
  ║  Catalog Search  ║  search 100M+ tracks in Apple Music      ║
  ║                  ║  catalog (requires ceol CLI)              ║
  ╠══════════════════╬═══════════════════════════════════════════╣
  ║  Library         ║  add catalog tracks to your library       ║
  ║                  ║  (requires ceol CLI + auth)               ║
  ╠══════════════════╬═══════════════════════════════════════════╣
  ║  AirPlay         ║  route to any speaker, multi-room        ║
  ║                  ║  groups, per-speaker volume               ║
  ╠══════════════════╬═══════════════════════════════════════════╣
  ║  AirPods         ║  switch between speakers and headphones  ║
  ╠══════════════════╬═══════════════════════════════════════════╣
  ║  Discovery       ║  similar tracks, suggestions, new        ║
  ║                  ║  releases, artist mixes (requires ceol)  ║
  ╠══════════════════╬═══════════════════════════════════════════╣
  ║  Now Playing     ║  current track, player state, active     ║
  ║                  ║  speakers                                 ║
  ╚══════════════════╩═══════════════════════════════════════════╝
```

## Quick commands

Instant controls — no AI reasoning, no chat clutter, just runs.

```
  /music:play                resume playback
  /music:play Working Vibes  play a playlist (with shuffle)
  /music:play Radiohead      search and play artist/album/song
  /music:pause               pause
  /music:skip                next track
  /music:back                previous track
  /music:stop                stop
  /music:np                  what's playing?

  /music:vol 60              set all active speakers to 60
  /music:vol up              +10
  /music:vol down            -10
  /music:vol kitchen 80      set per-speaker volume
  /music:shuffle             toggle shuffle on/off

  /music:speaker list        show all speakers
  /music:speaker kitchen     switch to kitchen
  /music:speaker airpods     switch to AirPods
  /music:speaker add bedroom add speaker to group
  /music:speaker remove bed  remove from group
```

## Ceol CLI

The `ceol` CLI is a Swift binary that extends the plugin with Apple Music REST API capabilities. Slash commands automatically delegate to ceol when installed, with AppleScript fallback when it's not.

```
  ceol now                                what's playing
  ceol play --playlist "Working Vibes"    play a playlist
  ceol speaker list                       AirPlay devices
  ceol vol Kitchen 80                     per-speaker volume
  ceol search "Fouk"                      search Apple Music catalog
  ceol add "Get It Done" "Fouk"           add to library
  ceol playlist list                      list playlists
  ceol playlist create "Friday Mix"       create playlist
  ceol similar                            tracks similar to now playing
  ceol new-releases --artist "Fouk"       new releases
  ceol mix --artists "Fouk,Floating Points" --count 20  build a mix
  ceol auth status                        check auth status
```

## Status line

See what's playing at the bottom of Claude Code — track, speakers, and volume — always visible, no token cost.

```
  ┌──────────────────────────────────────────────────────────────┐
  │  claude >                                                    │
  │                                                              │
  │                                                              │
  │                                                              │
  ├──────────────────────────────────────────────────────────────┤
  │  ▶ Everything In Its Right Place — Radiohead  ·  Kitchen [60]│
  └──────────────────────────────────────────────────────────────┘
```

To enable, add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/plugins/music/scripts/statusline.sh"
  }
}
```

## Natural language

For anything more complex, just talk naturally. No commands to memorize.

### Play music

```
> play some Daft Punk
> play radiohead kid a
> put on some music
> shuffle playlist Working Vibes
```

### Control playback

```
> pause
> volume 40
> skip
> stop
```

### Playlists

```
> list playlists
> play Friday on the Deck
> what's in the House playlist?
> play my top 25 most played and list the tracks
```

### AirPlay speakers

```
> play on the kitchen speaker
> add living room speaker
> remove the bedroom from the group
> turn the kitchen up to 80
```

### Catalog & discovery (requires ceol CLI)

```
> search for Bohemian Rhapsody
> add that track to my library
> find me something similar to what's playing
> what's new from Radiohead?
> make me a mix from Fouk and Floating Points
```

## How it works

```
  You: "play Kid A on the kitchen speaker"
   │
   ├─ ceol speaker set Kitchen
   ├─ ceol play --song "Kid A"
   │
  Claude: "Playing Kid A — Everything In Its Right Place."
```

The plugin uses the `ceol` CLI when installed (Swift binary wrapping AppleScript + Apple Music REST API). Without ceol, it falls back to raw AppleScript for playback and speaker control.

```
  ┌─────────────────────────────────────────────┐
  │            Claude Code Plugin                │
  │                                              │
  │  Slash Commands ──► ceol CLI ──► AppleScript │
  │       │                  │                   │
  │       │                  └──► REST API       │
  │       │                                      │
  │       └──► AppleScript (fallback)            │
  │                                              │
  │  Skill ──► ceol CLI (--json for structured)  │
  │                                              │
  │  Status Line ──► osascript (lightweight)     │
  └─────────────────────────────────────────────┘
```

## Requirements

```
  ┌────────────────────────────────────────────────────┐
  │  macOS           Required (AppleScript is macOS    │
  │                  only)                             │
  │                                                    │
  │  Apple Music     Comes with macOS                  │
  │                                                    │
  │  Permissions     System Settings > Privacy &       │
  │                  Security > Automation > enable    │
  │                  for your terminal app             │
  │                                                    │
  │  Swift 5.9+      For building ceol CLI (optional)  │
  │                                                    │
  │  AirPods         Must be connected via Bluetooth   │
  │                  to appear as a device             │
  └────────────────────────────────────────────────────┘
```

## License

MIT
