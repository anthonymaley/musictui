# Queue resume across restart — design spec (2026-07-16)

Quit the TUI mid-album (or mid-playlist), relaunch, and land back in that album
positioned where you left off — with the poller driving it album-scoped again, so
it stops at the album's end instead of running into the 14k-track library.

Status: **design, not built.** Touches `AppQueue`, the most fragile code in the
project. Reviewed before implementation.

## The bug, precisely

The scoped queue is the in-process `AppQueue` (`Sources/TUI/Shell/AppQueue.swift`):
a track list, a current position, and a display label. The TUI drives playback
track-by-track because macOS 26's `play track N of playlist X` collapses Music's
own `current playlist` to the whole library. On quit, `poller.stop()` halts the
driver but does not touch playback — Music keeps playing the current track. The
`AppQueue` dies with the process. On relaunch the Now tab has nothing to restore
from, so it rebuilds Up Next from Music's native context = the collapsed library.

Observed live (user screenshots, 2026-07-16): before quit, Up Next = the 16-track
Low End Theory album, context "The Low End Theory". After relaunch, same track
still audibly playing (Excursions, 0:05 → 0:47), but Up Next = the entire library
(positions 12706, 12707, 12708…), context "Music". Second consequence: playback is
now library-scoped, so at the album's end it will run past into track 12722+.

## Prior art (research 2026-07-15, cited in this session)

- **No competitor persists queue state.** Five native/Cider Apple Music CLIs
  inspected; none resume a queue across restart. This puts us ahead, not level.
- **No scriptable queue exists.** Live `sdef` dump of Music.app (macOS 26.4.1):
  no queue class, no queue/up-next verb, `current playlist`/`current track` are
  read-only. The AppQueue workaround is the only path; there's no escape hatch.
- **`play playlist X` is not a shortcut here.** The research floated it (competitors
  use it); the playbook (line 134) already refuted it exhaustively — sticky start
  position, floored backward nav — and albums have no playlist object to point at.
- **The applicable pattern is cmus's `resume` + autosave**, with one improvement:
  key by Apple's **`persistent ID`** (stable, never changes), not name/index. mpv
  (#8138) shipped index-keyed resume and it broke on reorder/duplicate tracks.

## Design

### What is saved

A new file `~/.config/music/queue.json` (sibling to `stations.json`,
`last-speakers.json` — same `StationStore`-style write pattern). It holds the
serialized `AppQueue` plus one **anchor**: the persistent ID of the track that was
current when saved.

```
{
  "playlistName": "Library",
  "displayName": "The Low End Theory",
  "currentIndex": 1,
  "tracks": [ { "index": 12708, "name": "Excursions", "artist": "A Tribe Called Quest" }, ... ],
  "anchorPersistentID": "A1B2C3D4E5F60718",   // Music's `persistent id of current track` at save time
  "anchorName": "Excursions",                  // fallback identity if the ID read fails/absent
  "anchorArtist": "A Tribe Called Quest"
}
```

`AppQueue` and `TrackListEntry` become `Codable` (they're plain structs today;
this is additive). The anchor fields are new and live only in the on-disk shape,
not in the in-memory `AppQueue` — a small `PersistedQueue` wrapper struct.

### When it is saved

**On every change to the queue's current position, not only on clean quit.** The
process can die non-gracefully (⌘Q, terminal close, crash), so an on-exit-only
save (cmus's weaker guarantee) would lose the last advance. Save points, all of
which already mutate the queue:
- poller auto-advance (`PlaybackPoller.swift:235`, `appQueue.step(1)`)
- next/prev/jump/select in the main loop
- a new queue set (`appQueue.set(...)` — the 6 call sites)
- clear (delete the file when the queue goes nil, so a stale queue never lingers)

The write is small (a few KB) and off the render path. Reading the current track's
persistent ID for the anchor is one extra AppleScript read, done only at save time,
tolerant of failure (falls back to name/artist, or omits the anchor).

### Restore, on launch

The audio is already playing — we do **not** re-issue `play` (that would stutter a
track that's already sounding). We re-attach the driver:

1. Load `queue.json`. Absent/corrupt → do nothing, today's behavior.
2. Read the currently-playing track's identity from Music (persistent ID if
   available, else name+artist).
3. **Staleness guard (v1, strict):** does the playing track match the saved queue's
   current entry (`tracks[currentIndex-1]`), by `anchorPersistentID` first, then
   name+artist?
   - **Match** → `appQueue.set(restoredQueue)`. The poller now drives the album
     scoped again, Up Next shows the album, and playback stops at the album's end.
   - **No match** → discard the file, fall back to today's native context. Never
     adopt a queue that doesn't match reality (the mpv lesson; MPD's prune-on-
     mismatch discipline).
4. If Music is stopped on launch, discard — nothing to resume onto.

**Known v1 limitation, called out on purpose:** strict match discards the queue if a
track *ended during the gap* between quit and relaunch (Music auto-advanced one
track library-scoped while nothing was driving). Quit-and-immediately-relaunch (the
common case, gap of seconds) matches and resumes. The forgiveness upgrade — search
the saved `tracks` for the playing track's persistent ID and resume from wherever it
sits — requires a persistent ID on every `TrackListEntry`, which ripples into the
bulk-fetch AppleScript (`fetchLibraryTracksWithPositions` + the playlist fetch) and
the `TrackListEntry` struct. Deferred to v2 unless the gap case proves annoying live;
v1 keeps the change isolated to the anchor (one current-track ID read) and away from
the fragile fetch/drive path.

### What this deliberately does NOT do

- **No re-play, no seek.** The track is already sounding at its real position; we
  only re-attach the queue. Position within the track is Music's, untouched.
- **No daemon.** Playback still stops being *driven* while the TUI is closed — if a
  track ends during the gap, Music auto-advances library-scoped and the guard
  correctly discards on relaunch. Keeping the album playing *while closed* is the
  separate resident-driver/daemon problem (`docs/deferred.md`), explicitly out of
  scope.
- **No CLI resume.** `music play --album` still exits immediately (no resident
  driver). This spec is the TUI only.

## Risks

- **Persistent ID on streamed tracks throws `-1728`** (Apple bug FB19908171, found
  in the research). Album/playlist tracks are library `shared track`s, so the ID
  read should work — but the save-time read MUST be failure-tolerant (fall back to
  name+artist anchor), and the restore guard must treat an unreadable ID as "no
  match, discard" rather than crashing. Never error at the user over a resume.
- **A false match** would resume the wrong content. Two different tracks with the
  same name+artist and no persistent ID is the only way this happens; persistent-ID
  matching closes it. Accept name+artist only as a fallback, and when even that is
  ambiguous, discard.
- **AppQueue is scar-tissue code.** Every change here has shipped green and failed
  live before (playbook). The queue struct changes are additive (Codable
  conformance + a wrapper); the behavioral change is isolated to save-on-mutate and
  a restore step at startup. No change to how the queue *drives* playback.

## Testing

- **Pure/unit:** `PersistedQueue` round-trips through JSON; the staleness guard is a
  pure function `matches(playing:, saved:) -> Bool` over (persistentID?, name,
  artist) — test match by ID, match by name+artist fallback, mismatch, ambiguous →
  false, missing-anchor cases. `AppQueue`/`TrackListEntry` Codable round-trip.
- **Seam:** the save writes through an injectable path (temp file in tests, never
  the real `~/.config/music/queue.json`), mirroring `StationStore`'s test seam.
- **Live — the gate:** the exact repro. Play Low End Theory from the Library tab,
  quit mid-album, relaunch. Up Next must show the album (not the library), context
  "The Low End Theory", positioned on the playing track; let it reach the album end
  and confirm it STOPS rather than running into the library. Then the negative case:
  quit mid-album, play a different album directly in Music.app, relaunch — must NOT
  resume the stale album; must show the new track's native context. Green tests do
  not prove either; the user drives both.

## Verification (definition of done)

1. `swift test` green.
2. Live: quit mid-album → relaunch → back in the album, positioned, poller driving;
   album stops at its end.
3. Live: quit mid-album → play something else in Music → relaunch → stale queue
   discarded, no wrong-content resume.
4. Live: quit with nothing playing → relaunch → no crash, clean idle Now tab.
5. Token-less / no-persistent-ID paths never error at the user.
