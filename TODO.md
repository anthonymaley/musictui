# TODO

## Current Session

- [x] All `disable-model-invocation` commands tested and working — `$ARGUMENTS` works correctly
- [x] Tested `/music:vol julie office 66` — per-speaker volume works
- [x] Tested `/music:speaker add kitchen`, `/music:speaker remove kitchen` — works
- [x] Added chained actions to `/music:speaker` — e.g. `remove kitchen add julie office`
- [x] Added `only` keyword to `/music:speaker` — e.g. `only kitchen`
- [ ] Discovered: `/music:stop` doesn't support per-speaker stop (stops all playback)
- [ ] Discovered: `/music:speaker stop kitchen` falls through to bare name match — no `stop` action

## What's Next

- Consider enhancing `/music:stop` to support per-speaker: `/music:stop kitchen` removes speaker, no args stops all
- Bump version to v0.3.0 — all commands verified working
- Consider adding `/music:list` command to list playlists without AI

## Backlog
