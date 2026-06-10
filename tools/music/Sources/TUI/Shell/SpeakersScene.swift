// tools/music/Sources/TUI/Shell/SpeakersScene.swift
import Foundation

/// One AirPlay output: its name, whether it's in the active group, and its volume.
struct SpeakerRow {
    let name: String
    var active: Bool
    var volume: Int
}

/// Pure mapping from `fetchSpeakerDevices()`'s `[[String:Any]]` to typed rows.
/// Entries missing name/selected/volume are skipped.
func speakerRows(from devices: [[String: Any]]) -> [SpeakerRow] {
    devices.compactMap { d in
        guard let name = d["name"] as? String,
              let active = d["selected"] as? Bool,
              let volume = d["volume"] as? Int else { return nil }
        return SpeakerRow(name: name, active: active, volume: volume)
    }
}

final class SpeakersScene: Scene {
    let id: SceneID = .speakers
    let tabTitle = "Speakers"
    var footerHint: String { "\u{2191}\u{2193} Speaker  Enter Toggle  \u{2190}\u{2192} Volume" }

    private let backend: AppleScriptBackend
    private let status: StatusStore
    private let actions: ActionRunner
    private let speakerTargets = TargetAccumulator()
    private var rows: [SpeakerRow] = []
    private var cursor = 0

    // Background refresh, inbox pattern: tick() kicks fetches and drains results.
    // The scene used to load once and never again — devices appearing/vanishing
    // never showed, and a failed optimistic toggle stayed wrong forever.
    private let inboxLock = NSLock()
    private var inbox: [SpeakerRow]? = nil
    private var fetchInFlight = false                 // tick()-thread only
    private var fetchStartedAt = Date.distantPast     // tick()-thread only
    private var lastFetchKickoff = Date.distantPast   // tick()-thread only
    private var lastTickAt = Date.distantPast         // tick()-thread only
    private var lastMutation = Date.distantPast       // handle()/tick() thread only
    private var everLoaded = false

    init(backend: AppleScriptBackend, status: StatusStore, actions: ActionRunner) {
        self.backend = backend
        self.status = status
        self.actions = actions
    }

    @discardableResult
    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        var changed = false
        // Apply a landed fetch — unless the user mutated state after it started,
        // in which case it's stale and would briefly revert the optimistic UI.
        inboxLock.lock()
        let fresh = inbox; inbox = nil
        inboxLock.unlock()
        if let fresh {
            fetchInFlight = false
            if fetchStartedAt > lastMutation {
                let cursorName = rows.indices.contains(cursor) ? rows[cursor].name : nil
                rows = fresh
                everLoaded = true
                if let name = cursorName, let i = rows.firstIndex(where: { $0.name == name }) { cursor = i }
                if cursor >= rows.count { cursor = max(0, rows.count - 1) }
                changed = true
            }
        }
        // Refresh on (re)entry — tick only runs while this scene is active, so a
        // gap since the last tick means the user just switched back — and every
        // few seconds while shown. AirPlay enumeration runs off-thread.
        let now = Date()
        let reentered = now.timeIntervalSince(lastTickAt) > 0.5
        lastTickAt = now
        // A wedged enumeration (osascript hung on a dying device) used to set
        // fetchInFlight forever and kill refreshes for the session; treat a
        // long-overdue fetch as dead and allow a new kickoff. (The backend
        // watchdog also terminates the hung osascript itself.)
        if fetchInFlight, now.timeIntervalSince(fetchStartedAt) > 30 {
            fetchInFlight = false
        }
        if !fetchInFlight, reentered || now.timeIntervalSince(lastFetchKickoff) > 5 {
            fetchInFlight = true
            fetchStartedAt = now
            lastFetchKickoff = now
            DispatchQueue.global().async { [weak self] in
                let result = speakerRows(from: (try? fetchSpeakerDevices()) ?? [])
                guard let self else { return }
                self.inboxLock.lock()
                self.inbox = result
                self.inboxLock.unlock()
            }
        }
        return changed
    }

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        var out = ""
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        var y = frame.bodyY
        out += ANSICode.moveTo(row: y, col: 3)
        out += "\(ANSICode.bold)\(ANSICode.cyan)AirPlay Outputs\(ANSICode.reset)"
        y += 2

        if rows.isEmpty {
            let msg = everLoaded ? "No AirPlay outputs found." : "Loading speakers\u{2026}"
            out += ANSICode.moveTo(row: y, col: 3) + "\(ANSICode.dim)\(msg)\(ANSICode.reset)"
            return out
        }

        let nameW = 18
        let barW = 16
        let bottom = frame.bodyY + frame.bodyHeight - 1
        for (i, row) in rows.enumerated() {
            guard y <= bottom else { break }
            out += ANSICode.moveTo(row: y, col: 3)
            let isCursor = i == cursor
            let marker = " "
            let dot = row.active ? "\(ANSICode.lime)\u{25CF}\(ANSICode.reset)" : "\(ANSICode.dim)\u{25CB}\(ANSICode.reset)"
            let name = truncText(row.name, to: nameW)
            let padName = name + String(repeating: " ", count: max(0, nameW - name.count))
            // Same selection language as the other tabs: inverse-video cursor.
            let nameStr: String
            if isCursor {
                nameStr = "\(ANSICode.inverse)\(padName)\(ANSICode.reset)"
            } else if row.active {
                nameStr = "\(ANSICode.brightWhite)\(padName)\(ANSICode.reset)"
            } else {
                nameStr = "\(ANSICode.dim)\(padName)\(ANSICode.reset)"
            }
            let bar = meterBar(value: row.volume, width: barW)
            let vol = String(format: "%3d", row.volume)
            out += "\(marker) \(dot) \(nameStr) \(bar) \(vol)"
            y += 1
        }

        // No in-body key hints — the scene-aware footer already shows them.
        return out
    }

    func handle(_ key: KeyPress) -> SceneAction {
        guard !rows.isEmpty else {
            if case .escape = key { return .pop }
            return .none
        }
        switch key {
        case .up:
            cursor = max(0, cursor - 1); return .redraw
        case .down:
            cursor = min(rows.count - 1, cursor + 1); return .redraw
        case .pageUp:
            cursor = max(0, cursor - 5); return .redraw
        case .pageDown:
            cursor = min(rows.count - 1, cursor + 5); return .redraw
        case .home:
            cursor = 0; return .redraw
        case .end:
            cursor = rows.count - 1; return .redraw
        case .enter:
            rows[cursor].active.toggle()
            lastMutation = Date()
            setSelected(rows[cursor])
            return .redraw
        case .left:
            rows[cursor].volume = max(0, rows[cursor].volume - 5)
            lastMutation = Date()
            setVolume(rows[cursor])
            return .redraw
        case .right:
            rows[cursor].volume = min(100, rows[cursor].volume + 5)
            lastMutation = Date()
            setVolume(rows[cursor])
            return .redraw
        case .escape:
            return .pop
        default:
            return .none
        }
    }

    // MARK: AppleScript (each its own call — never batched, per the -50 rule).
    // On the action queue: the optimistic UI updates instantly; a failure posts
    // a toast and the next background refresh reconciles the real state.

    private func setSelected(_ row: SpeakerRow) {
        let esc = escapeAppleScriptString(row.name)
        let name = row.name
        let active = row.active
        actions.run("Speaker") {
            try require((try? syncRun { try await self.backend.runMusic("set selected of AirPlay device \"\(esc)\" to \(active)") }) != nil,
                        "Couldn't \(active ? "add" : "remove") '\(name)'.")
        }
    }
    private func setVolume(_ row: SpeakerRow) {
        // Coalesced per speaker: holding an arrow applies only the final target.
        let esc = escapeAppleScriptString(row.name)
        let name = row.name
        speakerTargets.set(name, row.volume)
        actions.run("Volume") {
            guard let v = self.speakerTargets.take(name) else { return }
            try require((try? syncRun { try await self.backend.runMusic("set sound volume of AirPlay device \"\(esc)\" to \(v)") }) != nil,
                        "Couldn't set '\(name)' volume.")
        }
    }
}
