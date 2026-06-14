// tools/music/Sources/TUI/Shell/NowPlayingScene.swift
import Foundation

enum ContinuationAction: Equatable { case shuffle, playlist, quiet }

/// Where to snap the Up Next cursor after a track change: the row that is both
/// marked current AND matches the new track. nil when the rows predate the
/// change (the fast-publish window still shows the previous context) — the
/// caller must then NOT consume the change, so the snap retries when the
/// refreshed rows land. Pure.
func snapCursorIndex(rows: [TrackListEntry], currentKey: String) -> Int? {
    rows.firstIndex { $0.isCurrent && trackKey(title: $0.name, artist: $0.artist) == currentKey }
}

/// `q` is deliberately NOT a continuation key: globally it means quit, and a
/// user pressing `q` at a queue-ended TUI must leave the app, not pause it.
func continuationAction(for key: KeyPress) -> ContinuationAction? {
    switch key {
    case .char("s"), .char("S"): return .shuffle
    case .char("p"), .char("P"): return .playlist
    case .char("x"), .char("X"): return .quiet
    default: return nil
    }
}

final class NowPlayingScene: Scene {
    let id: SceneID = .nowPlaying
    let tabTitle = "Now"
    var footerHint: String {
        controlFocus
            ? "\u{2191}\u{2193}\u{2190}\u{2192} Move cell  Enter Set  Esc Done  \u{2014} control grid"
            : "\u{2191}\u{2193} Browse  \u{2190}\u{2192} Seek  l \u{2665}  c Controls  s/m Shuffle  r Repeat  g Genius"
    }

    private let backend: AppleScriptBackend
    private let appQueue: AppQueueStore
    private let status: StatusStore
    private let actions: ActionRunner
    private var cursor = 0
    private var scroll = 0
    private var rows: [TrackListEntry] = []
    private var lastCurrentKey = ""
    private var manualMenu = false   // user-opened menu (vs poller-detected queueEnded)
    private var menuShownLastFrame = false
    private var pendingSeedTitle = ""
    private var pendingSeedArtist = ""
    private var pendingPlaylist = ""         // context/ended playlist, for the Shuffle action
    private var pendingFromStopped = false   // menu opened from an auto queue-end (playback stopped)
    private var wantsPlaylists = false
    private var contextNameNow = ""          // cleaned context name from the latest snapshot

    // Shuffle/repeat state, fetched on a background inbox (the poller is left
    // untouched). Mirrors SpeakersScene's EQ inbox.
    private var modes: PlaybackModes? = nil
    private let modesLock = NSLock()
    private var inboxModes: PlaybackModes? = nil
    private var modesFetchInFlight = false
    private var modesFetchStartedAt = Date.distantPast
    private var lastModesMutation = Date.distantPast
    private var lastModesKick = Date.distantPast

    // Control grid: `c` moves focus into it; then ↑↓←→ move the cell cursor and
    // Enter sets the value. Unfocused, the grid still shows live active state.
    private var controlFocus = false
    private var gridRow = 0
    private var gridCol = 0

    init(backend: AppleScriptBackend, appQueue: AppQueueStore, status: StatusStore, actions: ActionRunner) {
        self.backend = backend
        self.appQueue = appQueue
        self.status = status
        self.actions = actions
    }

    // Once the user acts on an auto-detected queue-end, remember which one (by its
    // ended track) so the menu doesn't re-appear for the same event — e.g. after
    // picking Quiet, which leaves playback stopped with queueEnded still set.
    private var dismissedSeed = ""
    private func menuActive(_ snapshot: NowPlayingSnapshot) -> Bool {
        (snapshot.queueEnded && snapshot.endedTrack != dismissedSeed) || manualMenu
    }
    var capturesAllInput: Bool { menuShownLastFrame }

    @discardableResult
    func tick(snapshot: NowPlayingSnapshot) -> Bool {
        menuShownLastFrame = menuActive(snapshot)
        pendingFromStopped = snapshot.queueEnded
        if snapshot.queueEnded {
            pendingSeedTitle = snapshot.endedTrack
            pendingSeedArtist = snapshot.endedArtist
            pendingPlaylist = snapshot.endedPlaylist
        } else if case .active(let np) = snapshot.outcome {
            pendingSeedTitle = np.track
            pendingSeedArtist = np.artist
            pendingPlaylist = cleanContextName(snapshot.contextName)
        }
        rows = snapshot.surrounding
        contextNameNow = cleanContextName(snapshot.contextName)
        // Snap the cursor to the current track when the track changes; leave it
        // alone otherwise so the user can browse Up Next. Consume the change
        // only when the rows actually contain the new track as current — the
        // poller's fast-publish snapshot still carries the PREVIOUS window, and
        // snapping against it parked the cursor on a stale row for good (the
        // wrong-track-on-Enter bug).
        if case .active(let np) = snapshot.outcome {
            let key = trackKey(title: np.track, artist: np.artist)
            if key != lastCurrentKey, let i = snapCursorIndex(rows: rows, currentKey: key) {
                lastCurrentKey = key
                cursor = i
            }
        }
        if cursor >= rows.count { cursor = max(0, rows.count - 1) }

        // Shuffle/repeat: drain the background inbox, then kick a fresh fetch
        // every ~2s. A fetch that started before the user's last toggle is
        // stale (would revert the optimistic update), so it's dropped.
        var changed = false
        modesLock.lock()
        let freshModes = inboxModes; inboxModes = nil
        modesLock.unlock()
        if let freshModes, modesFetchStartedAt > lastModesMutation, freshModes != modes {
            modes = freshModes
            changed = true
        }
        let now = Date()
        if !modesFetchInFlight, now.timeIntervalSince(lastModesKick) > 2 {
            modesFetchInFlight = true
            modesFetchStartedAt = now
            lastModesKick = now
            DispatchQueue.global().async { [weak self] in
                guard let self else { return }
                let m = try? fetchPlaybackModes(self.backend)
                self.modesLock.lock()
                self.inboxModes = m
                self.modesFetchInFlight = false
                self.modesLock.unlock()
            }
        }
        // The snapshot-derived state above repaints via the store's generation
        // counter; `changed` covers a modes update that the generation misses.
        return changed
    }

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        var out = ""
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        guard frame.bodyHeight > 4, frame.width > 30 else { return out }

        if menuActive(snapshot) {
            return renderContinuationMenu(frame: frame, snapshot: snapshot, into: out)
        }

        guard case .active(let np) = snapshot.outcome else {
            // The empty state is the on-ramp, not a dead end.
            out += ANSICode.moveTo(row: frame.bodyY + 1, col: 3)
            out += "\(ANSICode.dim)Nothing playing \u{2014} press \(ANSICode.reset)2\(ANSICode.dim) to browse playlists, \(ANSICode.reset)z\(ANSICode.dim) to shuffle.\(ANSICode.reset)"
            return out
        }

        // Two-pane when wide enough: left = now-playing (large art + metadata),
        // right = Up Next list. Narrow falls back to stacked (art+meta, list below).
        let twoPane = frame.width >= 92
        let leftX = 3
        let leftW = twoPane ? 44 : (frame.width - 6)
        let listBottom = frame.bodyY + frame.bodyHeight - 1

        // --- Left pane: large album art ---
        // The art is rendered at a fixed 44 columns; below ~50 columns the
        // chafa lines wrap and corrupt the whole frame — skip art entirely.
        let artLines = frame.width >= 52 ? snapshot.artLines : []
        // Reserve room below the art for metadata (~7 rows) + the control grid (~6).
        let artRows = min(artLines.count, max(0, frame.bodyHeight - 13))
        for i in 0..<artRows {
            out += ANSICode.moveTo(row: frame.bodyY + i, col: leftX) + "\(artLines[i])\(ANSICode.reset)"
        }

        // --- Left pane: metadata below the art ---
        var my = frame.bodyY + artRows + 1
        let metaW = leftW
        let playIcon = np.state == "playing" ? "\u{25B6}" : "\u{23F8}"
        out += ANSICode.moveTo(row: my, col: leftX)
        out += "\(ANSICode.bold)\(ANSICode.brightWhite)\(playIcon) \(truncText(np.track, to: metaW - 2))\(ANSICode.reset)"
        my += 1
        out += ANSICode.moveTo(row: my, col: leftX) + truncText(np.artist, to: metaW)
        my += 1
        out += ANSICode.moveTo(row: my, col: leftX) + "\(ANSICode.dim)\(truncText(np.album, to: metaW))\(ANSICode.reset)"
        my += 2
        let elapsed = formatTime(np.position)
        let total = formatTime(np.duration)
        let ratio = np.duration > 0 ? Double(np.position) / Double(np.duration) : 0
        let pbW = min(28, max(8, metaW - 14))
        let knob = max(0, min(pbW - 1, Int(ratio * Double(pbW - 1))))
        var bar = ""
        for i in 0..<pbW { bar += i == knob ? "\(ANSICode.bold)\u{25CF}\(ANSICode.reset)" : "\(ANSICode.dim)\u{2500}\(ANSICode.reset)" }
        out += ANSICode.moveTo(row: my, col: leftX) + "\(elapsed) \(bar) \(total)"
        my += 2
        if !snapshot.contextName.isEmpty {
            out += ANSICode.moveTo(row: my, col: leftX) + "\(ANSICode.cyan)\u{266A} \(ANSICode.reset)\(ANSICode.brightWhite)\(truncText(cleanContextName(snapshot.contextName), to: metaW - 3))\(ANSICode.reset)"
        }

        // Playback-control grid (shuffle/order/repeat/genius). Always shows live
        // active state; `c` focuses it for arrow-navigation + Enter.
        out += renderControlGrid(startY: my + 2, x: leftX, bottom: frame.bodyY + frame.bodyHeight - 1)

        // --- Up Next: right pane (wide) or below the metadata (narrow) ---
        let listX = twoPane ? (leftX + leftW + 2) : leftX
        let listY = twoPane ? frame.bodyY : (my + 2)
        let listW = twoPane ? max(20, frame.width - listX - 1) : (frame.width - 6)
        if listY + 1 <= listBottom {
            // Adapt context entries to the timeline-row shape the shared renderer expects.
            let timeline = rows.map { e in
                TimelineRow(
                    index: e.index,
                    label: "\(e.name) \u{2014} \(e.artist)",
                    isCurrent: e.isCurrent, wasPlayed: false
                )
            }
            out += renderTimelineRows(
                rows: timeline,
                header: "Up Next",
                x: listX,
                y: listY,
                width: listW,
                visibleHeight: listBottom - listY + 1,
                cursorIndex: cursor,
                scrollOffset: &scroll
            )
        }
        return out
    }

    /// The playback-control grid: a label column then option cells per row.
    /// Active value is bright; the focused cell (when `controlFocus`) is inverse.
    private func renderControlGrid(startY: Int, x: Int, bottom: Int) -> String {
        var out = ""
        var y = startY
        let labelW = 8
        for row in 0..<ControlGrid.rowCount {
            guard y <= bottom else { break }
            out += ANSICode.moveTo(row: y, col: x)
            let label = ControlGrid.labels[row]
            let padLabel = label + String(repeating: " ", count: max(0, labelW - label.count))
            out += "\(ANSICode.dim)\(padLabel)\(ANSICode.reset) "
            let active = modes.flatMap { ControlGrid.activeColumn(row: row, modes: $0) }
            var line = ""
            for col in 0..<ControlGrid.cellCount(row: row) {
                let cell = ControlGrid.cells[row][col]
                let isActive = (col == active)
                let isCursor = controlFocus && row == gridRow && col == gridCol
                let styled: String
                if isCursor {
                    styled = "\(ANSICode.inverse)\(ANSICode.bold) \(cell) \(ANSICode.reset)"
                } else if isActive {
                    styled = "\(ANSICode.brightWhite)[\(cell)]\(ANSICode.reset)"
                } else {
                    styled = "\(ANSICode.dim) \(cell) \(ANSICode.reset)"
                }
                line += styled + " "
            }
            // `line` carries ANSI codes, so it isn't truncText'd (that counts
            // escape bytes); the rows are short and fit the metadata column.
            out += line
            y += 1
        }
        return out
    }

    private func renderContinuationMenu(frame: ShellFrame, snapshot: NowPlayingSnapshot, into base: String) -> String {
        var out = base
        let (seedTitle, art): (String, [String]) = snapshot.queueEnded
            ? (snapshot.endedTrack, snapshot.endedArtLines)
            : ({ if case .active(let np) = snapshot.outcome { return np.track } else { return "" } }(), snapshot.artLines)
        let title = snapshot.queueEnded
            ? "Queue ended — what next?"
            : "What next?"
        out += ANSICode.moveTo(row: frame.bodyY, col: 3)
        out += "\(ANSICode.bold)\(ANSICode.cyan)\(title)\(ANSICode.reset)"

        // Art thumbnail (shared by Radio/Similar cards), then a labelled option list.
        let artTop = frame.bodyY + 2
        let artRows = min(art.count, max(0, frame.bodyHeight - 8))
        for i in 0..<artRows {
            out += ANSICode.moveTo(row: artTop + i, col: 3) + "\(art[i])\(ANSICode.reset)"
        }
        let lx = 3
        var ly = artTop + artRows + 1
        let shuffleTarget = pendingPlaylist.isEmpty ? seedTitle : pendingPlaylist
        let opts: [(String, String)] = [
            ("[S]", "Shuffle  \(ANSICode.dim)\(truncText(shuffleTarget, to: 28))\(ANSICode.reset)"),
            ("[P]", "Playlist  \(ANSICode.dim)browse\(ANSICode.reset)"),
            ("[X]", "Quiet  \(ANSICode.dim)stop here\(ANSICode.reset)"),
        ]
        for (key, label) in opts {
            out += ANSICode.moveTo(row: ly, col: lx) + "\(ANSICode.lime)\(key)\(ANSICode.reset)  \(label)"
            ly += 1
        }
        return out
    }

    /// Apply the focused control-grid cell: set the value (optimistically) and
    /// run the AppleScript write. Maps the (row, col) cursor to the action.
    private func applyControlCell() {
        lastModesMutation = Date()
        switch ControlRow(rawValue: gridRow) {
        case .shuffle:
            let on = gridCol == 0
            modes?.shuffleEnabled = on
            actions.run("Shuffle") { try require((try? setShuffleEnabled(self.backend, on)) != nil, "Couldn't set shuffle.") }
        case .order:
            let mode = ControlGrid.orderModes[gridCol]
            modes?.shuffleMode = mode
            actions.run("Shuffle mode") { try require((try? setShuffleMode(self.backend, mode)) != nil, "Couldn't set shuffle mode.") }
        case .repeatMode:
            let rep = ControlGrid.repeatModes[gridCol]
            modes?.songRepeat = rep
            actions.run("Repeat") { try require((try? setSongRepeat(self.backend, rep)) != nil, "Couldn't set repeat.") }
        case .genius, .none:
            actions.run("Genius") { try require((try? triggerGeniusShuffle(self.backend)) != nil, "Genius Shuffle failed.") }
        }
    }

    private func act(on action: ContinuationAction) {
        switch action {
        case .shuffle:
            // Replay the just-played playlist shuffled, via the app-owned queue.
            // Falls back to shuffling whatever's playing if there's no playlist name.
            // On the action queue: shufflePlayPlaylist bulk-fetches the whole
            // playlist, which must not stall the input loop.
            let playlist = pendingPlaylist
            let backend = self.backend
            let appQueue = self.appQueue
            actions.run("Shuffle") {
                let ok = playlist.isEmpty
                    ? shufflePlayCurrent(backend: backend, appQueue: appQueue)
                    : shufflePlayPlaylist(backend: backend, appQueue: appQueue, playlist: playlist)
                try require(ok, "Shuffle failed.")
            }
        case .playlist:
            wantsPlaylists = true
        case .quiet:
            appQueue.clear()
            actions.run("Pause") { _ = try syncRun { try await self.backend.runMusic("pause") } }
        }
    }

    func handle(_ key: KeyPress) -> SceneAction {
        // Continuation menu intercepts its keys when active.
        if menuShownLastFrame {
            if let action = continuationAction(for: key) {
                act(on: action)
                manualMenu = false
                dismissedSeed = pendingSeedTitle   // don't re-show this queue-end's menu
                if wantsPlaylists { wantsPlaylists = false; return .push(.playlists) }
                return .redraw
            }
            // The menu captures all input, so quit must be honored here — `q` at
            // a queue-ended TUI means "leave the app", never a menu action.
            if case .char("q") = key { return .quit }
            // Esc dismisses the menu — manual or auto (the auto menu is keyed by
            // its ended track, so it won't re-appear for the same queue-end).
            if case .escape = key {
                manualMenu = false
                dismissedSeed = pendingSeedTitle
                return .redraw
            }
        }
        // Manual open: 'n' (next-options) when no menu is up.
        if case .char("n") = key, !menuShownLastFrame {
            manualMenu = true; return .redraw
        }

        // `c` toggles focus into the control grid (not while the queue-end menu owns input).
        if case .char("c") = key, !menuShownLastFrame {
            controlFocus.toggle()
            if controlFocus { (gridRow, gridCol) = ControlGrid.clamp(row: gridRow, col: gridCol) }
            return .redraw
        }
        // While the grid is focused, arrows move the cell cursor, Enter sets the
        // value, Esc returns focus to the Up Next list. The s/m/r/g shortcuts
        // below still work in either mode.
        if controlFocus, !menuShownLastFrame {
            switch key {
            case .up:    (gridRow, gridCol) = ControlGrid.clamp(row: gridRow - 1, col: gridCol); return .redraw
            case .down:  (gridRow, gridCol) = ControlGrid.clamp(row: gridRow + 1, col: gridCol); return .redraw
            case .left:  (gridRow, gridCol) = ControlGrid.clamp(row: gridRow, col: gridCol - 1); return .redraw
            case .right: (gridRow, gridCol) = ControlGrid.clamp(row: gridRow, col: gridCol + 1); return .redraw
            case .enter: applyControlCell(); return .redraw
            case .escape: controlFocus = false; return .redraw
            default: break   // fall through: s/m/r/g/l still work
            }
        }

        switch key {
        case .up:
            guard !rows.isEmpty else { return .none }
            cursor = max(0, cursor - 1); return .redraw
        case .down:
            guard !rows.isEmpty else { return .none }
            cursor = min(max(0, rows.count - 1), cursor + 1); return .redraw
        case .pageUp:
            guard !rows.isEmpty else { return .none }
            cursor = max(0, cursor - 10); return .redraw
        case .pageDown:
            guard !rows.isEmpty else { return .none }
            cursor = min(max(0, rows.count - 1), cursor + 10); return .redraw
        case .home:
            guard !rows.isEmpty else { return .none }
            cursor = 0; return .redraw
        case .end:
            guard !rows.isEmpty else { return .none }
            cursor = rows.count - 1; return .redraw
        case .enter:
            guard cursor < rows.count else { return .none }
            // Jump within the app-owned queue by the row's play-order position.
            let backend = self.backend
            if let (pl, pos) = appQueue.jump(to: rows[cursor].index) {
                actions.run("Play") { try require(playQueueTrack(backend: backend, playlist: pl, position: pos), "Couldn't play that track.") }
                return .redraw
            }
            // No app queue: a whole-playlist play (native queue) lands here. Playing
            // the row from the Library would collapse Music's context to the
            // alphabetical library (and `play track N of current playlist` is the
            // macOS 26.x-regressed verb) — so ADOPT the app-owned queue: fetch the
            // context playlist and take over from this row, same as the Playlists
            // tab does. Album/library contexts (the context name isn't a playlist,
            // or the row doesn't line up) fall back to the library lookup.
            let row = rows[cursor]
            let context = contextNameNow
            let store = self.appQueue
            actions.run("Play") {
                if !context.isEmpty, !isLibraryContextName(context) {
                    let tracks = fetchPlaylistTracks(backend: backend, playlist: context)
                    if row.index >= 1, row.index <= tracks.count,
                       trackKey(title: tracks[row.index - 1].name, artist: tracks[row.index - 1].artist)
                           == trackKey(title: row.name, artist: row.artist) {
                        store.set(AppQueue(playlistName: context, tracks: tracks, currentIndex: row.index))
                        try require(playQueueTrack(backend: backend, playlist: context, position: row.index), "Couldn't play that track.")
                        return
                    }
                }
                try require(playLibraryTrack(backend: backend, title: row.name, artist: row.artist), "'\(row.name)' not found in the library.")
            }
            return .redraw
        case .char("l"):
            // Toggle favorite on the current track (macOS 26: `favorited`, the
            // old `loved` property errors). State isn't polled — the toast IS
            // the feedback.
            let status = self.status
            actions.run("Favorite") {
                let result = try syncRun {
                    try await self.backend.runMusic("""
                        if player state is stopped then return "NOTHING"
                        set favorited of current track to (not favorited of current track)
                        if favorited of current track then
                            return "ON" & (ASCII character 31) & name of current track
                        end if
                        return "OFF" & (ASCII character 31) & name of current track
                    """)
                }
                let parts = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: asFieldSep).map(String.init)
                try require(parts.first != "NOTHING", "Nothing playing.")
                let title = parts.count > 1 ? parts[1] : "track"
                status.post(parts.first == "ON" ? "\u{2665} Favorited '\(title)'" : "Unfavorited '\(title)'")
            }
            return .redraw
        case .left:
            actions.run("Seek") { _ = try syncRun { try await self.backend.runMusic("set player position to (player position - 30)") } }
            return .redraw
        case .right:
            actions.run("Seek") { _ = try syncRun { try await self.backend.runMusic("set player position to (player position + 30)") } }
            return .redraw
        case .char("s"), .char("S"):
            // Shuffle on/off (Music's `shuffle enabled` flag). Distinct from the
            // global `z`, which shuffle-plays the current context.
            let on = !(modes?.shuffleEnabled ?? false)
            modes?.shuffleEnabled = on
            lastModesMutation = Date()
            actions.run("Shuffle") {
                try require((try? setShuffleEnabled(self.backend, on)) != nil, "Couldn't set shuffle.")
            }
            return .redraw
        case .char("m"), .char("M"):
            let next = (modes?.shuffleMode ?? .songs).next
            modes?.shuffleMode = next
            lastModesMutation = Date()
            actions.run("Shuffle mode") {
                try require((try? setShuffleMode(self.backend, next)) != nil, "Couldn't set shuffle mode.")
            }
            return .redraw
        case .char("r"), .char("R"):
            let next = (modes?.songRepeat ?? .off).next
            modes?.songRepeat = next
            lastModesMutation = Date()
            actions.run("Repeat") {
                try require((try? setSongRepeat(self.backend, next)) != nil, "Couldn't set repeat.")
            }
            return .redraw
        case .char("g"), .char("G"):
            // Genius Shuffle rebuilds the queue from the current song (UI-scripted).
            actions.run("Genius") {
                try require((try? triggerGeniusShuffle(self.backend)) != nil, "Genius Shuffle failed.")
            }
            return .redraw
        default:
            return .none
        }
    }
}
