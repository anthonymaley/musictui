# TODO

## Current Session

- [x] Designed unified Music CLI architecture (spec + plan)
- [x] Spec: `docs/superpowers/specs/2026-03-31-music-cli-design.md` — reviewed, 7 findings fixed
- [x] Plan: `docs/superpowers/plans/2026-03-31-music-cli.md` — 13 tasks, 5 phases, 4 findings fixed
- [x] Prototype: JWT token generation + catalog search works (tested with .p8 key)
- [x] Prototype: `tools/music-catalog/` exists but is superseded by the plan's `tools/music-cli/`
- [ ] **Execute the plan** — 13 tasks across 5 phases, using subagent-driven-development

## What's Next

- **Start next session with:** `execute the music CLI plan` — use subagent-driven-development
- Phase 1 (Tasks 1-4): Swift package scaffold + playback/speaker/volume commands
- Phase 2 (Tasks 5-6): Auth (JWT + user token browser flow)
- Phase 3 (Tasks 7-9): REST API backend + search/add/playlist commands
- Phase 4 (Task 10): Discovery (similar, suggest, new-releases, mix)
- Phase 5 (Tasks 11-13): Plugin integration (install script, slash commands, skill)
- Clean up `tools/music-catalog/` prototype (Task 1, Step 1 handles this)

## Key Context

- User has Apple Developer account with MusicKit key: `AuthKey_W5H3NYJ999.p8`
- Key copied to `~/.music-catalog-key.p8` (prototype location — plan moves to `~/.config/music-cli/`)
- Team ID: `8NS66RKB45`, Key ID: `W5H3NYJ999`
- Signing identity: `Apple Development: Anthony Maley (KG6T2K5H9Y)`
- MusicKit `MusicLibrary.add()` is iOS-only — macOS must use REST API for library writes
- MusicKit import causes CLI to hang — pure REST API + CryptoKit approach works
- User token acquisition: MusicKit JS in browser → paste token → cached at `~/.config/music-cli/user-token`
- AppleScript Parameter error -50: split AirPlay routing + playback into separate osascript calls

## Backlog

- Consider enhancing `/music:stop` to support per-speaker stop
- Consider adding per-speaker stop to the CLI (`music speaker stop kitchen`)
