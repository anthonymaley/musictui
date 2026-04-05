# TODO

## Current Session

- [x] Brainstormed AirPlay resilience + CLI polish improvements
- [x] Wrote design spec with 3-layer architecture (plumbing → resilience → TUI)
- [x] Spec reviewed: fixed 3 issues (play.md path, verbose/JSON contract, test plan clarity)
- [x] Wrote 14-task implementation plan
- [x] Implemented all 14 tasks via subagent-driven development in worktree
- [x] Spec compliance review: fixed version bump + fetchSpeakerDevices error handling
- [x] Merged worktree to main, release-built and installed v1.4.0
- [x] User tested: wake cycle, verbose, speaker not found, routed playback
- [x] Fixed: added speaker/volume parsing to Swift Play command (music play "X" kitchen 20)
- [x] Fixed: speakerNotFound error message carried name+available as separate fields
- [x] Updated README with v1.4.0 features, routed playback, diagnostics, wake cycle
- [x] Ran /kerd:tend — 7 passing, 2 warnings (gitignore + hooks, unfixed)

## What's Next

- TUI keybinding: `f` to cycle shuffle on/off, `r` to cycle repeat off→all→one (user requested)
- Fix /kerd:tend warnings: add kivna/input/ and kivna/output/ to .gitignore, register hooks
- Inherited-session wake detection in Swift Play command (auto-wake when non-local AirPlay active)
- Consider `--no-wake` pass-through in commands/play.md slash command
- End-to-end testing: playlist with comma in name, overlapping speaker names, 200+ track playlist
- Monitor community feedback on v1.4.0

## Key Context

- Version is 1.4.0 everywhere (plugin.json, marketplace.json x2, CLI, Music.swift)
- CLI binary is `music`, installed at `~/.local/bin/music`
- **Wake cycle**: deselect→500ms→reselect→500ms→verify. Runs automatically on routed playback.
- **Routed playback**: `music play "Playlist" kitchen 20` now works directly from CLI (longest-match speaker parsing)
- **--verbose**: diagnostics to stderr, works alongside --json
- **--no-wake**: skips wake cycle on Play command
- **Play command flag**: `@Flag var verboseFlag` (not `verbose`) to avoid shadowing the global `verbose()` function
- **speakerNotFound**: carries `(name: String, available: [String])` not a single string
- **Worktree branch** `worktree-airplay-resilience` still exists at `.claude/worktrees/airplay-resilience` — can be cleaned up
- **2-screen flow**: PlaylistBrowser ↔ NowPlaying with PlaybackContext. b/Esc returns to browser with state preserved
- **Speaker matching**: longest match wins (avoids "Office" matching before "Julie office")

## Backlog

- Playlist browser: incremental track loading beyond 200
- Playlist browser: artwork support (chafa + raw mode)
- Playlist browser: `/` search
- Video demo in README
- `/music:list` command for listing playlists
