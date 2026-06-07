# Unified TUI Shell — Design

**Date:** 2026-06-07
**Status:** Approved (design); pending implementation plan
**Scope:** Turn the music CLI's separate one-shot TUIs into one navigable app launched by bare `music`
**Components:** new shell layer in `tools/music/Sources/TUI/`; migrates `NowPlayingTUI.swift`, `ListPicker.swift` (PlaylistBrowser), `VolumeMixer.swift`, `MultiSelectList.swift`; touches `Music.swift` and `Commands/PlaybackCommands.swift` (bare-invocation routing) and `TUILayout.swift` (`ScreenFrame`)

## Goal

Make `music` (no args) launch a single, cohesive, keyboard-driven app — a persistent live now-playing bar, a tab strip across scenes, one shared keymap — instead of the current pile of separate full-screen surfaces that each own a loop and exit back to the shell.

The bar the user set:

> **complete · performant · capable · usable · great UX**

The reference points are `cmus` / `ncmpcpp` / `musikcube`: one app, always-visible playback state, consistent keys everywhere, switch views without leaving.

## Background — current state (verified)

Mapped against the live codebase (see the architecture exploration, 2026-06-07):

- **Healthy shared foundation already exists.** `ANSICode` + `TerminalState` + `KeyPress` (`Terminal.swift`) is one non-duplicated terminal-primitive layer used by all five TUIs. `renderShell` / `clearBody` / `ScreenFrame` (`TUILayout.swift`) is shared chrome. `renderNowPlayingMetadata` and `renderTimelineRows` (`NowPlayingTUI.swift`) already take explicit `(x, y, width, height)` regions rather than assuming full screen.
- **Clean handoff already typed.** Browser → now-playing uses `BrowserResult` (enum) + `PlaybackContext` with restorable `BrowserState`. This is already the right shape for a navigation push/pop.
- **Each surface owns its own `while true` loop and returns to its caller.** There is no router, no screen stack, no persistent bar, no shared keybinding registry.
- **Everything is single-threaded and synchronous.** Every backend call goes through `syncRun` (`DispatchSemaphore`). AppleScript polls run on the main thread via `osascript` subprocess + `waitUntilExit()`. A 300ms poll freezes input for 300ms.
- **Modals tear down and rebuild the alt-screen.** `s`/`v` in now-playing call `exitRawMode()` → modal → `enterRawMode()`, causing a visible flash.

## The one deliberate reversal (read this first)

The **2026-06-06 playlist-browser spec states**: *"The design must not introduce [a background worker] — it would add data races to a currently race-free codebase."* That was correct for that surface: enrichment is **input-driven** (nothing changes until a key is pressed or a tick fires on the existing loop), so it rode the event loop and stayed race-free.

The unified shell introduces the app's **first time-driven surface**: a live now-playing bar that must redraw *while the user does nothing*. That single requirement is what forces concurrency. This spec therefore **deliberately and narrowly reverses** the no-threads rule:

- The reversal is **scoped to one unit** — a background poller that owns now-playing state. Nothing else gains a thread.
- Shared mutable state is **exactly one struct** (`NowPlayingState`), guarded by **one lock**. The main loop reads a snapshot-under-lock once per frame; the poller writes under the same lock.
- Enrichment (playlist metadata) **stays on the event loop**, unchanged — it remains input/tick-driven and race-free.

This is a contained seam, built and tested in isolation before any scene wiring, not a general move to concurrency.

## Architecture

### Control-flow inversion

Today: surface owns the loop, returns to caller. Shell: **one loop owns the screen; scenes are passive views it renders and routes keys to.**

```
enter raw mode once
start background poller thread
loop:
    snapshot = nowPlaying.read()        // under lock
    render(activeScene, frame, snapshot)
    render(bar, snapshot)               // persistent, every frame
    key = KeyPress.read(timeout: 0.1)   // ~10fps; redraw even on nil
    if key handled by global keymap -> apply (transport, scene switch, quit)
    else -> activeScene.handle(key)     // may push/pop the router
exit raw mode once
stop poller thread
```

### Scene model + router

```
enum Scene { case nowPlaying, playlists, search, speakers, library, queue }

final class Router {
    private(set) var stack: [Scene]     // back stack; top = active
    func switchTo(_ s: Scene)           // top-level tab switch (replace top-level)
    func push(_ s: Scene)               // drill-down (playlist -> nowPlaying)
    func pop()                          // Esc / b
    var active: Scene { stack.last! }
}
```

Top-level switching (`1`–`6`, `Tab`/`Shift-Tab`) sets the current top-level scene. Drill-down (`Enter` on a playlist) pushes; `Esc`/`b` pops. The existing `PlaybackContext` becomes the payload of a `push(.nowPlaying)` instead of a function return.

### Background poller (the keystone)

```
final class NowPlayingStore {
    private let lock = NSLock()
    private var state: PollOutcome
    func read() -> PollOutcome            // copy under lock
    func write(_ o: PollOutcome)          // under lock
}

// dedicated Thread: loop { store.write(pollNowPlaying(backend)); sleep(interval) }
```

- Poll cadence: ~1s (tunable), independent of the 10fps render tick.
- The poller reuses the existing `pollNowPlaying(backend:)` and `PollOutcome {active|stopped|unavailable}` contract verbatim — including the existing `unavailableBlankThreshold` tolerance.
- Clean shutdown: a `running` flag the poller checks each iteration; the shell sets it false and joins on quit, before `exitRawMode()`.

### Layout — `ScreenFrame` grows a bar band

`ScreenFrame` today: chrome at top (`bodyY = 7`), status/footer on the bottom two rows. New model:

```
 music                                    row 1  (chrome: app label)
 ♫ Now  Playlists  Spkrs                  row 2  (tab strip; active highlighted)
 ─────────────────────────────────────    row 3  (accent rule)
 [ active scene body ]                     bodyY .. barY-1   (scene-owned region)
 ─────────────────────────────────────
 ▶ Track — Artist                          rich now-playing bar (a few rows):
   Album · ▓▓▓▓▓░░░░ 1:23 / 4:10           track/artist/album, progress+time,
   ♪ Kitchen 60  Office 45   z⇄ r↻          speakers+volume, shuffle/repeat
 z shuffle · 1-3 switch · / filter · q     footer (context-sensitive keys; one digit per visible scene)
```

- `ScreenFrame` gains `barY` / `barHeight` (rich bar ≈ 3 rows). `bodyY` and scene usable-height shrink by the band.
- The bar reuses `renderNowPlayingMetadata()` content, fed by the poller snapshot, drawn on **every** frame regardless of scene.
- Scenes render only into the body rect the shell hands them; no scene knows the bar exists.

### Vertical degradation (not optional)

Chrome + tabs + rule + a 3-row bar + footer is a lot of fixed vertical cost. The shell must degrade by height so the design doesn't collapse on small terminals. Four tiers, chosen by terminal rows; `ScreenFrame` selects the tier and reports the resulting body region:

| Tier | Bar | Tabs | What it shows |
|---|---|---|---|
| **Full** | rich, 3 rows | full text tabs (`♫ Now  Playlists  Spkrs`) | track/artist/album · progress+time · speakers+volume · modes |
| **Compact** | 1 row | full text tabs | `▶ Track — Artist  ▓▓▓░ 1:23/4:10` |
| **Minimal** | 1 row | compressed tabs (`1·2·3` or initials) | track — artist + tiny progress; tabs as digits only |
| **Bare** | folded into footer | none | one status line; scene switching by digit still works, no tab strip |

`ScreenFrame` owns the tier decision and exposes `barHeight`, `showTabs`, and the body rect; scenes are unaffected — they just receive a smaller body. **Exact row thresholds are pinned in the implementation plan** (they depend on the final bar row count), but the tier model itself is fixed here so no surface is designed assuming infinite height.

### Shared keymap

The shell resolves **globals first** in every scene, then delegates the rest to the active scene:

| Global key | Action | Scene-local (delegated) |
|---|---|---|
| `space` | play/pause | `↑`/`↓` navigate |
| `+`/`-` | volume ±5 | `Enter` activate (play / push) |
| `<`/`>` | prev / next | `/` filter (where applicable) |
| `z` | shuffle | `Esc`/`b` pop |
| `r` | radio | scene-specific actions |
| `1`–`N`, `Tab` | switch scene (one digit per visible scene; 3 in v1) | |
| `q` | quit | |

Transport controls work identically from any scene. That uniformity is the core UX claim.

## Scenes

| Scene | Body | Reuses | Net-new |
|---|---|---|---|
| **Now Playing** | scrollable queue/timeline (metadata now in bar) | `renderTimelineRows`, `buildPlaylistRows`/`buildStandaloneRows`, `pollNowPlaying` | render into body rect; metadata→bar |
| **Playlists** | 3-zone rail·hero·preview | the whole v1.8.0 browser + `PlaylistBrowserModel` + enrichment | `Enter` → `router.push(.nowPlaying)` |
| **Search** *(fast-follow)* | query input + results | search backend, `ResultCache` | **mostly new** — `Search` today only prints to stdout (`SearchCommand.swift`); no interactive surface exists to migrate |
| **Speakers** | outputs list + inline per-speaker volume | `MixerSpeaker`, `MultiSelectList`, `meterBar`, speaker fetch | **merge** picker + mixer into one scene |
| **Library** *(fast-follow)* | browse all tracks / albums / artists | REST library backend | **mostly new** — no browse-all surface today |
| **Queue** *(fast-follow, data-gated)* | upcoming tracks | now-playing timeline | verify Apple Music exposes a real queue first |

### Speakers scene — the consolidation

Today speaker membership (`MultiSelectList` via `music speaker`) and per-speaker volume (`VolumeMixer` via `music volume`) are two surfaces with overlapping concerns. The shell merges them: one list of every AirPlay output, `space` toggles active membership, `←`/`→` adjusts that output's volume inline (`meterBar`). One place to answer "what's playing where, and how loud."

The standalone `music speaker` and `music volume` commands remain (one-shot CLI), but their bare-TTY path can route into this scene.

## What is preserved (non-negotiable)

- **All 14 slash commands and one-shot CLI usage are unchanged.** `music play X`, `music skip`, `music add`, `--json`, non-TTY pipes — identical behavior. The shell is *only* what bare `music` launches in a TTY.
- **`--json` and non-TTY paths never enter the shell.** `isBareInvocation` + `isTTY` gate it exactly as `Now.run()` gates the now-playing TUI today.
- **`PollOutcome` transient-failure tolerance is kept** — the live bar must not blank on one bad poll.

## Scope — v1 vs. fast-follow

**v1 (shippable):** shell core + poller + rich bar + the **three scenes that already exist as interactive surfaces** — **Now Playing, Playlists, Speakers**. After these, bare `music` is a complete unified app for the things the app can already do interactively.

**Fast-follow (same architecture, later plans):**
- **Search** — no interactive surface today (the command only prints to stdout), so the scene is net-new: an inline query field + a results region built on the existing search backend and `ResultCache`. Real work, but well-bounded; sequenced right after the spine is proven.
- **Library** — the largest net-new code; no browse-all surface exists.
- **Queue** — only if Apple Music exposes a reliable upcoming-queue source (verify before building; otherwise fold "up next" into the Now Playing scene).

This keeps v1 strictly to surfaces that already exist as interactive code sharing the new spine, and isolates every net-new or unknown piece into fast-follow.

## Testing

Follows the v1.8.0 pure-core + thin-render seam that produced 21 testable units:

- **`Router`** — push/pop/switch transitions are pure and unit-tested (back-stack correctness, no-pop-past-root).
- **`NowPlayingStore`** — read/write-under-lock; a test that concurrent writes never tear state.
- **Keymap resolution** — "global key in scene X resolves to global action; scene-local key delegates" is a pure table test.
- **`ScreenFrame` bar math** — `bodyY`/`barY`/usable-height computed correctly across terminal sizes (incl. too-small).
- **Rendering stays thin and is verified live** by the user per checkpoint, as last session — TUI output is not CI-verifiable.

## Risks & unknowns (stated, not hidden)

1. **Concurrency is the real risk.** The poller/lock seam is where this can go wrong (races, exit cleanup, `osascript` subprocess lifetime under rapid quit). Mitigation: build + test it in isolation as build step ①, before any scene exists.
2. **Queue data may not exist.** AppleScript may not expose the upcoming queue (last session flagged standalone now-playing lacks a reliable queue source). Verify in the plan; Queue scene is conditional on that result.
3. **Library scope.** Browse-all is the largest unwritten surface; deliberately fast-follow, not v1.
4. **Rich bar vs. small terminals.** Addressed by the four-tier Vertical Degradation model above (Full/Compact/Minimal/Bare). The tier *model* is fixed; only the exact row thresholds are deferred to the plan. No longer an open design risk — a sizing detail.
5. **Modal-as-overlay** (vs. today's teardown) is new rendering territory; if overlays prove fiddly, the fallback is the existing exit/re-enter pattern (accept the flash) — not a blocker.

## Build sequence

The first milestone is **not** "shell + all scenes." It is the smallest thing that proves the spine works end to end:

**Milestone 1 — prove the spine:**
① background poller + store (isolated, its own tests, its own checkpoint — the highest-risk seam, done before anything composes on it) → ② shell core (`Router`, `ScreenFrame` bar/tabs + degradation tiers, single loop, global keymap) → ③ rich persistent bar → ④ **Now Playing** migrated to a scene. *At this point one real scene runs inside the shell with a live bar — the architecture is demonstrated or it isn't, before any fan-out.*

**Milestone 2 — complete v1:**
⑤ **Playlists** scene → ⑥ **Speakers** scene (the picker+mixer merge) → **[v1 shippable: bare `music` is a unified app]**.

**Fast-follow (separate plans):**
⑦ **Search** scene (net-new input field + results region) → ⑧ **Library** scene → ⑨ **Queue** (verify Apple Music exposes a real queue, then fold into Now Playing or build standalone).

Sequencing the poller/store as its own tested checkpoint (①) and gating fan-out behind one proven scene (④) is the deliberate de-risking: the part most likely to cause subtle regressions is isolated and verified before anything depends on it.
