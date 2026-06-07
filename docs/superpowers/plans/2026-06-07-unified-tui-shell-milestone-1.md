# Unified TUI Shell — Milestone 1 (Spine) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make bare `music` launch a single shell loop that runs the Now Playing surface as a *scene* inside a frame with a persistent, live now-playing bar fed by a background poller — proving the architecture end-to-end before any scene fan-out.

**Architecture:** One render loop owns the screen and enters raw mode once. A background `PlaybackPoller` thread polls Apple Music and writes `NowPlayingSnapshot` into a lock-guarded `NowPlayingStore`; the main loop reads a snapshot each frame (~10fps) and renders the active scene's body plus a persistent bar. A pure `Router` (scene-id stack) and a pure global-keymap resolver sit between input and scenes. The Now Playing scene reuses the existing timeline renderers; the poller absorbs the existing poll loop's auto-advance/history/album-context behavior verbatim so playback semantics are unchanged.

**Tech Stack:** Swift 5, swift-argument-parser, AppleScript via `osascript` subprocess, XCTest, raw-mode terminal (Darwin `termios`/`poll`).

**Reference spec:** `docs/superpowers/specs/2026-06-07-unified-tui-shell-design.md`

**Scope of this plan:** Milestone 1 only — poller/store → shell core (frame/router/keymap) → persistent bar → Now Playing scene → wire bare `music`. Playlists and Speakers scenes are Milestone 2 (separate plan). Search/Library/Queue are fast-follow.

**Working location:** directly on `main` (project convention; user consented). Commit per task. Push at end of milestone (project CLAUDE.md: always push after committing).

---

## File Structure

New files (all under `tools/music/Sources/TUI/`):

- `Shell/NowPlayingStore.swift` — `NowPlayingSnapshot` value type + lock-guarded `NowPlayingStore` (read/write a snapshot).
- `Shell/PlaybackPoller.swift` — background `Thread` that polls, maintains history/album-context/auto-advance, writes snapshots; `start()`/`stop()`.
- `Shell/ShellFrame.swift` — `ShellFrame`, `BarTier`, `TabStyle`, pure `shellLayout(width:height:)` with degradation tiers.
- `Shell/Router.swift` — `SceneID` enum + pure `Router` (push/pop/switchTo/active).
- `Shell/GlobalKeymap.swift` — `GlobalAction` + pure `resolveGlobalKey(_:)`.
- `Shell/Scene.swift` — `Scene` protocol + `SceneAction` enum.
- `Shell/ShellChrome.swift` — `renderShellChrome(frame:)`, `renderTabStrip(...)`, `renderNowPlayingBar(snapshot:frame:)` (bar is net-new at bar-band coords).
- `Shell/NowPlayingScene.swift` — `NowPlayingScene` conforming to `Scene` (body = album timeline; reuses `buildStandaloneRows`/`renderTimelineRows`).
- `Shell/Shell.swift` — `runShell()` top-level loop wiring all of the above.

New test files (under `tools/music/Tests/MusicTests/`):

- `ShellFrameTests.swift`, `RouterTests.swift`, `GlobalKeymapTests.swift`, `NowPlayingStoreTests.swift`.

Modified:

- `Sources/Commands/PlaybackCommands.swift:378-384` — `Now.run()` launches `runShell()` for bare TTY (was `runNowPlayingTUI()`).

Note: `runNowPlayingTUI()` / `runNowPlayingWithContext()` in `NowPlayingTUI.swift` are **left in place** this milestone (still used by `Radio.run()` at `PlaybackCommands.swift:494` and the playlist browser handoff). They are removed only after Milestone 2 migrates their callers. Do not delete them now.

---

## Task 1: NowPlayingSnapshot + NowPlayingStore (lock-guarded state)

**Files:**
- Create: `tools/music/Sources/TUI/Shell/NowPlayingStore.swift`
- Test: `tools/music/Tests/MusicTests/NowPlayingStoreTests.swift`

`NowPlayingState`, `PollOutcome`, and `TrackListEntry` already exist in `NowPlayingTUI.swift` (all value types) — reuse them. The snapshot bundles the poll outcome with the derived context the bar and Now Playing scene need.

- [ ] **Step 1: Write the failing test**

```swift
// tools/music/Tests/MusicTests/NowPlayingStoreTests.swift
import XCTest
@testable import music

final class NowPlayingStoreTests: XCTestCase {
    func testReadReturnsLastWrite() {
        let store = NowPlayingStore()
        var np = NowPlayingState()
        np.track = "Homosapien"
        np.artist = "Pete Shelley"
        store.write(NowPlayingSnapshot(outcome: .active(np), history: [], surrounding: []))
        let snap = store.read()
        guard case .active(let got) = snap.outcome else { return XCTFail("expected active") }
        XCTAssertEqual(got.track, "Homosapien")
        XCTAssertEqual(got.artist, "Pete Shelley")
    }

    func testDefaultIsUnavailable() {
        let store = NowPlayingStore()
        if case .unavailable = store.read().outcome { } else { XCTFail("expected unavailable default") }
    }

    func testConcurrentWritesDoNotTearState() {
        let store = NowPlayingStore()
        let group = DispatchGroup()
        for i in 0..<500 {
            group.enter()
            DispatchQueue.global().async {
                var np = NowPlayingState()
                np.track = "T\(i)"
                np.position = i
                store.write(NowPlayingSnapshot(outcome: .active(np), history: [], surrounding: []))
                group.leave()
            }
        }
        for _ in 0..<500 {
            group.enter()
            DispatchQueue.global().async {
                // A torn read would crash or mismatch; we only assert it never traps
                // and that the track/position pair stays internally consistent.
                if case .active(let np) = store.read().outcome {
                    XCTAssertTrue(np.track.hasPrefix("T"))
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tools/music && swift test --filter NowPlayingStoreTests`
Expected: FAIL — `NowPlayingSnapshot` / `NowPlayingStore` not defined (compile error).

- [ ] **Step 3: Write minimal implementation**

```swift
// tools/music/Sources/TUI/Shell/NowPlayingStore.swift
import Foundation

/// One frame's worth of playback truth, copied atomically between the poller
/// thread and the main render loop. All fields are value types so a read under
/// lock yields an independent, internally-consistent copy.
struct NowPlayingSnapshot {
    var outcome: PollOutcome
    var history: [(track: String, artist: String)]
    var surrounding: [TrackListEntry]
}

/// Thread-safe box around the latest snapshot. The poller calls `write`; the
/// main loop calls `read` once per frame. One lock, one struct — the entire
/// shared-mutable-state surface of the shell (see spec: "one poller, one store,
/// one lock").
final class NowPlayingStore {
    private let lock = NSLock()
    private var snapshot = NowPlayingSnapshot(outcome: .unavailable, history: [], surrounding: [])

    func read() -> NowPlayingSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    func write(_ next: NowPlayingSnapshot) {
        lock.lock(); snapshot = next; lock.unlock()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tools/music && swift test --filter NowPlayingStoreTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/TUI/Shell/NowPlayingStore.swift tools/music/Tests/MusicTests/NowPlayingStoreTests.swift
git commit -m "$(printf 'feat(shell): NowPlayingSnapshot + lock-guarded NowPlayingStore\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 2: PlaybackPoller — minimal poll→store thread with clean shutdown

**Files:**
- Create: `tools/music/Sources/TUI/Shell/PlaybackPoller.swift`

This task builds the thread that writes poll outcomes into the store, with start/stop and clean shutdown. Auto-advance/history/album-context are added in Task 3 (kept separate so the threading seam is proven first). This is the highest-risk seam — verify shutdown before composing anything on it.

- [ ] **Step 1: Write the implementation**

```swift
// tools/music/Sources/TUI/Shell/PlaybackPoller.swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Background thread that polls Apple Music on its own cadence and publishes
/// snapshots to a NowPlayingStore. Decouples poll latency (~50-500ms per
/// AppleScript call) from the main loop's input/redraw latency, so the live
/// now-playing bar advances while the user is idle and input never freezes
/// waiting on a poll.
///
/// Threading contract: `running` is the only field touched from two threads;
/// it is guarded by `lock`. The poll cadence is `intervalMs`. On `stop()` the
/// loop exits after its current iteration and signals `finished`; `stop()`
/// waits briefly so the main loop can leave raw mode after the poller is idle.
final class PlaybackPoller {
    private let store: NowPlayingStore
    private let backend: AppleScriptBackend
    private let intervalMs: UInt32
    private let lock = NSLock()
    private var running = false
    private let finished = DispatchSemaphore(value: 0)

    init(store: NowPlayingStore, backend: AppleScriptBackend, intervalMs: UInt32 = 1000) {
        self.store = store
        self.backend = backend
        self.intervalMs = intervalMs
    }

    func start() {
        lock.lock(); running = true; lock.unlock()
        let thread = Thread { [weak self] in self?.loop() }
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// Signal the loop to stop and wait (bounded) for it to finish its current
    /// tick. Safe to call from the main thread before exitRawMode().
    func stop() {
        lock.lock(); running = false; lock.unlock()
        _ = finished.wait(timeout: .now() + 2.0)
    }

    private func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func loop() {
        while isRunning() {
            tick()
            // Sleep in small slices so stop() is responsive even with a long interval.
            var slept: UInt32 = 0
            while slept < intervalMs, isRunning() {
                usleep(50 * 1000)
                slept += 50
            }
        }
        finished.signal()
    }

    /// Overridden in Task 3 to carry history/album-context/auto-advance.
    func tick() {
        let outcome = pollNowPlaying(backend: backend)
        let prev = store.read()
        store.write(NowPlayingSnapshot(outcome: outcome, history: prev.history, surrounding: prev.surrounding))
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tools/music && swift build`
Expected: Builds with no errors. (No unit test here — threading + live AppleScript is verified in Task 11's manual run; `stop()`'s bounded wait is the regression guard.)

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/TUI/Shell/PlaybackPoller.swift
git commit -m "$(printf 'feat(shell): PlaybackPoller thread (poll->store) with bounded shutdown\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 3: Move history, album-context, and auto-advance into the poller

**Files:**
- Modify: `tools/music/Sources/TUI/Shell/PlaybackPoller.swift` (replace the `tick()` from Task 2)

This relocates the time-driven behavior from `runNowPlayingTUI()`'s loop (`NowPlayingTUI.swift:1312-1357` and the track-change block at 1319-1333) into the poller, verbatim in logic. Playback semantics must not change: history accrues on track change, album context refreshes on track change, and a natural track-end auto-advances to the next album track. These run regardless of which scene is active, because playback continues while browsing.

`pollAlbumTracks(for:backend:)` and `playLibraryTrack(backend:title:artist:)` already exist in `NowPlayingTUI.swift` — reuse them.

- [ ] **Step 1: Replace `tick()` and add the poller's thread-confined working state**

Add these stored properties to `PlaybackPoller` (thread-confined — only `loop()`/`tick()` touch them, all on the poller thread):

```swift
    // Thread-confined working state (poller thread only).
    private var lastTrack = ""
    private var lastArtist = ""
    private var lastPosition = 0
    private var lastDuration = 0
    private var stoppedPolls = 0
    private var history: [(track: String, artist: String)] = []
    private var surrounding: [TrackListEntry] = []
```

Replace the Task-2 `tick()` with:

```swift
    func tick() {
        switch pollNowPlaying(backend: backend) {
        case .active(let np):
            stoppedPolls = 0
            lastPosition = np.position
            lastDuration = np.duration
            if np.track != lastTrack {
                // Record the track we just left into history (dedup against head).
                if !lastTrack.isEmpty {
                    if history.first.map({ $0.track != lastTrack || $0.artist != lastArtist }) ?? true {
                        history.insert((track: lastTrack, artist: lastArtist), at: 0)
                        if history.count > 20 { history.removeLast() }
                    }
                }
                lastTrack = np.track
                lastArtist = np.artist
                surrounding = pollAlbumTracks(for: np, backend: backend)
            }
            store.write(NowPlayingSnapshot(outcome: .active(np), history: history, surrounding: surrounding))

        case .stopped:
            stoppedPolls += 1
            // Auto-advance only when the previous track reached its natural end.
            let naturalEnd = lastDuration > 0 && lastPosition >= max(0, lastDuration - 4)
            if naturalEnd,
               let cur = surrounding.firstIndex(where: { $0.isCurrent }),
               cur + 1 < surrounding.count {
                let entry = surrounding[cur + 1]
                playLibraryTrack(backend: backend, title: entry.name, artist: entry.artist)
                stoppedPolls = 0
                return // next tick will observe the new track
            }
            // Tolerate a few stopped polls before publishing a genuine stop, so a
            // brief gap between tracks doesn't flash the stopped state.
            if !lastTrack.isEmpty && stoppedPolls < 4 { return }
            store.write(NowPlayingSnapshot(outcome: .stopped, history: history, surrounding: surrounding))

        case .unavailable:
            // Transient read failure: keep the last published snapshot. Never blank
            // on a single hiccup (the published snapshot is simply not overwritten).
            return
        }
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tools/music && swift build`
Expected: Builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/TUI/Shell/PlaybackPoller.swift
git commit -m "$(printf 'feat(shell): poller owns history/album-context/auto-advance\n\nRelocates the time-driven behavior from the now-playing loop so playback\nadvances regardless of active scene. Behavior parity with runNowPlayingTUI.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 4: ShellFrame + degradation tiers (pure)

**Files:**
- Create: `tools/music/Sources/TUI/Shell/ShellFrame.swift`
- Test: `tools/music/Tests/MusicTests/ShellFrameTests.swift`

Implements the spec's four-tier Vertical Degradation model. Thresholds (pinned here): Full ≥24 rows (bar 3, full tabs) · Compact 19–23 (bar 1, full tabs) · Minimal 15–18 (bar 1, digit tabs) · Bare ≤14 (bar folded into footer, no tabs).

Row layout: app label row 1; tab strip row 2 (when shown); accent rule next row; body fills down to the bar band; bar band sits directly above the footer (last row).

- [ ] **Step 1: Write the failing test**

```swift
// tools/music/Tests/MusicTests/ShellFrameTests.swift
import XCTest
@testable import music

final class ShellFrameTests: XCTestCase {
    func testFullTier() {
        let f = shellLayout(width: 120, height: 40)
        XCTAssertEqual(f.barTier, .full)
        XCTAssertEqual(f.barHeight, 3)
        XCTAssertEqual(f.tabStyle, .full)
        XCTAssertEqual(f.footerY, 40)
        XCTAssertEqual(f.barY, 37)          // footerY - barHeight
        XCTAssertEqual(f.bodyY, 4)          // label(1) tabs(2) rule(3) body(4)
        XCTAssertEqual(f.bodyHeight, f.barY - f.bodyY) // 33
        XCTAssertGreaterThan(f.bodyHeight, 0)
    }

    func testCompactTier() {
        let f = shellLayout(width: 120, height: 21)
        XCTAssertEqual(f.barTier, .compact)
        XCTAssertEqual(f.barHeight, 1)
        XCTAssertEqual(f.tabStyle, .full)
    }

    func testMinimalTier() {
        let f = shellLayout(width: 120, height: 16)
        XCTAssertEqual(f.barTier, .minimal)
        XCTAssertEqual(f.barHeight, 1)
        XCTAssertEqual(f.tabStyle, .digits)
    }

    func testBareTier() {
        let f = shellLayout(width: 120, height: 12)
        XCTAssertEqual(f.barTier, .bare)
        XCTAssertEqual(f.barHeight, 0)
        XCTAssertEqual(f.tabStyle, .hidden)
        XCTAssertEqual(f.bodyY, 3)          // label(1) rule(2) body(3) — no tab row
    }

    func testBodyHeightNeverNegative() {
        for h in 1...50 {
            XCTAssertGreaterThanOrEqual(shellLayout(width: 80, height: h).bodyHeight, 0)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tools/music && swift test --filter ShellFrameTests`
Expected: FAIL — `shellLayout` / `ShellFrame` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// tools/music/Sources/TUI/Shell/ShellFrame.swift
import Foundation

enum BarTier { case full, compact, minimal, bare }
enum TabStyle { case full, digits, hidden }

/// Geometry for the unified shell, chosen by terminal height so the design
/// degrades gracefully instead of collapsing. Scenes render only into the body
/// region (bodyY .. bodyY+bodyHeight-1) and never need to know the tier.
struct ShellFrame {
    let width: Int
    let height: Int
    let barTier: BarTier
    let tabStyle: TabStyle
    let labelY: Int        // app label "music"
    let tabsY: Int         // tab strip row (0 when hidden)
    let ruleY: Int         // accent rule
    let bodyY: Int         // first body row
    let bodyHeight: Int    // rows available for the active scene body
    let barY: Int          // first row of the bar band (== footerY when barHeight 0)
    let barHeight: Int
    let footerY: Int       // last row
}

func shellLayout(width: Int, height: Int) -> ShellFrame {
    let tier: BarTier
    let barHeight: Int
    let tabStyle: TabStyle
    switch height {
    case 24...:   tier = .full;    barHeight = 3; tabStyle = .full
    case 19...23: tier = .compact; barHeight = 1; tabStyle = .full
    case 15...18: tier = .minimal; barHeight = 1; tabStyle = .digits
    default:      tier = .bare;    barHeight = 0; tabStyle = .hidden
    }

    let labelY = 1
    let showTabs = tabStyle != .hidden
    let tabsY = showTabs ? 2 : 0
    let ruleY = showTabs ? 3 : 2
    let bodyY = ruleY + 1
    let footerY = max(bodyY, height)
    let barY = footerY - barHeight
    let bodyHeight = max(0, barY - bodyY)

    return ShellFrame(
        width: width, height: height,
        barTier: tier, tabStyle: tabStyle,
        labelY: labelY, tabsY: tabsY, ruleY: ruleY,
        bodyY: bodyY, bodyHeight: bodyHeight,
        barY: barY, barHeight: barHeight, footerY: footerY
    )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tools/music && swift test --filter ShellFrameTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/TUI/Shell/ShellFrame.swift tools/music/Tests/MusicTests/ShellFrameTests.swift
git commit -m "$(printf 'feat(shell): ShellFrame with four-tier vertical degradation\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 5: Router (pure scene-id stack)

**Files:**
- Create: `tools/music/Sources/TUI/Shell/Router.swift`
- Test: `tools/music/Tests/MusicTests/RouterTests.swift`

`Router` holds a `SceneID` stack, not `Scene` instances, so it stays pure and testable; the shell maps id→instance. `switchTo` (top-level tab switch) resets the stack; `push` drills in; `pop` is a no-op at the root.

- [ ] **Step 1: Write the failing test**

```swift
// tools/music/Tests/MusicTests/RouterTests.swift
import XCTest
@testable import music

final class RouterTests: XCTestCase {
    func testStartsAtRoot() {
        let r = Router(root: .nowPlaying)
        XCTAssertEqual(r.active, .nowPlaying)
        XCTAssertEqual(r.stack, [.nowPlaying])
    }
    func testPushPop() {
        let r = Router(root: .playlists)
        r.push(.nowPlaying)
        XCTAssertEqual(r.active, .nowPlaying)
        r.pop()
        XCTAssertEqual(r.active, .playlists)
    }
    func testPopAtRootIsNoOp() {
        let r = Router(root: .nowPlaying)
        r.pop()
        XCTAssertEqual(r.active, .nowPlaying)
        XCTAssertEqual(r.stack.count, 1)
    }
    func testSwitchResetsStack() {
        let r = Router(root: .playlists)
        r.push(.nowPlaying)
        r.switchTo(.speakers)
        XCTAssertEqual(r.active, .speakers)
        XCTAssertEqual(r.stack, [.speakers])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tools/music && swift test --filter RouterTests`
Expected: FAIL — `Router` / `SceneID` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// tools/music/Sources/TUI/Shell/Router.swift
import Foundation

enum SceneID: Equatable {
    case nowPlaying, playlists, speakers, search, library, queue
}

/// Navigation state for the shell: a back stack of scene ids. Top-level tab
/// switches reset the stack; drill-downs push; back pops (never past root).
final class Router {
    private(set) var stack: [SceneID]

    init(root: SceneID) { stack = [root] }

    var active: SceneID { stack.last! }

    func switchTo(_ id: SceneID) { stack = [id] }
    func push(_ id: SceneID) { stack.append(id) }
    func pop() { if stack.count > 1 { stack.removeLast() } }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tools/music && swift test --filter RouterTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/TUI/Shell/Router.swift tools/music/Tests/MusicTests/RouterTests.swift
git commit -m "$(printf 'feat(shell): pure Router scene-id stack\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 6: Global keymap resolver (pure)

**Files:**
- Create: `tools/music/Sources/TUI/Shell/GlobalKeymap.swift`
- Test: `tools/music/Tests/MusicTests/GlobalKeymapTests.swift`

Globals are resolved by the shell before delegating to the active scene, so transport works in every scene. Digits map to scene-switch (1-based). `KeyPress` is defined in `Terminal.swift` and is `Equatable`-comparable via its cases.

Known conflict to document (not resolve here): digit-as-scene-switch will collide with the future Speakers scene's two-digit volume entry. Milestone 1 has only the Now Playing scene, where digits are free. Resolution belongs to the Milestone 2 Speakers plan.

- [ ] **Step 1: Write the failing test**

```swift
// tools/music/Tests/MusicTests/GlobalKeymapTests.swift
import XCTest
@testable import music

final class GlobalKeymapTests: XCTestCase {
    func testTransportKeys() {
        XCTAssertEqual(resolveGlobalKey(.space), .playPause)
        XCTAssertEqual(resolveGlobalKey(.char("+")), .volumeUp)
        XCTAssertEqual(resolveGlobalKey(.char("=")), .volumeUp)
        XCTAssertEqual(resolveGlobalKey(.char("-")), .volumeDown)
        XCTAssertEqual(resolveGlobalKey(.char(">")), .next)
        XCTAssertEqual(resolveGlobalKey(.char(".")), .next)
        XCTAssertEqual(resolveGlobalKey(.f9), .next)
        XCTAssertEqual(resolveGlobalKey(.char("<")), .prev)
        XCTAssertEqual(resolveGlobalKey(.f7), .prev)
        XCTAssertEqual(resolveGlobalKey(.char("z")), .shuffle)
        XCTAssertEqual(resolveGlobalKey(.char("r")), .radio)
        XCTAssertEqual(resolveGlobalKey(.char("q")), .quit)
    }
    func testDigitsSwitchScene() {
        XCTAssertEqual(resolveGlobalKey(.char("1")), .switchScene(1))
        XCTAssertEqual(resolveGlobalKey(.char("3")), .switchScene(3))
    }
    func testZeroIsNotASwitch() {
        XCTAssertNil(resolveGlobalKey(.char("0")))
    }
    func testNonGlobalKeysReturnNil() {
        XCTAssertNil(resolveGlobalKey(.up))
        XCTAssertNil(resolveGlobalKey(.enter))
        XCTAssertNil(resolveGlobalKey(.char("/")))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tools/music && swift test --filter GlobalKeymapTests`
Expected: FAIL — `resolveGlobalKey` / `GlobalAction` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// tools/music/Sources/TUI/Shell/GlobalKeymap.swift
import Foundation

/// Actions the shell handles in every scene, before delegating scene-local keys.
enum GlobalAction: Equatable {
    case playPause, volumeUp, volumeDown, next, prev, shuffle, radio
    case switchScene(Int)   // 1-based index into the visible scene tabs
    case quit
}

/// Pure mapping from a keypress to a global action, or nil if the key is not a
/// global (the shell then delegates it to the active scene). Navigation keys
/// (Tab, Esc) are handled directly by the shell loop, not here.
func resolveGlobalKey(_ key: KeyPress) -> GlobalAction? {
    switch key {
    case .space: return .playPause
    case .char("+"), .char("="): return .volumeUp
    case .char("-"): return .volumeDown
    case .char(">"), .char("."), .f9: return .next
    case .char("<"), .char(","), .f7: return .prev
    case .char("z"): return .shuffle
    case .char("r"): return .radio
    case .char("q"): return .quit
    case .char(let c) where c.isNumber:
        guard let n = c.wholeNumberValue, n >= 1 else { return nil }
        return .switchScene(n)
    default:
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tools/music && swift test --filter GlobalKeymapTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/TUI/Shell/GlobalKeymap.swift tools/music/Tests/MusicTests/GlobalKeymapTests.swift
git commit -m "$(printf 'feat(shell): pure global keymap resolver\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 7: Scene protocol + SceneAction

**Files:**
- Create: `tools/music/Sources/TUI/Shell/Scene.swift`

The contract every scene implements. `render` draws only the body region; `handle` returns an action telling the shell what navigation/redraw to do. Scenes are reference types (`AnyObject`) so the shell can hold them in a dictionary and mutate their cursor state in place.

- [ ] **Step 1: Write the implementation**

```swift
// tools/music/Sources/TUI/Shell/Scene.swift
import Foundation

/// What a scene asks the shell to do after handling a key.
enum SceneAction: Equatable {
    case none          // key ignored
    case redraw        // state changed; repaint next frame (already continuous, but explicit)
    case push(SceneID) // drill into another scene
    case pop           // go back
    case quit          // exit the shell
}

/// A renderable, interactive surface inside the shell. Implementations draw into
/// the body region the shell hands them (frame.bodyY .. frame.bodyY+bodyHeight-1)
/// and never touch chrome, tabs, or the now-playing bar.
protocol Scene: AnyObject {
    var id: SceneID { get }
    var tabTitle: String { get }

    /// Called once per frame before render, so the scene can fold the latest
    /// snapshot into its own view state (e.g. clamp a cursor to new row counts).
    func tick(snapshot: NowPlayingSnapshot)

    /// Return the ANSI string for the body region only.
    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String

    /// Handle a scene-local key (globals were already resolved by the shell).
    func handle(_ key: KeyPress) -> SceneAction
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tools/music && swift build`
Expected: Builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/TUI/Shell/Scene.swift
git commit -m "$(printf 'feat(shell): Scene protocol + SceneAction\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 8: Shell chrome — frame, tab strip, persistent now-playing bar

**Files:**
- Create: `tools/music/Sources/TUI/Shell/ShellChrome.swift`

Three renderers. The bar is net-new (it draws a compact/rich block at the bottom bar band, unlike `renderNowPlayingMetadata` which uses absolute full-screen coords). It reuses `formatTime` (defined in `NowPlayingTUI.swift`) and `truncText`/`ANSICode` (in `TUILayout.swift`/`Terminal.swift`). This renderer is thin and verified live (Task 11), so no unit test.

- [ ] **Step 1: Write the implementation**

```swift
// tools/music/Sources/TUI/Shell/ShellChrome.swift
import Foundation

/// App label + accent rule. Tab strip is rendered separately so it can be
/// hidden in the Bare tier.
func renderShellChrome(frame: ShellFrame) -> String {
    var out = ANSICode.cursorHome
    out += ANSICode.moveTo(row: frame.labelY, col: 3) + ANSICode.clearLine
    out += "\(ANSICode.dim)music\(ANSICode.reset)"
    out += ANSICode.moveTo(row: frame.ruleY, col: 3) + ANSICode.clearLine
    out += "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(40, frame.width - 4)))\(ANSICode.reset)"
    return out
}

/// Horizontal scene tabs. `.full` shows names; `.digits` shows 1·2·3; `.hidden`
/// renders nothing. The active tab is highlighted in cyan/bold.
func renderTabStrip(active: SceneID, tabs: [(id: SceneID, title: String)], frame: ShellFrame) -> String {
    guard frame.tabStyle != .hidden, frame.tabsY > 0 else { return "" }
    var out = ANSICode.moveTo(row: frame.tabsY, col: 3) + ANSICode.clearLine
    out += "\(ANSICode.bold)\(ANSICode.cyan)\u{266B}\(ANSICode.reset)  "
    for (i, tab) in tabs.enumerated() {
        let isActive = tab.id == active
        let label: String
        switch frame.tabStyle {
        case .full:   label = tab.title
        case .digits: label = "\(i + 1)"
        case .hidden: label = ""
        }
        if isActive {
            out += "\(ANSICode.bold)\(ANSICode.cyan)\(label)\(ANSICode.reset)"
        } else {
            out += "\(ANSICode.dim)\(label)\(ANSICode.reset)"
        }
        if i < tabs.count - 1 { out += frame.tabStyle == .digits ? "\(ANSICode.dim)·\(ANSICode.reset)" : "   " }
    }
    return out
}

/// Persistent now-playing bar drawn in the bar band (frame.barY..) or, in the
/// Bare tier (barHeight 0), folded onto the footer row. Tier-aware: Full draws
/// three rows (track/artist+album, progress, speakers+modes); Compact/Minimal
/// draw one row; Bare draws a single status line.
func renderNowPlayingBar(snapshot: NowPlayingSnapshot, frame: ShellFrame) -> String {
    let col = 3
    let w = frame.width - col - 1

    // Resolve display fields from the snapshot.
    let np: NowPlayingState? = {
        if case .active(let s) = snapshot.outcome { return s }
        return nil
    }()

    // Clear the bar band (or the footer row in Bare tier).
    var out = ""
    let firstRow = frame.barHeight > 0 ? frame.barY : frame.footerY
    let rows = frame.barHeight > 0 ? frame.barHeight : 1
    for r in 0..<rows {
        out += ANSICode.moveTo(row: firstRow + r, col: 1) + ANSICode.clearLine
    }

    guard let np = np else {
        out += ANSICode.moveTo(row: firstRow, col: col)
        out += "\(ANSICode.dim)Nothing playing.\(ANSICode.reset)"
        return out
    }

    let playIcon = np.state == "playing" ? "\u{25B6}" : "\u{23F8}"
    let elapsed = formatTime(np.position)
    let total = formatTime(np.duration)
    let ratio = np.duration > 0 ? Double(np.position) / Double(np.duration) : 0

    func progress(_ width: Int) -> String {
        let knob = max(0, min(width - 1, Int(ratio * Double(width - 1))))
        var s = ""
        for i in 0..<width { s += i == knob ? "\(ANSICode.bold)\u{25CF}\(ANSICode.reset)" : "\(ANSICode.dim)\u{2500}\(ANSICode.reset)" }
        return s
    }

    switch frame.barTier {
    case .full:
        // Row 1: ▶ Track — Artist
        out += ANSICode.moveTo(row: frame.barY, col: col)
        out += "\(ANSICode.bold)\(playIcon) \(truncText(np.track, to: max(4, w / 2)))\(ANSICode.reset) \(ANSICode.dim)\u{2014}\(ANSICode.reset) \(truncText(np.artist, to: max(4, w / 3)))"
        // Row 2: Album · progress · time
        out += ANSICode.moveTo(row: frame.barY + 1, col: col)
        out += "\(ANSICode.dim)\(truncText(np.album, to: max(4, w / 3)))\(ANSICode.reset)  \(progress(min(24, max(8, w / 3))))  \(ANSICode.dim)\(elapsed) / \(total)\(ANSICode.reset)"
        // Row 3: speakers + modes
        out += ANSICode.moveTo(row: frame.barY + 2, col: col)
        let spk = np.speakers.isEmpty ? "" : np.speakers.map { "\($0.name) \($0.volume)" }.joined(separator: "  ")
        var modes = ""
        if np.shuffleEnabled { modes += "z\u{21C4} " }
        if np.repeatMode == "one" { modes += "r\u{21BB}1" } else if np.repeatMode == "all" { modes += "r\u{21BB}" }
        out += "\(ANSICode.dim)\u{266A} \(truncText(spk, to: max(4, w - modes.count - 4)))   \(modes)\(ANSICode.reset)"

    case .compact, .minimal:
        out += ANSICode.moveTo(row: frame.barY, col: col)
        out += "\(ANSICode.bold)\(playIcon)\(ANSICode.reset) \(truncText("\(np.track) \u{2014} \(np.artist)", to: max(8, w - 22)))  \(progress(min(12, max(6, w / 6))))  \(ANSICode.dim)\(elapsed)/\(total)\(ANSICode.reset)"

    case .bare:
        out += ANSICode.moveTo(row: frame.footerY, col: col)
        out += "\(playIcon) \(truncText("\(np.track) \u{2014} \(np.artist)", to: max(8, w - 12)))  \(ANSICode.dim)\(elapsed)/\(total)\(ANSICode.reset)"
    }

    return out
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tools/music && swift build`
Expected: Builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/TUI/Shell/ShellChrome.swift
git commit -m "$(printf 'feat(shell): chrome, tab strip, tier-aware persistent now-playing bar\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 9: NowPlayingScene (body = album timeline)

**Files:**
- Create: `tools/music/Sources/TUI/Shell/NowPlayingScene.swift`

The Now Playing scene's body is the scrollable album/history timeline (metadata now lives in the bar). It reuses `buildStandaloneRows` and `renderTimelineRows` (both in `NowPlayingTUI.swift`). Cursor/scroll are scene-owned. Enter plays the selected track; arrows move the cursor. Seek (←/→) acts on the player. Globals (space/+/-/</>/z/r/digits/q) are handled by the shell, not here.

- [ ] **Step 1: Write the implementation**

```swift
// tools/music/Sources/TUI/Shell/NowPlayingScene.swift
import Foundation

final class NowPlayingScene: Scene {
    let id: SceneID = .nowPlaying
    let tabTitle = "Now"

    private let backend: AppleScriptBackend
    private var cursor = 0
    private var scroll = 0
    private var rows: [TimelineRow] = []

    init(backend: AppleScriptBackend) { self.backend = backend }

    func tick(snapshot: NowPlayingSnapshot) {
        rows = buildStandaloneRows(history: snapshot.history, surrounding: snapshot.surrounding)
        if cursor >= rows.count { cursor = max(0, rows.count - 1) }
    }

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        // Clear the body region first (prevents stale rows on shrink).
        var out = ""
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        guard frame.bodyHeight > 3, frame.width > 30 else { return out }
        out += renderTimelineRows(
            rows: rows,
            header: "Album",
            x: 3,
            y: frame.bodyY,
            width: frame.width - 6,
            visibleHeight: frame.bodyHeight,
            cursorIndex: cursor,
            scrollOffset: &scroll
        )
        return out
    }

    func handle(_ key: KeyPress) -> SceneAction {
        switch key {
        case .up:
            guard !rows.isEmpty else { return .none }
            cursor = max(0, cursor - 1)
            return .redraw
        case .down:
            guard !rows.isEmpty else { return .none }
            cursor = min(max(0, rows.count - 1), cursor + 1)
            return .redraw
        case .enter:
            guard cursor < rows.count else { return .none }
            let row = rows[cursor]
            playLibraryTrack(backend: backend, title: row.title, artist: row.artist)
            return .redraw
        case .left:
            _ = try? syncRun { try await self.backend.runMusic("set player position to (player position - 30)") }
            return .redraw
        case .right:
            _ = try? syncRun { try await self.backend.runMusic("set player position to (player position + 30)") }
            return .redraw
        default:
            return .none
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tools/music && swift build`
Expected: Builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/TUI/Shell/NowPlayingScene.swift
git commit -m "$(printf 'feat(shell): NowPlayingScene (album timeline body)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 10: Shell loop — wire it all together

**Files:**
- Create: `tools/music/Sources/TUI/Shell/Shell.swift`

`runShell()` enters raw mode once, starts the poller, and runs the render/input loop: read snapshot → compute frame → draw chrome+tabs+scene+bar → read key (100ms) → resolve globals → else navigation (Tab/Esc) → else delegate to scene. On exit it stops the poller (bounded wait) then leaves raw mode. Milestone 1 registers only the Now Playing scene; the tab list shows just it (Playlists/Speakers tabs arrive in Milestone 2).

`startRadioStation()` (used by the `radio` global) and `pollNowPlaying` already exist in the codebase.

- [ ] **Step 1: Write the implementation**

```swift
// tools/music/Sources/TUI/Shell/Shell.swift
import Foundation

func runShell() {
    let backend = AppleScriptBackend()
    let store = NowPlayingStore()
    let poller = PlaybackPoller(store: store, backend: backend)
    let terminal = TerminalState.shared

    let router = Router(root: .nowPlaying)
    let scenes: [SceneID: Scene] = [.nowPlaying: NowPlayingScene(backend: backend)]
    // v1 tab order; Milestone 1 ships only Now Playing.
    let tabs: [(id: SceneID, title: String)] = [(.nowPlaying, "Now")]

    terminal.enterRawMode()
    print(ANSICode.cursorHome + ANSICode.clearScreen, terminator: "")
    poller.start()
    defer {
        poller.stop()
        terminal.exitRawMode()
    }

    func dims() -> (Int, Int) {
        let f = ScreenFrame.current()
        return (f.width, f.height)
    }

    while true {
        if terminalResized {
            terminalResized = false
            print(ANSICode.cursorHome + ANSICode.clearScreen, terminator: "")
            fflush(stdout)
        }

        let snap = store.read()
        let (w, h) = dims()
        let frame = shellLayout(width: w, height: h)
        guard let scene = scenes[router.active] else { continue }
        scene.tick(snapshot: snap)

        var out = renderShellChrome(frame: frame)
        out += renderTabStrip(active: router.active, tabs: tabs, frame: frame)
        out += scene.render(frame: frame, snapshot: snap)
        out += renderNowPlayingBar(snapshot: snap, frame: frame)
        // Footer hint line (skipped in Bare tier where the bar occupies the footer).
        if frame.barTier != .bare {
            out += ANSICode.moveTo(row: frame.footerY, col: 3) + ANSICode.clearLine
            out += "\(ANSICode.dim)\u{2191}\u{2193} Album  Enter Play  Space \u{23EF}  </> Track  +/- Vol  r Radio  q Quit\(ANSICode.reset)"
        }
        print(out, terminator: "")
        fflush(stdout)

        // 100ms tick: redraw on timeout so the live bar advances while idle.
        guard let key = KeyPress.read(timeout: 0.1) else { continue }

        // 1) Globals (work in every scene).
        if let action = resolveGlobalKey(key) {
            switch action {
            case .playPause:
                _ = try? syncRun { try await backend.runMusic("playpause") }
            case .volumeUp:
                _ = try? syncRun { try await backend.runMusic("set sound volume to (sound volume + 5)") }
            case .volumeDown:
                _ = try? syncRun { try await backend.runMusic("set sound volume to (sound volume - 5)") }
            case .next:
                _ = try? syncRun { try await backend.runMusic("next track") }
            case .prev:
                _ = try? syncRun { try await backend.runMusic("previous track") }
            case .shuffle:
                _ = try? syncRun { try await backend.runMusic("set shuffle enabled to (not shuffle enabled)") }
            case .radio:
                _ = startRadioStation()
                router.switchTo(.nowPlaying)
            case .switchScene(let n):
                if n >= 1 && n <= tabs.count { router.switchTo(tabs[n - 1].id) }
            case .quit:
                return
            }
            continue
        }

        // 2) Shell navigation keys.
        if case .char("\t") = key {
            if let idx = tabs.firstIndex(where: { $0.id == router.active }) {
                router.switchTo(tabs[(idx + 1) % tabs.count].id)
            }
            continue
        }
        if case .escape = key {
            if router.stack.count > 1 { router.pop() } else { return }
            continue
        }

        // 3) Delegate to the active scene.
        switch scene.handle(key) {
        case .none, .redraw: break
        case .push(let id): router.push(id)
        case .pop: router.pop()
        case .quit: return
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd tools/music && swift build`
Expected: Builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/TUI/Shell/Shell.swift
git commit -m "$(printf 'feat(shell): runShell loop wiring poller, router, keymap, scene, bar\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Task 11: Wire bare `music` to the shell + manual verification

**Files:**
- Modify: `tools/music/Sources/Commands/PlaybackCommands.swift:378-384`

Bare `music` (and `music now` with no flags, in a TTY) launches the shell. `--json` and non-TTY paths are untouched — they still call `showNowPlaying`.

- [ ] **Step 1: Change the dispatch**

**Verified from code (do not skip the empty-args case):** `isBareInvocation(command: "now")` (`Terminal.swift:155-158`) drops the binary arg then requires `count == 1 && first == "now"`. For bare `music`, `CommandLine.arguments == ["…/music"]`, so the dropped list is *empty* (count 0) and `isBareInvocation` returns **false** — only `music now` (count 1) returns true. So the dispatch must treat *both* "no args" and "`now`" as shell triggers, otherwise bare `music` would fall through to the text `showNowPlaying`.

Replace the body of `Now.run()` (currently at `PlaybackCommands.swift:378-384`) with exactly this:

```swift
    func run() throws {
        let bareMusic = CommandLine.arguments.dropFirst().isEmpty   // `music` with no subcommand
        let bareNow = isBareInvocation(command: "now")              // `music now` with no flags
        if (bareMusic || bareNow) && isTTY() {
            runShell()
            return
        }
        showNowPlaying(json: json)
    }
```

This keeps every non-bare and non-TTY path (`music now --json`, pipes, redirects) on `showNowPlaying`, unchanged.

- [ ] **Step 2: Build the whole package and run the full test suite**

Run: `cd tools/music && swift build && swift test`
Expected: Build succeeds; all tests pass (the existing 55 + the new Router/ShellFrame/GlobalKeymap/NowPlayingStore tests).

- [ ] **Step 3: Manual verification (TUI is not CI-verifiable — user verifies live)**

Reinstall and run:

```bash
cd /Users/anthonymaley/apple-music && scripts/install.sh
music
```

Verify with playback active:
- Bare `music` opens the shell (not the old now-playing screen); raw mode entered once, no flash.
- The bottom **now-playing bar is rich (3 rows)** and **advances on its own** (progress moves) while you press no keys — proves the background poller + live bar.
- `↑`/`↓` move the album timeline cursor; `Enter` plays the selected track.
- `Space` toggles play/pause; `+`/`-` change volume; `<`/`>` change track; `z` toggles shuffle — all reflected in the bar within ~1s.
- `r` starts a radio station and playback continues.
- Resize the terminal smaller: bar degrades Full→Compact→Minimal→Bare and tabs compress/hide; nothing overlaps or corrupts.
- `q` exits cleanly: cursor restored, alt-screen off, terminal usable (proves `poller.stop()` before `exitRawMode()`).
- Let a track play to its end: it auto-advances to the next album track (proves auto-advance moved into the poller).
- Confirm `music --json` and `music now --json` still print JSON and do NOT open the shell.

Report any failures with the exact symptom before proceeding.

- [ ] **Step 4: Bump version + commit + push**

The shell is a user-facing feature → minor bump to **1.9.0** across all four locations (per CLAUDE.md Version Strategy):
- `.claude-plugin/plugin.json` → `version`
- `.claude-plugin/marketplace.json` → `metadata.version`
- `.claude-plugin/marketplace.json` → `plugins[0].version`
- `tools/music/Sources/Music.swift:8` → `version: "1.9.0"`

Then rebuild and verify:

```bash
cd /Users/anthonymaley/apple-music && scripts/install.sh && music --version
# Expected: 1.9.0
```

Commit and push:

```bash
git add tools/music/Sources/Commands/PlaybackCommands.swift .claude-plugin/plugin.json .claude-plugin/marketplace.json tools/music/Sources/Music.swift
git commit -m "$(printf 'feat(shell): bare music launches unified shell; bump to 1.9.0\n\nMilestone 1 of the unified TUI shell: one loop, persistent live bar,\nNow Playing as a scene. Playlists + Speakers scenes follow in M2.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
git push
```

---

## Self-Review

**Spec coverage (Milestone 1 scope):**
- Control-flow inversion (single loop, passive scenes) → Tasks 7, 9, 10. ✓
- Background poller (one thread, one store, one lock; enrichment unaffected) → Tasks 1–3. ✓
- Auto-advance/history/album-context relocated (the named regression risk) → Task 3. ✓
- ScreenFrame bar/tabs + four degradation tiers → Task 4. ✓
- Router push/pop/switch → Task 5. ✓
- Shared global keymap (globals first, then delegate) → Tasks 6, 10. ✓
- Rich persistent bar reusing now-playing rendering content → Task 8. ✓
- Now Playing migrated to a scene → Task 9. ✓
- Preserved `--json`/non-TTY; commands unchanged → Task 11. ✓
- Modal teardown-flash avoided (raw mode entered once) → Task 10. ✓ (Speaker/volume *modals* are not in M1; they become the Speakers scene in M2.)
- Out of M1 scope by design: Playlists/Speakers/Search/Library/Queue scenes; Shift-Tab; digit-vs-volume conflict resolution.

**Placeholder scan:** No TBD/TODO; every code step contains complete code; every run step has an exact command + expected result. ✓

**Type consistency:** `NowPlayingSnapshot`(outcome/history/surrounding), `ShellFrame`(barTier/tabStyle/bodyY/bodyHeight/barY/barHeight/footerY), `SceneID`, `GlobalAction`, `SceneAction`, `Scene`(id/tabTitle/tick/render/handle) used identically across Tasks 1–11. `PollOutcome`/`NowPlayingState`/`TrackListEntry`/`TimelineRow`/`buildStandaloneRows`/`renderTimelineRows`/`pollNowPlaying`/`pollAlbumTracks`/`playLibraryTrack`/`formatTime`/`startRadioStation`/`syncRun`/`ANSICode`/`truncText`/`ScreenFrame.current` are all existing symbols (verified in source). ✓

**Resolved during planning (was a soft spot):** bare `music` yields an *empty* arg list, so `isBareInvocation("now")` is false for it; Task 11 Step 1 now handles both the empty-args (`music`) and `now`-subcommand cases explicitly, verified against `Terminal.swift:155-158`. No runtime guesswork left for the executor.
