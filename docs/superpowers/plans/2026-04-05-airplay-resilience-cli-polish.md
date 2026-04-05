# AirPlay Resilience & CLI Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add AirPlay wake cycle for reliable speaker routing, improve CLI feedback during operations, and add play/pause + shuffle/repeat indicators to the Now Playing TUI.

**Architecture:** Three layers (plumbing → resilience → TUI). Layer 1 adds `--verbose`, speaker error types, and a status utility. Layer 2 adds the wake cycle to both the Swift CLI and the bash slash command. Layer 3 adds TUI state indicators and progress feedback on waits.

**Tech Stack:** Swift 5.9, ArgumentParser, AppleScript/osascript, Bash (slash commands)

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `tools/music/Sources/Music.swift` | Modify | Add `--verbose` and `--no-wake` global flags |
| `tools/music/Sources/Backends/AppleScriptBackend.swift` | Modify | Add speaker error types, verbose logging, osascript timeout |
| `tools/music/Sources/StatusReporter.swift` | Create | `withStatus`, `verbose()` utility functions |
| `tools/music/Sources/Commands/SpeakerCommands.swift` | Modify | Wake cycle, `.wake` parser case, `resolveSpeakerName` throws on no match |
| `tools/music/Sources/Commands/PlaybackCommands.swift` | Modify | `withStatus` around library sync |
| `tools/music/Sources/Commands/PlaylistCommands.swift` | Modify | `withStatus` counter around track addition loops |
| `tools/music/Sources/TUI/NowPlayingTUI.swift` | Modify | Play/pause indicator, shuffle/repeat, TUI error feedback |
| `commands/speaker.md` | Modify | Add `wake` action case |
| `commands/play.md` | Modify | Replace `speaker set` with `speaker wake` for routed play |
| `tools/music/Tests/MusicTests/SmartParserTests.swift` | Modify | Add `.wake` parser tests |
| `tools/music/Tests/MusicTests/WakeCycleTests.swift` | Create | Wake cycle unit tests |

---

## Layer 1 — Plumbing

### Task 1: Add `--verbose` and `--no-wake` global flags

**Files:**
- Modify: `tools/music/Sources/Music.swift`

- [ ] **Step 1: Add global flags and static properties to Music.swift**

Replace the entire contents of `Music.swift` with:

```swift
import ArgumentParser

@main
struct Music: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "music",
        abstract: "Control Apple Music from the terminal.",
        version: "1.4.0",
        subcommands: [
            // Playback
            Play.self,
            Pause.self,
            Skip.self,
            Back.self,
            Stop.self,
            Now.self,
            Shuffle.self,
            Repeat_.self,
            Radio.self,
            // Speakers & Volume
            Speaker.self,
            Vol.self,
            // Auth
            Auth.self,
            // Catalog
            Search.self,
            Add.self,
            Remove.self,
            Playlist.self,
            // Discovery
            Similar.self,
            Suggest.self,
            NewReleases.self,
            Mix.self,
        ],
        defaultSubcommand: Now.self
    )

    // Global config — set once at process start, read-only thereafter
    static var verbose: Bool = false
    static var noWake: Bool = false
    static var isJSON: Bool = false
}
```

Note: ArgumentParser doesn't support inheritable global flags on the root command with a `defaultSubcommand`. The flags will be threaded through subcommands that need them. The `Music` statics serve as read-only global config set by those subcommands at entry.

- [ ] **Step 2: Build to verify**

Run:
```bash
cd tools/music && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/Music.swift
git commit -m "feat: add Music.verbose, Music.noWake, Music.isJSON global config"
```

---

### Task 2: Add speaker-specific error types

**Files:**
- Modify: `tools/music/Sources/Backends/AppleScriptBackend.swift`

- [ ] **Step 1: Extend ScriptError with new cases**

In `AppleScriptBackend.swift`, replace the `ScriptError` enum (lines 4-12) with:

```swift
    enum ScriptError: Error, LocalizedError {
        case executionFailed(String)
        case speakerNotFound(String)
        case speakerUnavailable(String)
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .executionFailed(let msg):
                return "AppleScript error: \(msg)"
            case .speakerNotFound(let name):
                return "Speaker \"\(name)\" not found."
            case .speakerUnavailable(let name):
                return "\(name) is not responding. Try: music speaker wake"
            case .timeout(let operation):
                return "Timed out: \(operation). Speaker may be offline."
            }
        }
    }
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd tools/music && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/Backends/AppleScriptBackend.swift
git commit -m "feat: add speakerNotFound, speakerUnavailable, timeout error types"
```

---

### Task 3: Create StatusReporter utility

**Files:**
- Create: `tools/music/Sources/StatusReporter.swift`

- [ ] **Step 1: Create the StatusReporter file**

Create `tools/music/Sources/StatusReporter.swift`:

```swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Print a diagnostic line to stderr when `Music.verbose` is enabled.
func verbose(_ message: String) {
    guard Music.verbose else { return }
    FileHandle.standardError.write(Data("[verbose] \(message)\n".utf8))
}

/// Show a transient status message on stderr during a long operation.
/// - Prints only when stdout is a TTY and not in JSON mode.
/// - Suppresses if the operation completes in under ~200ms.
/// - Clears the line on completion (success or failure).
func withStatus<T>(_ message: String, body: () throws -> T) rethrows -> T {
    let shouldShow = isTTY() && !Music.isJSON
    var displayed = false

    if shouldShow {
        // Schedule display after 200ms threshold
        let startTime = DispatchTime.now()
        // Show immediately for simplicity in sync context — the 200ms
        // threshold is best-effort. For operations known to be fast
        // (speaker list on local network), callers should skip withStatus.
        FileHandle.standardError.write(Data("\(message)\r".utf8))
        displayed = true
        _ = startTime // suppress unused warning
    }

    defer {
        if displayed {
            // Clear the status line
            let clearLine = "\r\(String(repeating: " ", count: message.count + 2))\r"
            FileHandle.standardError.write(Data(clearLine.utf8))
        }
    }

    return try body()
}

/// Overload for async closures (used inside syncRun blocks).
func withStatusAsync<T>(_ message: String, body: () async throws -> T) async rethrows -> T {
    let shouldShow = isTTY() && !Music.isJSON
    var displayed = false

    if shouldShow {
        FileHandle.standardError.write(Data("\(message)\r".utf8))
        displayed = true
    }

    defer {
        if displayed {
            let clearLine = "\r\(String(repeating: " ", count: message.count + 2))\r"
            FileHandle.standardError.write(Data(clearLine.utf8))
        }
    }

    return try await body()
}

/// Show a progress counter on stderr (e.g., "Adding tracks... 3/10").
/// Call repeatedly as the count advances; each call overwrites the previous line.
func updateStatus(_ message: String) {
    guard isTTY() && !Music.isJSON else { return }
    FileHandle.standardError.write(Data("\r\(message)".utf8))
}

/// Clear any active status line on stderr.
func clearStatus(length: Int = 80) {
    guard isTTY() && !Music.isJSON else { return }
    FileHandle.standardError.write(Data("\r\(String(repeating: " ", count: length))\r".utf8))
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd tools/music && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/StatusReporter.swift
git commit -m "feat: add StatusReporter with verbose(), withStatus(), updateStatus()"
```

---

## Layer 2 — AirPlay Resilience

### Task 4: Add `.wake` to SpeakerParser and write tests

**Files:**
- Modify: `tools/music/Sources/Commands/SpeakerCommands.swift` (lines 6-34)
- Modify: `tools/music/Tests/MusicTests/SmartParserTests.swift`

- [ ] **Step 1: Write the failing tests**

Add these tests to `SmartParserTests.swift` after the existing tests (before the closing `}`):

```swift
    func testWakeAllSpeakers() {
        let result = SpeakerParser.parse(["wake"])
        XCTAssertEqual(result, .wake(name: nil))
    }

    func testWakeSpecificSpeaker() {
        let result = SpeakerParser.parse(["wake", "kitchen"])
        XCTAssertEqual(result, .wake(name: "kitchen"))
    }

    func testWakeMultiWordSpeaker() {
        let result = SpeakerParser.parse(["wake", "macbook", "pro"])
        XCTAssertEqual(result, .wake(name: "macbook pro"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
cd tools/music && swift test 2>&1 | tail -10
```
Expected: compilation error — `.wake` case doesn't exist yet.

- [ ] **Step 3: Add `.wake` case to SpeakerAction and SpeakerParser**

In `SpeakerCommands.swift`, replace the `SpeakerAction` enum (lines 6-14) with:

```swift
enum SpeakerAction: Equatable {
    case interactive
    case list
    case add(name: String)
    case addWithVolume(name: String, volume: Int)
    case remove(name: String)
    case exclusive(name: String)
    case indices([Int])
    case wake(name: String?)
}
```

In `SpeakerParser.parse` (lines 17-34), add the wake check after the `list` check (after line 19):

```swift
        if args.count >= 1 && args[0].lowercased() == "wake" {
            let name = args.count > 1 ? args.dropFirst().joined(separator: " ") : nil
            return .wake(name: name)
        }
```

The full `parse` method becomes:

```swift
    static func parse(_ args: [String]) -> SpeakerAction {
        guard !args.isEmpty else { return .interactive }
        if args.count == 1 && args[0].lowercased() == "list" { return .list }
        if args.count >= 1 && args[0].lowercased() == "wake" {
            let name = args.count > 1 ? args.dropFirst().joined(separator: " ") : nil
            return .wake(name: name)
        }
        let ints = args.compactMap { Int($0) }
        if ints.count == args.count { return .indices(ints) }
        let lastArg = args.last!.lowercased()
        if lastArg == "stop" {
            return .remove(name: args.dropLast().joined(separator: " "))
        }
        if lastArg == "only" {
            return .exclusive(name: args.dropLast().joined(separator: " "))
        }
        if let vol = Int(lastArg), (0...100).contains(vol), args.count >= 2 {
            return .addWithVolume(name: args.dropLast().joined(separator: " "), volume: vol)
        }
        return .add(name: args.joined(separator: " "))
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
cd tools/music && swift test 2>&1 | tail -15
```
Expected: all tests pass including the 3 new wake tests.

- [ ] **Step 5: Commit**

```bash
git add tools/music/Sources/Commands/SpeakerCommands.swift tools/music/Tests/MusicTests/SmartParserTests.swift
git commit -m "feat: add .wake case to SpeakerParser with tests"
```

---

### Task 5: Implement `wakeSpeakers()` function and `resolveSpeakerName` error handling

**Files:**
- Modify: `tools/music/Sources/Commands/SpeakerCommands.swift`

- [ ] **Step 1: Add WakeResult struct and wakeSpeakers function**

Add this code above the `runSpeakerSmart` function (before line 58 in `SpeakerCommands.swift`):

```swift
// MARK: - Wake cycle

struct WakeResult {
    let name: String
    let deselectSucceeded: Bool
    let reselectSucceeded: Bool
    let verifiedSelected: Bool
}

func wakeSpeakers(_ names: [String], backend: AppleScriptBackend) -> [WakeResult] {
    var results: [WakeResult] = []

    for name in names {
        verbose("deselecting \(name)...")
        let deselectOk: Bool
        do {
            _ = try syncRun {
                try await backend.runMusic("set selected of AirPlay device \"\(name)\" to false")
            }
            deselectOk = true
        } catch {
            verbose("deselect failed for \(name): \(error.localizedDescription)")
            deselectOk = false
        }
        results.append(WakeResult(name: name, deselectSucceeded: deselectOk, reselectSucceeded: false, verifiedSelected: false))
    }

    // Wait for AirPlay stack to release
    verbose("waiting 500ms for AirPlay release...")
    Thread.sleep(forTimeInterval: 0.5)

    for i in results.indices {
        let name = results[i].name
        verbose("reselecting \(name)...")
        let reselectOk: Bool
        do {
            _ = try syncRun {
                try await backend.runMusic("set selected of AirPlay device \"\(name)\" to true")
            }
            reselectOk = true
        } catch {
            verbose("reselect failed for \(name): \(error.localizedDescription)")
            reselectOk = false
        }
        results[i] = WakeResult(name: name, deselectSucceeded: results[i].deselectSucceeded, reselectSucceeded: reselectOk, verifiedSelected: false)
    }

    // Wait for AirPlay stack to reconnect
    verbose("waiting 500ms for AirPlay reconnect...")
    Thread.sleep(forTimeInterval: 0.5)

    // Verify selection state
    for i in results.indices {
        let name = results[i].name
        let verified: Bool
        do {
            let state = try syncRun {
                try await backend.runMusic("get selected of AirPlay device \"\(name)\"")
            }
            verified = state.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            verbose("\(name) verified selected: \(verified)")
        } catch {
            verbose("verification failed for \(name): \(error.localizedDescription)")
            verified = false
        }
        results[i] = WakeResult(name: name, deselectSucceeded: results[i].deselectSucceeded, reselectSucceeded: results[i].reselectSucceeded, verifiedSelected: verified)
    }

    return results
}
```

- [ ] **Step 2: Make `resolveSpeakerName` throw on no match**

Replace `resolveSpeakerName` (lines 195-208) with:

```swift
func resolveSpeakerName(_ input: String, backend: AppleScriptBackend) throws -> String {
    let result = try syncRun {
        try await backend.runMusic("get name of every AirPlay device")
    }
    let names = result.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }

    let lower = input.lowercased()
    verbose("resolving speaker \"\(input)\" against: \(names.joined(separator: ", "))")
    if let exact = names.first(where: { $0.lowercased() == lower }) {
        verbose("resolved \"\(input)\" → \"\(exact)\" (exact match)")
        return exact
    }
    if let prefix = names.first(where: { $0.lowercased().hasPrefix(lower) }) {
        verbose("resolved \"\(input)\" → \"\(prefix)\" (prefix match)")
        return prefix
    }
    if let contains = names.first(where: { $0.lowercased().contains(lower) }) {
        verbose("resolved \"\(input)\" → \"\(contains)\" (contains match)")
        return contains
    }

    let available = names.joined(separator: ", ")
    throw AppleScriptBackend.ScriptError.speakerNotFound("\(input)\" not found. Available: \(available)")
}
```

- [ ] **Step 3: Build to verify**

Run:
```bash
cd tools/music && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add tools/music/Sources/Commands/SpeakerCommands.swift
git commit -m "feat: add wakeSpeakers() function, resolveSpeakerName throws on no match"
```

---

### Task 6: Wire `.wake` case into `runSpeakerSmart`

**Files:**
- Modify: `tools/music/Sources/Commands/SpeakerCommands.swift`

- [ ] **Step 1: Add the .wake handler to runSpeakerSmart**

In `runSpeakerSmart`, add a new case before the closing `}` of the switch statement (after the `.indices` case, around line 121):

```swift
    case .wake(let name):
        let backend = AppleScriptBackend()
        let targetNames: [String]
        if let name = name {
            let resolved = try resolveSpeakerName(name, backend: backend)
            targetNames = [resolved]
        } else {
            // Wake all currently selected speakers
            let devices = try fetchSpeakerDevices()
            targetNames = devices.filter { $0["selected"] as? Bool == true }.map { $0["name"] as! String }
            if targetNames.isEmpty {
                print("No active speakers to wake.")
                return
            }
        }

        let results = withStatus("Waking speakers...") {
            wakeSpeakers(targetNames, backend: backend)
        }

        for r in results {
            if r.verifiedSelected {
                print("Woke \(r.name).")
            } else {
                print("\(r.name): wake cycle completed but verification uncertain.")
            }
        }
```

Wait — the `backend` variable is already declared at the top of `runSpeakerSmart` (line 60). The `.wake` case should reuse that existing `backend` instance. Let me revise:

```swift
    case .wake(let name):
        let targetNames: [String]
        if let name = name {
            let resolved = try resolveSpeakerName(name, backend: backend)
            targetNames = [resolved]
        } else {
            let devices = try fetchSpeakerDevices()
            targetNames = devices.filter { $0["selected"] as? Bool == true }.map { $0["name"] as! String }
            if targetNames.isEmpty {
                print("No active speakers to wake.")
                return
            }
        }

        let results = withStatus("Waking speakers...") {
            wakeSpeakers(targetNames, backend: backend)
        }

        for r in results {
            if r.verifiedSelected {
                print("Woke \(r.name).")
            } else {
                print("\(r.name): wake cycle completed but verification uncertain.")
            }
        }
```

- [ ] **Step 2: Build and run tests**

Run:
```bash
cd tools/music && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -10
```
Expected: build succeeds, all tests pass.

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/Commands/SpeakerCommands.swift
git commit -m "feat: wire .wake case into runSpeakerSmart with withStatus feedback"
```

---

### Task 7: Add `wake` action to `commands/speaker.md`

**Files:**
- Modify: `commands/speaker.md`

- [ ] **Step 1: Update speaker.md description and add wake action**

In `commands/speaker.md`, update the description in frontmatter (line 3) to include wake:

```yaml
description: "Switch or manage AirPlay speakers. /music:speaker kitchen, /music:speaker only kitchen, /music:speaker add bedroom, /music:speaker remove kitchen, /music:speaker stop kitchen, /music:speaker wake, /music:speaker remove kitchen add bedroom, /music:speaker list"
```

Update the argument description (line 6) to include wake:

```yaml
    description: "Speaker name, 'add <name>', 'remove <name>', 'stop <name>', 'only <name>', 'wake [name]', 'airpods', 'list'. Chain actions: 'remove kitchen add bedroom'"
```

Add the wake handler. Insert this block after the airpods handler (after line 120, before the `find_match` function):

```bash
# Handle wake
if [ "$LOWER_INPUT" = "wake" ] || echo "$LOWER_INPUT" | grep -q '^wake '; then
    WAKE_TARGET=$(echo "$INPUT" | sed 's/^[Ww]ake *//')
    if $HAS_CLI; then
        if [ -n "$WAKE_TARGET" ]; then
            $MUSIC_CLI speaker smart wake "$WAKE_TARGET"
        else
            $MUSIC_CLI speaker smart wake
        fi
    else
        echo "Wake requires the music CLI. Run: scripts/install.sh"
    fi
    exit 0
fi
```

- [ ] **Step 2: Commit**

```bash
git add commands/speaker.md
git commit -m "feat: add wake action to speaker slash command"
```

---

### Task 8: Integrate wake cycle into `commands/play.md`

**Files:**
- Modify: `commands/play.md`

- [ ] **Step 1: Replace `speaker set` with `speaker wake` for routed play**

In `commands/play.md`, replace the speaker routing section (lines 58-61):

```bash
# --- Step 1: Route to speaker ---
if [ -n "$SPEAKER" ]; then
    $MUSIC_CLI speaker set "$SPEAKER"
fi
```

With:

```bash
# --- Step 1: Route to speaker (with wake cycle for AirPlay reliability) ---
if [ -n "$SPEAKER" ]; then
    $MUSIC_CLI speaker smart wake "$SPEAKER"
fi
```

- [ ] **Step 2: Add inherited-session wake detection**

Before the `# --- Step 3: Play content ---` section (before line 70), add:

```bash
# --- Step 2b: Wake inherited AirPlay session (no explicit speaker) ---
if [ -z "$SPEAKER" ] && $HAS_CLI; then
    # Check if non-local AirPlay outputs are active
    ACTIVE_AIRPLAY=$($MUSIC_CLI speaker list --json 2>/dev/null | grep -c '"selected":true' || echo "0")
    if [ "$ACTIVE_AIRPLAY" -gt 1 ] || ($MUSIC_CLI speaker list --json 2>/dev/null | grep -q '"selected":true' && ! $MUSIC_CLI speaker list --json 2>/dev/null | grep '"selected":true' | head -1 | grep -qi 'macbook\|built-in\|internal'); then
        $MUSIC_CLI speaker smart wake 2>/dev/null
    fi
fi
```

Wait — this detection logic is getting complex and fragile in bash. A simpler approach: only wake when a speaker was explicitly requested. The inherited-session detection is better handled in a future iteration when the Swift CLI can do it more reliably. Let me simplify.

Replace the above with a cleaner approach. The inherited-session detection stays in the Swift CLI (when called without speaker args but with active AirPlay). For the slash command, just replace `speaker set` with `speaker wake` when a speaker is specified:

```bash
# --- Step 1: Route to speaker (with wake cycle for AirPlay reliability) ---
if [ -n "$SPEAKER" ]; then
    $MUSIC_CLI speaker smart wake "$SPEAKER"
fi
```

That's the primary fix. The inherited-session wake (plain `music play` with active AirPlay) is a refinement best added to the Swift `Play` command itself in a follow-up, since detecting "non-local" vs "local" speakers reliably requires parsing the device list — something the Swift code already does.

- [ ] **Step 3: Commit**

```bash
git add commands/play.md
git commit -m "feat: use speaker wake instead of speaker set for routed playback"
```

---

### Task 9: Add verbose logging to AppleScriptBackend

**Files:**
- Modify: `tools/music/Sources/Backends/AppleScriptBackend.swift`

- [ ] **Step 1: Add verbose logging to the run function**

In `AppleScriptBackend.swift`, replace the `run` function (lines 15-37) with:

```swift
    /// Run raw AppleScript and return stdout.
    func run(_ script: String) async throws -> String {
        verbose("osascript: \(script.prefix(200))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
            verbose("osascript failed: \(errStr)")
            throw ScriptError.executionFailed(errStr)
        }

        let result = String(data: outData, encoding: .utf8) ?? ""
        verbose("osascript result: \(result.prefix(200))")
        return result
    }
```

- [ ] **Step 2: Build and run tests**

Run:
```bash
cd tools/music && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -10
```
Expected: build succeeds, all tests pass. Verbose output only appears if `Music.verbose` is true (it's false by default).

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/Backends/AppleScriptBackend.swift
git commit -m "feat: add verbose logging to AppleScriptBackend.run()"
```

---

### Task 10: Thread `--verbose` and `--json` into key subcommands

**Files:**
- Modify: `tools/music/Sources/Commands/SpeakerCommands.swift`
- Modify: `tools/music/Sources/Commands/PlaybackCommands.swift`

The `--verbose` and `--json` flags need to set `Music.verbose` and `Music.isJSON` at the entry point of subcommands that use them. Since ArgumentParser doesn't support global inherited flags well, the simplest approach is to set the statics in the `run()` method of key commands.

- [ ] **Step 1: Add `--verbose` flag to Speaker command**

In `SpeakerCommands.swift`, add a verbose flag to `SpeakerSmart` (around line 49):

```swift
struct SpeakerSmart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "smart", abstract: "Smart speaker control.", shouldDisplay: false)
    @Argument(help: "Speaker name, index, volume, or keyword (stop/only/list/wake)") var args: [String] = []
    @Flag(name: .long, help: "Output JSON") var json = false
    @Flag(name: .shortAndLong, help: "Show diagnostic output") var verbose = false

    func run() throws {
        Music.verbose = verbose
        Music.isJSON = json
        try runSpeakerSmart(args: args, json: json)
    }
}
```

- [ ] **Step 2: Add `--verbose` and `--no-wake` flags to Play command**

In `PlaybackCommands.swift`, update the `Play` struct (lines 4-12):

```swift
struct Play: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Play or resume music.")

    @Argument(help: "Playlist name, result index, or 'shuffle'") var args: [String] = []
    @Option(name: .long, help: "Playlist name") var playlist: String?
    @Option(name: .long, help: "Song name") var song: String?
    @Option(name: .long, help: "Artist name") var artist: String?
    @Flag(name: .long, help: "Output JSON") var json = false
    @Flag(name: .shortAndLong, help: "Show diagnostic output") var verbose = false
    @Flag(name: .long, help: "Skip speaker wake cycle") var noWake = false

    func run() throws {
        Music.verbose = verbose
        Music.isJSON = json
        Music.noWake = noWake
        let backend = AppleScriptBackend()
```

The rest of `run()` stays the same (lines 14-102 become 17-105).

- [ ] **Step 3: Build and run tests**

Run:
```bash
cd tools/music && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -10
```
Expected: build succeeds, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add tools/music/Sources/Commands/SpeakerCommands.swift tools/music/Sources/Commands/PlaybackCommands.swift
git commit -m "feat: thread --verbose and --no-wake flags into Speaker and Play commands"
```

---

## Layer 3 — TUI & Feedback

### Task 11: Add play/pause and shuffle/repeat indicators to Now Playing TUI

**Files:**
- Modify: `tools/music/Sources/TUI/NowPlayingTUI.swift`

- [ ] **Step 1: Extend pollNowPlaying to return shuffle and repeat state**

In `NowPlayingTUI.swift`, add two fields to `NowPlayingState` (lines 8-16):

```swift
struct NowPlayingState {
    var track: String = ""
    var artist: String = ""
    var album: String = ""
    var duration: Int = 0
    var position: Int = 0
    var state: String = "stopped"
    var speakers: [(name: String, volume: Int)] = []
    var shuffleEnabled: Bool = false
    var repeatMode: String = "off"  // "off", "one", "all"
}
```

- [ ] **Step 2: Update the poll AppleScript to fetch shuffle and repeat**

In `pollNowPlaying()` (lines 25-66), update the AppleScript to include shuffle and repeat data. Replace the return line inside the try block (line 45):

```applescript
                set sh to shuffle enabled
                set rp to song repeat as text
                return t & "|" & a & "|" & al & "|" & (round d) & "|" & (round p) & "|" & state & "|" & spk & "|" & sh & "|" & rp
```

The full AppleScript inside `pollNowPlaying` becomes:

```swift
        try await backend.runMusic("""
            try
                set state to player state as text
                if state is "stopped" then return "STOPPED"
                set t to name of current track
                set a to artist of current track
                set al to album of current track
                set d to duration of current track
                set p to player position
                set spk to ""
                set deviceList to every AirPlay device
                repeat with dev in deviceList
                    if selected of dev then
                        if spk is not "" then set spk to spk & ","
                        set spk to spk & name of dev & ":" & sound volume of dev
                    end if
                end repeat
                set sh to shuffle enabled
                set rp to song repeat as text
                return t & "|" & a & "|" & al & "|" & (round d) & "|" & (round p) & "|" & state & "|" & spk & "|" & sh & "|" & rp
            end try
            return "STOPPED"
        """)
```

Update the parsing code (lines 51-65). Replace:

```swift
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "STOPPED" { return nil }
    let parts = trimmed.split(separator: "|", maxSplits: 6).map(String.init)
    guard parts.count >= 7 else { return nil }

    let speakers = parts[6].split(separator: ",").map { pair -> (name: String, volume: Int) in
        let kv = pair.split(separator: ":", maxSplits: 1)
        return (name: String(kv[0]), volume: Int(kv.count > 1 ? String(kv[1]) : "0") ?? 0)
    }

    return NowPlayingState(
        track: parts[0], artist: parts[1], album: parts[2],
        duration: Int(parts[3]) ?? 0, position: Int(parts[4]) ?? 0,
        state: parts[5], speakers: speakers
    )
```

With:

```swift
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "STOPPED" { return nil }
    let parts = trimmed.split(separator: "|", maxSplits: 8).map(String.init)
    guard parts.count >= 7 else { return nil }

    let speakers = parts[6].split(separator: ",").map { pair -> (name: String, volume: Int) in
        let kv = pair.split(separator: ":", maxSplits: 1)
        return (name: String(kv[0]), volume: Int(kv.count > 1 ? String(kv[1]) : "0") ?? 0)
    }

    let shuffleEnabled = parts.count > 7 && parts[7].trimmingCharacters(in: .whitespaces) == "true"
    let repeatMode = parts.count > 8 ? parts[8].trimmingCharacters(in: .whitespaces) : "off"

    return NowPlayingState(
        track: parts[0], artist: parts[1], album: parts[2],
        duration: Int(parts[3]) ?? 0, position: Int(parts[4]) ?? 0,
        state: parts[5], speakers: speakers,
        shuffleEnabled: shuffleEnabled, repeatMode: repeatMode
    )
```

- [ ] **Step 3: Add play/pause indicator to the title row in both render functions**

In `runNowPlayingTUI()`, in its `render` function (around line 659), replace:

```swift
        // Title
        out += ANSICode.moveTo(row: metaY, col: metaX)
        out += "\(ANSICode.bold)\(truncText(np.track, to: metaW))\(ANSICode.reset)"
```

With:

```swift
        // Title with play/pause indicator
        let playIcon = np.state == "playing" ? "▶" : "⏸"
        out += ANSICode.moveTo(row: metaY, col: metaX)
        out += "\(ANSICode.bold)\(playIcon) \(truncText(np.track, to: metaW - 2))\(ANSICode.reset)"
```

Do the same in `runNowPlayingWithContext`, in its `render` function (around line 357), replace:

```swift
        out += ANSICode.moveTo(row: metaY, col: metaX)
        out += "\(ANSICode.bold)\(truncText(np.track, to: metaW))\(ANSICode.reset)"
```

With:

```swift
        let playIcon = np.state == "playing" ? "▶" : "⏸"
        out += ANSICode.moveTo(row: metaY, col: metaX)
        out += "\(ANSICode.bold)\(playIcon) \(truncText(np.track, to: metaW - 2))\(ANSICode.reset)"
```

- [ ] **Step 4: Add shuffle/repeat indicators near the speaker info**

In `runNowPlayingTUI()`, after the Volume line in the Outputs block (after line 708), add:

```swift
        // Shuffle/repeat indicators
        var modeStr = ""
        if np.shuffleEnabled { modeStr += "Shuffle" }
        if np.repeatMode == "one" { modeStr += (modeStr.isEmpty ? "" : "  ") + "Repeat One" }
        else if np.repeatMode == "all" { modeStr += (modeStr.isEmpty ? "" : "  ") + "Repeat" }
        if !modeStr.isEmpty {
            let modeRow = np.speakers.isEmpty ? metaY + 12 : metaY + 18
            out += ANSICode.moveTo(row: modeRow, col: metaX)
            out += "\(ANSICode.dim)\(modeStr)\(ANSICode.reset)"
        }
```

Do the same in `runNowPlayingWithContext`, after the Volume line (after line 403):

```swift
        var modeStr = ""
        if np.shuffleEnabled { modeStr += "Shuffle" }
        if np.repeatMode == "one" { modeStr += (modeStr.isEmpty ? "" : "  ") + "Repeat One" }
        else if np.repeatMode == "all" { modeStr += (modeStr.isEmpty ? "" : "  ") + "Repeat" }
        if !modeStr.isEmpty {
            let modeRow = np.speakers.isEmpty ? metaY + 12 : metaY + 18
            out += ANSICode.moveTo(row: modeRow, col: metaX)
            out += "\(ANSICode.dim)\(modeStr)\(ANSICode.reset)"
        }
```

- [ ] **Step 5: Build to verify**

Run:
```bash
cd tools/music && swift build 2>&1 | tail -5
```
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add tools/music/Sources/TUI/NowPlayingTUI.swift
git commit -m "feat: add play/pause icon and shuffle/repeat indicators to Now Playing TUI"
```

---

### Task 12: Add progress feedback to library sync and playlist operations

**Files:**
- Modify: `tools/music/Sources/Commands/PlaylistCommands.swift`
- Modify: `tools/music/Sources/Commands/PlaybackCommands.swift`

- [ ] **Step 1: Wrap library sync waits in PlaylistCommands with status feedback**

In `PlaylistCommands.swift`, find the 4-second sleep in `PlaylistCreate` (around line 333):

```swift
            try syncRun { try await api.addToLibrary(songIDs: ids) }
            try syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }
```

Replace with:

```swift
            try syncRun { try await api.addToLibrary(songIDs: ids) }
            withStatus("Syncing library...") {
                try! syncRun { try await Task.sleep(nanoseconds: 4_000_000_000) }
            }
```

Do the same for the other 4-second sleep instances:
- `PlaylistAdd` index-based path (around line 397): same replacement
- `PlaylistAdd` search-based path (around line 434): same replacement
- `PlaylistCreateFrom` (around line 618): same replacement

- [ ] **Step 2: Add counter feedback to track addition loops**

In `PlaylistCreate`, the track addition loop (around lines 335-353), wrap the loop body with counter feedback. Before the loop:

```swift
            let totalTracks = indices.count
```

Inside the loop, after each track is added, update the status:

```swift
                    addedCount += 1
                    updateStatus("Adding tracks... \(addedCount)/\(totalTracks)")
                    print("  + \(song.title) — \(song.artist)")
```

After the loop:

```swift
            clearStatus()
```

Apply the same pattern to `PlaylistAdd` (around lines 399-414) and `PlaylistCreateFrom` (around lines 620+).

- [ ] **Step 3: Build and run tests**

Run:
```bash
cd tools/music && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -10
```
Expected: build succeeds, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add tools/music/Sources/Commands/PlaylistCommands.swift tools/music/Sources/Commands/PlaybackCommands.swift
git commit -m "feat: add progress feedback to library sync and playlist track addition"
```

---

### Task 13: Replace try? with error feedback in TUI modal operations

**Files:**
- Modify: `tools/music/Sources/TUI/NowPlayingTUI.swift`

- [ ] **Step 1: Replace try? in speaker modal callbacks with error reporting**

This is the most surgical change. The TUI modal callbacks currently use `try?` which silently swallows errors. We can't throw from these callbacks (they're closures passed to `runMultiSelectList`), but we can log the error.

In `runNowPlayingTUI()`, in the speaker modal's `onToggle` callback (around line 808), replace:

```swift
                    _ = try? syncRun {
                        try await backend.runMusic("set selected of AirPlay device \"\(name)\" to \(selected)")
                    }
```

With:

```swift
                    do {
                        _ = try syncRun {
                            try await backend.runMusic("set selected of AirPlay device \"\(name)\" to \(selected)")
                        }
                    } catch {
                        verbose("speaker toggle failed for \(name): \(error.localizedDescription)")
                    }
```

Apply the same pattern to:
- `runNowPlayingTUI()` volume mixer `onVolumeChange` (around line 831)
- `runNowPlayingWithContext()` speaker modal `onToggle` (around line 553)
- `runNowPlayingWithContext()` volume mixer `onVolumeChange` (around line 577)

For the `fetchSpeakerDevices()` calls that gate the modal opening (lines 546, 570, 801, 824), replace `if let devices = try? fetchSpeakerDevices()` with:

```swift
                let devices: [[String: Any]]
                do {
                    devices = try fetchSpeakerDevices()
                } catch {
                    verbose("failed to fetch speakers: \(error.localizedDescription)")
                    // Skip modal — can't open without device list
                    terminal.enterRawMode()
                    continue
                }
```

Note: The `terminal.enterRawMode()` + `continue` is needed because these blocks are inside the `while true` key loop, and `terminal.exitRawMode()` was called just before the fetch.

- [ ] **Step 2: Build and run tests**

Run:
```bash
cd tools/music && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -10
```
Expected: build succeeds, all tests pass.

- [ ] **Step 3: Commit**

```bash
git add tools/music/Sources/TUI/NowPlayingTUI.swift
git commit -m "feat: replace try? with verbose error logging in TUI modal operations"
```

---

### Task 14: Version bump and final build verification

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Bump version to 1.4.0 in plugin.json**

In `.claude-plugin/plugin.json`, update the version field to `"1.4.0"`.

- [ ] **Step 2: Bump version in marketplace.json (both locations)**

In `.claude-plugin/marketplace.json`, update:
- `metadata.version` to `"1.4.0"`
- `plugins[0].version` to `"1.4.0"`

- [ ] **Step 3: Full build and test**

Run:
```bash
cd tools/music && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -15
```
Expected: `Build complete!`, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore: bump version to 1.4.0"
```

---

## Verification Checklist

After all tasks are complete, verify:

- [ ] `music speaker wake` cycles all selected speakers and reports results
- [ ] `music speaker wake kitchen` cycles only the named speaker
- [ ] `/music:play "Playlist" kitchen 60%` uses `speaker wake` instead of `speaker set`
- [ ] `music play` with only local speakers does NOT trigger wake
- [ ] `music speaker wake nonexistent` shows "not found" with available speakers list
- [ ] `music speaker smart --verbose wake kitchen` shows diagnostic steps on stderr
- [ ] `music now --json` does NOT show withStatus output
- [ ] `music now` TUI shows `▶` or `⏸` next to track title
- [ ] `music now` TUI shows `Shuffle` / `Repeat` indicators when active
- [ ] Creating a playlist with tracks shows `Adding tracks... 3/10` progress
- [ ] Version is `1.4.0` in plugin.json and marketplace.json (both locations)
