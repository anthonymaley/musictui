# Playbook: Apple Music

How to rebuild this project from scratch.

## Tech Stack
Claude Code plugin with two layers:
- **music CLI** — Swift 5.9+ binary using AppleScript (playback/speakers) + Apple Music REST API (catalog/library)
- **Plugin shell** — slash commands, skill, status line script that delegate to music CLI (with AppleScript fallback)

## Setup
1. Install the plugin: `/plugin marketplace add anthonymaley/music` then `/plugin install music@anthonymaley-music`
2. Grant automation permissions: System Settings > Privacy & Security > Automation
3. Build music CLI: `scripts/install.sh` (optional, unlocks catalog features)
4. Set up Apple Music auth: `music auth setup` then `music auth` (optional, unlocks library/discovery)
5. Optional: enable status line in `~/.claude/settings.json` (see README)

## Architecture

```
apple-music/
├── tools/music/               # Swift CLI binary
│   ├── Package.swift          # SPM manifest (swift-argument-parser)
│   └── Sources/
│       ├── Music.swift        # @main entry, 20 subcommands
│       ├── Backends/
│       │   ├── AppleScriptBackend.swift  # osascript wrapper
│       │   └── RESTAPIBackend.swift      # Apple Music API (URLSession)
│       ├── Auth/
│       │   ├── AuthManager.swift     # Config + token management
│       │   ├── JWTGenerator.swift    # ES256 JWT from .p8 key (CryptoKit)
│       │   └── AuthPage.swift        # MusicKit JS HTML for user token
│       ├── Commands/
│       │   ├── PlaybackCommands.swift   # play, pause, skip, back, stop, now, shuffle, repeat
│       │   ├── SpeakerCommands.swift    # speaker list/set/add/remove/stop
│       │   ├── VolumeCommands.swift     # vol get/set/up/down/per-speaker
│       │   ├── AuthCommands.swift       # auth setup/status/open/set-token
│       │   ├── SearchCommand.swift      # catalog search
│       │   ├── AddCommand.swift         # add to library
│       │   ├── PlaylistCommands.swift   # full playlist CRUD + share + temp
│       │   ├── DiscoveryCommands.swift  # similar, suggest, new-releases
│       │   ├── MixCommand.swift         # build mixed playlists
│       │   └── RemoveCommand.swift      # remove track from playlist
│       ├── Models/
│       │   ├── OutputFormat.swift    # --json vs human-readable
│       │   ├── ResultCache.swift     # domain-specific song/speaker caches
│       │   └── LibrarySync.swift     # poll-and-retry for REST→AppleScript sync
│       └── TUI/
│           ├── Terminal.swift        # raw mode, ANSI codes, key reading
│           ├── TUILayout.swift       # shared ScreenFrame, renderShell
│           ├── MultiSelectList.swift # speaker picker, track selector
│           ├── ListPicker.swift      # playlist browser (2-pane)
│           ├── VolumeMixer.swift     # per-speaker volume mixer
│           └── NowPlayingTUI.swift   # now playing with album art + queue
├── commands/                  # Slash commands (delegate to music CLI, osascript fallback)
├── skills/music/SKILL.md      # Conversational skill documenting music CLI surface
├── scripts/
│   ├── install.sh             # Build + symlink music to ~/.local/bin/
│   └── statusline.sh          # Now playing for Claude Code status bar
└── .claude-plugin/            # plugin.json and marketplace.json
```

### Backend Selection
- **AppleScript** — playback, speakers, volume, now playing (no auth)
- **REST API** — catalog search (developer token), library writes + playlists + discovery (both tokens)

### Auth Tiers
| Tier | Commands available |
|------|-------------------|
| No auth | play, pause, skip, back, stop, now, shuffle, repeat, speaker, vol |
| Developer token | Above + search |
| Both tokens | Everything (add, playlist API, similar, suggest, new-releases, mix) |

### Config Location
- `~/.config/music/config.json` — key ID, team ID, key path, storefront
- `~/.config/music/AuthKey.p8` — Apple MusicKit private key
- `~/.config/music/user-token` — Apple Music user token (~6 month expiry)

## Integrations
- macOS Music app (via AppleScript/osascript)
- Apple Music REST API (via URLSession, JWT auth)
- AirPlay speakers and Bluetooth audio devices
- Messages.app and Mail.app (for playlist sharing)

## Deployment
Published via Claude Code marketplace. Version bumps must update all three locations (see CLAUDE.md).

## Gotchas
- **Parameter error (-50)** — Split AirPlay routing and playback into separate osascript calls
- **MusicKit JS requires HTTP origin** — Auth page served via localhost:8537, not file://
- **MusicKit framework hangs on macOS CLI** — Use pure REST API + CryptoKit JWT instead
- **`MusicLibrary.add()` is iOS-only** — macOS library writes go through REST API
- **Library sync delay** — REST API writes may take 1-3 seconds to appear in AppleScript
- User must grant Automation permissions on first use
- macOS only — AppleScript doesn't exist on other platforms
- AirPods names often contain apostrophes — escape in bash: `'Anthony'\''s AirPods Pro'`
- **Ghost speaker problem** — AirPlay speakers report `selected = true` but don't play audio. Fix: deselect→wait→reselect (wake cycle). v1.4.0 does this automatically on routed playback.
- **ArgumentParser flag shadowing** — `@Flag var verbose` on a ParsableCommand shadows the global `verbose()` function. Use `@Flag var verboseFlag` with explicit `name: [.customShort("v"), .customLong("verbose")]`.
- **Error enum payload formatting** — Don't embed full sentences in error enum payloads when `errorDescription` also wraps them. Use structured fields (e.g., `speakerNotFound(name:, available:)`).
- **AppleScript string escaping** — Always route user/catalog-supplied values through `escapeAppleScriptString()` (Backends/AppleScriptEscaping.swift) before interpolating into a script. It escapes backslash *then* quote — order matters. Never hand-roll a quote-only escape; a name with a `\` (e.g. `AC\DC`) corrupts the script otherwise.
- **Poll error vs stop** — `pollNowPlaying()` returns `PollOutcome` (`active`/`stopped`/`unavailable`), not an optional. Treat `.unavailable` (transient read failure) differently from `.stopped`: never auto-advance or blank the UI on a single transient hiccup.
- **`every track of playlist` is a per-element trap** — `repeat with t in (every track of playlist "X")` accessing `name of t`/`artist of t` does an Apple Event round-trip *per element*: ~3.77s for 200 tracks of the 13.6k-track library playlist. Fetch properties in bulk: `set total to count of tracks of playlist "X"`, then `name of tracks 1 thru n of playlist "X"` + `artist of tracks 1 thru n` (clamp `n` to `total`, guard `n > 0`), join in-memory. ~0.21s (~18×). Never enumerate per-element for track properties.
- **Version lives in 4 places** — keep `plugin.json`, `marketplace.json` (metadata + plugins[0]), AND `tools/music/Sources/Music.swift` `CommandConfiguration(version:)` in sync; rebuild via `scripts/install.sh` so `music --version` matches.
- **`play track N of playlist X` is broken in macOS 26.x — the app owns the playlist queue now** (see `Sources/TUI/Shell/AppQueue.swift`). Exhaustively verified live: (1) `play track N of playlist X` sets `current playlist` to the library and, at track end, bleeds into Autoplay — no navigable queue at all; (2) `play playlist X` keeps context but resumes at the playlist's *sticky* position (NOT track 1) and backward nav FLOORS there, so "tracks above" can't reach track 1; (3) a fresh temp-playlist copy *also* starts mid-list and clutters the user's iCloud library. None give "playlist positioned at N with full up/down." **Resolution:** don't rely on Music's queue — the app holds the ordered track list (`AppQueue`) and drives playback itself: `play track N of playlist X` for one track, and `PlaybackPoller` plays the next when it stops at end. `next`/`prev`/`Enter` navigate our list (full up/down, immune to the regression). **Hard dependency: Music's Autoplay (∞) must be OFF** — `once` is ignored, so with Autoplay on a single track bleeds into the library before the poller can advance. Whole-playlist `play playlist X` (the `p` key) still uses Music's gapless native queue.
- **Native radio = the "Create Station" menu, not a verb** — Music.app's AppleScript dictionary has NO station/radio/genius command. The only route to start a station is System Events clicking `Song ▸ Create Station`, which needs (a) Music FRONTMOST (`tell application "Music" to activate` first, then restore the prior front app) and (b) the clicking process to hold **Accessibility** permission. Apple Events permission (control Music) ≠ Accessibility permission (click its UI): the `music` binary gets the former via the terminal but apparently not the latter, so the click silently no-ops. Treat native radio as fragile / possibly unavailable from the CLI.
- **`runMusic` wraps in `tell application "Music"`** — do NOT route System Events / GUI-automation scripts through it; nesting a `tell application "System Events"` click inside the `tell Music` block is a no-op. Use the raw `backend.run()` for those.
- **Shell unit tests are pure-model only** — the ~89 tests cover zones/parsing/router/frame math and prove NOTHING about playback context, AirPlay, radio, or macOS permissions. For anything AppleScript/Music.app/TCC-dependent, build-green ≠ verified; confirm live, and after one live failure on a symptom, change layers rather than ship another same-shape patch.
- **Concatenated AppleScript batches fail all-or-nothing under concurrent load** — `onMeta` builds one script for N playlists; at startup the poller + preview fetches hammer Music in parallel, so a batch can transiently error and (with `try? syncRun`) silently return `[:]` — blanking exactly `chunkSize` rows (the giveaway: 8 missing = one failed batch of 8). Each individual playlist works when retried alone. Fixes: (a) wrap each playlist's clause in its own `try` so one bad entry can't abort the batch and partial results survive; (b) the background refresh retries any index that didn't come back, with backoff, until all resolve. Playlist rail metadata is cached to `~/.config/music/playlist-meta.json` (keyed by name) and seeded on launch for an instant paint; the off-thread refresh rewrites it.

## Current Status
**1.10.0 — app-owned playlist queue (routes around the macOS 26.x regression).** Picking a track in a playlist now registers an in-memory `AppQueue` (full ordered track list) and drives playback track-by-track; `PlaybackPoller` auto-advances on natural end, `next`/`prev`/`Enter` navigate our list — full up/down restored, immune to Apple's broken `play track N of playlist X`. **Requires Music Autoplay OFF** (verified live). **Radio removed** from the shell (Accessibility-walled, unfixable) and replaced by **shuffle** (`z`/`r`, and the end-of-queue menu's `[S]`). Whole-playlist `p`/`s` still use Music's native gapless queue.

**1.9.0 — unified TUI shell.** Bare `music` launches one navigable app: a single `runShell` loop, `Router` scene stack, `ShellFrame`, global keymap, and a background `PlaybackPoller`/`NowPlayingStore`. Three scenes: **Now Playing**, **Playlists** (3-zone browser as a tab), **Speakers**. The 14 slash commands, conversational skill, and status line are unchanged; the shell is only what bare `music` opens in a TTY.

**Architecture decision (researched + verified):** AppleScript (control of Music.app) + REST (catalog/library/recommendations data) is the only viable stack for a no-paid-account, native-macOS CLI. MusicKit/MediaPlayer/MediaRemote/browser are evaluated-and-rejected. Native radio is a permission gap (removed); the playlist-queue gap is now solved app-side.
