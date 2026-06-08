// tools/music/Sources/TUI/Shell/PlaylistsScene.swift
import Foundation

final class PlaylistsScene: Scene {
    let id: SceneID = .playlists
    let tabTitle = "Playlists"
    var capturesAllInput: Bool { filtering }

    private let backend: AppleScriptBackend
    private let playlists: [String]
    private let sources: PlaylistDataSources
    private let appQueue: AppQueueStore

    private var focus: BrowserFocus = .playlists
    private var plCursor = 0
    private var plScroll = 0
    private var trCursor = 0
    private var trScroll = 0
    private var meta: [PlaylistMeta]
    private var loaded: Set<Int> = []
    private var fullCache: [Int: PlaylistPreview] = [:]
    private var previewLines: [Int: [String]] = [:]
    private var lastLoadedPl = -1
    private var filterText = ""
    private var filtering = false

    // Off-thread metadata refresh: a background thread fetches via `onMeta` and posts
    // results to `inbox`; tick() drains them on the main thread, so `meta` stays
    // main-thread-only and the slow AppleScript never blocks a render frame.
    private let inboxLock = NSLock()
    private var inbox: [Int: (Int, Int, Bool, String)] = [:]

    private let metaCol = 6

    init(backend: AppleScriptBackend, playlists: [String], sources: PlaylistDataSources, appQueue: AppQueueStore) {
        self.backend = backend
        self.playlists = playlists
        self.sources = sources
        self.appQueue = appQueue
        self.meta = playlists.map { PlaylistMeta(name: $0) }
        // Seed the rail from the on-disk cache so it paints fully on first frame;
        // a background pass then refreshes every playlist and rewrites the cache.
        let cache = PlaylistMetaCache.load()
        for i in 0..<meta.count {
            guard let c = cache[meta[i].name] else { continue }
            meta[i].trackCount = c.count
            meta[i].durationSec = c.durationSec
            meta[i].isSmart = c.isSmart
            meta[i].specialKind = c.specialKind
            meta[i].loaded = true
            loaded.insert(i)
        }
        startBackgroundRefresh()
    }

    /// Refresh every playlist's metadata off the main thread (so render never
    /// blocks on AppleScript), posting results to `inbox` and rewriting the cache.
    /// Batches can fail transiently when Music is under concurrent AppleScript load
    /// at startup (poller + preview fetches), so any index that doesn't come back is
    /// retried with backoff until all resolve or the attempt cap is hit.
    private func startBackgroundRefresh() {
        let names = playlists
        let sources = self.sources
        Thread.detachNewThread { [weak self] in
            var merged = PlaylistMetaCache.load()
            var pending = Set(0..<names.count)
            var attempt = 0
            while !pending.isEmpty && attempt < 5 {
                attempt += 1
                let todo = pending.sorted()
                var i = 0
                while i < todo.count {
                    let batch = Array(todo[i..<min(i + 8, todo.count)])
                    let fetched = sources.onMeta(batch)
                    if !fetched.isEmpty { self?.postMeta(fetched) }
                    for (idx, v) in fetched where idx >= 0 && idx < names.count {
                        merged[names[idx]] = CachedPlaylistMeta(count: v.0, durationSec: v.1, isSmart: v.2, specialKind: v.3)
                        pending.remove(idx)
                    }
                    i += 8
                }
                if !pending.isEmpty { Thread.sleep(forTimeInterval: 0.6) } // let Music settle, then retry
            }
            PlaylistMetaCache.save(merged)
        }
    }

    private func postMeta(_ results: [Int: (Int, Int, Bool, String)]) {
        inboxLock.lock(); for (k, v) in results { inbox[k] = v }; inboxLock.unlock()
    }

    private func drainMeta() -> [Int: (Int, Int, Bool, String)] {
        inboxLock.lock(); defer { inboxLock.unlock() }
        let r = inbox; inbox = [:]; return r
    }

    // MARK: filter helpers

    private func visibleIndices() -> [Int] {
        guard !filterText.isEmpty else { return Array(0..<meta.count) }
        let q = filterText.lowercased()
        return (0..<meta.count).filter { meta[$0].name.lowercased().contains(q) }
    }
    private func clampCursorToFilter() {
        let vis = visibleIndices()
        if !vis.contains(plCursor) { plCursor = vis.first ?? 0 }
        plScroll = 0
    }
    private func loadFull() {
        guard plCursor != lastLoadedPl else { return }
        lastLoadedPl = plCursor
        if fullCache[plCursor] == nil { fullCache[plCursor] = sources.onTracks(plCursor) }
        trCursor = 0; trScroll = 0
    }
    private func badgeText(_ m: PlaylistMeta) -> (String, String)? {
        switch playlistBadge(name: m.name, isSmart: m.isSmart ?? false, specialKind: m.specialKind ?? "none") {
        case .radio: return ("RADIO", ANSICode.amber)
        case .smart: return ("SMART", ANSICode.amber)
        case .recent: return ("RECENT", ANSICode.amber)
        case .none: return nil
        }
    }

    // MARK: Scene

    func tick(snapshot: NowPlayingSnapshot) {
        // Apply metadata the background refresh thread has fetched (off-main), so
        // the slow AppleScript never blocks a render frame.
        let fresh = drainMeta()
        for (idx, v) in fresh where idx >= 0 && idx < meta.count {
            meta[idx].trackCount = v.0
            meta[idx].durationSec = v.1
            meta[idx].isSmart = v.2
            meta[idx].specialKind = v.3
            meta[idx].loaded = true
            loaded.insert(idx)
        }
        // One preview fetch per frame when the preview pane is shown and empty.
        let z = playlistZones(width: ScreenFrame.current().width)
        if focus == .playlists, z.mode == .three, previewLines[plCursor] == nil {
            previewLines[plCursor] = sources.onPreview(plCursor) ?? []
        }
    }

    func render(frame: ShellFrame, snapshot: NowPlayingSnapshot) -> String {
        var out = ""
        // Clear the body region first.
        for r in frame.bodyY..<(frame.bodyY + frame.bodyHeight) {
            out += ANSICode.moveTo(row: r, col: 1) + ANSICode.clearLine
        }
        let z = playlistZones(width: frame.width)
        let bodyTop = frame.bodyY
        let bodyBottom = frame.bodyY + frame.bodyHeight - 1

        renderRail(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom)
        renderHero(z, into: &out, bodyTop: bodyTop)
        if focus == .tracks {
            renderTrackList(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom)
        } else {
            renderPreview(z, into: &out, bodyTop: bodyTop, bodyBottom: bodyBottom)
        }
        if filtering || !filterText.isEmpty {
            out += ANSICode.moveTo(row: bodyTop, col: z.railX)
            out += "\(ANSICode.cyan)/\(ANSICode.reset) \(ANSICode.brightWhite)\(filterText)\(ANSICode.reset)\(filtering ? "\u{2588}" : "")"
        }
        return out
    }

    func handle(_ key: KeyPress) -> SceneAction {
        let trackCount = fullCache[plCursor]?.tracks.count ?? 0

        if filtering {
            switch key {
            case .enter: filtering = false
            case .escape: filtering = false; filterText = ""; clampCursorToFilter()
            case .char(let c) where c == "\u{7F}" || c == "\u{8}":
                if !filterText.isEmpty { filterText.removeLast() }
                clampCursorToFilter()
            case .char(let c): filterText.append(c); clampCursorToFilter()
            default: break
            }
            return .redraw
        }

        switch key {
        case .up:
            if focus == .playlists {
                let vis = visibleIndices()
                if let pos = vis.firstIndex(of: plCursor), pos > 0 { plCursor = vis[pos - 1] }
            } else { trCursor = max(0, trCursor - 1) }
            return .redraw
        case .down:
            if focus == .playlists {
                let vis = visibleIndices()
                if let pos = vis.firstIndex(of: plCursor), pos < vis.count - 1 { plCursor = vis[pos + 1] }
            } else { trCursor = min(trackCount - 1, trCursor + 1) }
            return .redraw
        case .char("/"):
            filtering = true
            return .redraw
        case .enter:
            if focus == .playlists {
                loadFull(); focus = .tracks; trCursor = 0; trScroll = 0
                return .redraw
            } else {
                playTrack(trCursor)
                return .push(.nowPlaying)
            }
        case .left:
            if focus == .tracks { focus = .playlists; return .redraw }
            return .pop
        case .escape:
            if focus == .tracks { focus = .playlists; return .redraw }
            return .pop
        case .char("p"):
            playPlaylist(shuffle: false); return .push(.nowPlaying)
        case .char("s"):
            playPlaylist(shuffle: true); return .push(.nowPlaying)
        case .char("b"):
            return .push(.nowPlaying)
        default:
            return .none
        }
    }

    // MARK: playback (user-initiated; brief inline stall acceptable)

    private func playTrack(_ trackIndex: Int) {
        // App-owned queue (see AppQueue.swift). macOS 26.x broke `play track N of
        // playlist X`, so instead of leaning on Music's queue we hold the playlist
        // ourselves: fetch its tracks, register the queue at position N, and play
        // that one track. The poller advances when it stops at end (Music Autoplay
        // must be off), and next/prev/Enter navigate our list — full up/down. Off-main
        // so the bulk track fetch never freezes the UI; the poller reflects playback.
        let name = playlists[plCursor]
        let pos = trackIndex + 1
        let store = self.appQueue
        let backend = self.backend
        DispatchQueue.global().async {
            let tracks = fetchPlaylistTracks(backend: backend, playlist: name)
            guard !tracks.isEmpty, pos >= 1, pos <= tracks.count else { return }
            store.set(AppQueue(playlistName: name, tracks: tracks, currentIndex: pos))
            playQueueTrack(backend: backend, playlist: name, position: pos)
        }
    }
    private func playPlaylist(shuffle: Bool) {
        // Whole-playlist play uses Music's native (gapless) queue — relinquish the
        // app-owned queue so the poller reads Music's context again.
        appQueue.clear()
        let esc = escapeAppleScriptString(playlists[plCursor])
        _ = try? syncRun { try await self.backend.runMusic("set shuffle enabled to \(shuffle)") }
        _ = try? syncRun { try await self.backend.runMusic("play playlist \"\(esc)\"") }
    }

    // MARK: render helpers (relocated from runPlaylistBrowser, region-relative)

    private func renderRail(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int) {
        let listY = bodyTop + 2
        let maxVisible = max(1, bodyBottom - listY)
        let vis = visibleIndices()
        if vis.isEmpty {
            out += ANSICode.moveTo(row: listY, col: z.railX) + "\(ANSICode.dim)(no matches)\(ANSICode.reset)"
            return
        }
        let pos = vis.firstIndex(of: plCursor) ?? 0
        if pos < plScroll { plScroll = pos }
        if pos >= plScroll + maxVisible { plScroll = pos - maxVisible + 1 }
        let end = min(vis.count, plScroll + maxVisible)
        let nameWidth = z.railWidth - 2 - metaCol - 1
        for p in plScroll..<end {
            let i = vis[p]
            let row = listY + (p - plScroll)
            out += ANSICode.moveTo(row: row, col: z.railX)
            let m = meta[i]
            let display = m.name.hasPrefix("__radio__") ? String(m.name.dropFirst("__radio__".count)) : m.name
            let nm = railName(display, nameWidth: max(1, nameWidth))
            let metaCell: String
            if !m.loaded {
                metaCell = "\(ANSICode.dim)\(String(repeating: " ", count: metaCol - 1))\u{00B7}\(ANSICode.reset)"
            } else if let (text, color) = badgeText(m) {
                let padded = String(repeating: " ", count: max(0, metaCol - text.count)) + text
                metaCell = "\(color)\(padded)\(ANSICode.reset)"
            } else {
                let c = "\(m.trackCount ?? 0)"
                let padded = String(repeating: " ", count: max(0, metaCol - c.count)) + c
                metaCell = "\(ANSICode.dim)\(padded)\(ANSICode.reset)"
            }
            let padName = nm + String(repeating: " ", count: max(0, nameWidth - nm.count))
            if i == plCursor {
                let mark = (focus == .playlists) ? ANSICode.cyan : ANSICode.dim
                out += "\(mark)\u{258C}\(ANSICode.reset) \(ANSICode.brightWhite)\(padName)\(ANSICode.reset) \(metaCell)"
            } else {
                out += "  \(ANSICode.white)\(padName)\(ANSICode.reset) \(metaCell)"
            }
        }
    }

    private func renderHero(_ z: PlaylistZones, into out: inout String, bodyTop: Int) {
        var y = bodyTop
        let m = meta[plCursor]
        let title = m.name.hasPrefix("__radio__") ? String(m.name.dropFirst("__radio__".count)) : m.name
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.bold)\(ANSICode.brightWhite)\(truncText(title, to: z.heroWidth))\(ANSICode.reset)"
        y += 1
        out += ANSICode.moveTo(row: y, col: z.heroX)
        if m.loaded, let c = m.trackCount {
            let dur = m.durationSec.map { " \u{00B7} " + formatPlaylistDuration($0) } ?? ""
            out += "\(ANSICode.dim)\(c) tracks\(dur)\(ANSICode.reset)"
        }
        y += 2
        let gw = min(28, z.heroWidth)
        let gh = 10
        let block = gradientBlock(name: m.name, width: gw, height: gh)
        var seed = 0; for b in m.name.unicodeScalars { seed = (seed &* 31 &+ Int(b.value)) & 0xffffff }
        let r = 80 + (seed & 0x7f), g = 80 + ((seed >> 8) & 0x7f), bl = 80 + ((seed >> 16) & 0x7f)
        let color = "\u{1B}[38;2;\(r);\(g);\(bl)m"
        for line in block {
            out += ANSICode.moveTo(row: y, col: z.heroX) + "\(color)\(line)\(ANSICode.reset)"
            y += 1
        }
        y += 1
        if let (text, c) = badgeText(m) {
            out += ANSICode.moveTo(row: y, col: z.heroX) + "\(c)\(text)\(ANSICode.reset)"
            y += 2
        } else { y += 1 }
        out += ANSICode.moveTo(row: y, col: z.heroX)
        out += "\(ANSICode.lime)[Enter]\(ANSICode.reset) Browse   \(ANSICode.lime)[P]\(ANSICode.reset) Play   \(ANSICode.lime)[S]\(ANSICode.reset) Shuffle   \(ANSICode.lime)[/]\(ANSICode.reset) Filter"
    }

    private func renderPreview(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int) {
        guard z.mode == .three, let rx = z.rightX else { return }
        var y = bodyTop
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.cyan)Preview\(ANSICode.reset)"; y += 1
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(z.rightWidth, 18)))\(ANSICode.reset)"; y += 1
        if let lines = previewLines[plCursor] {
            if lines.isEmpty {
                out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)(empty)\(ANSICode.reset)"
            } else {
                let maxLines = max(1, bodyBottom - y + 1)
                for (i, line) in lines.prefix(maxLines).enumerated() {
                    out += ANSICode.moveTo(row: y, col: rx)
                    let idx = String(format: "%02d", i + 1)
                    out += "\(ANSICode.dim)\(idx)\(ANSICode.reset)  \(truncText(line, to: max(2, z.rightWidth - 4)))"
                    y += 1
                }
            }
        } else {
            out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)Loading preview\u{2026}\(ANSICode.reset)"
        }
    }

    private func renderTrackList(_ z: PlaylistZones, into out: inout String, bodyTop: Int, bodyBottom: Int) {
        guard z.mode == .three, let rx = z.rightX else { return }
        var y = bodyTop
        let tracks = fullCache[plCursor]?.tracks ?? []
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.cyan)Tracks\(ANSICode.reset) \(ANSICode.dim)\(tracks.count)\(ANSICode.reset)"; y += 1
        out += ANSICode.moveTo(row: y, col: rx) + "\(ANSICode.dim)\(String(repeating: "\u{2500}", count: min(z.rightWidth, 18)))\(ANSICode.reset)"; y += 1
        let maxVis = max(1, bodyBottom - y)
        if trCursor < trScroll { trScroll = trCursor }
        if trCursor >= trScroll + maxVis { trScroll = trCursor - maxVis + 1 }
        let end = min(tracks.count, trScroll + maxVis)
        for i in trScroll..<end {
            out += ANSICode.moveTo(row: y, col: rx)
            let idx = String(format: "%02d", i + 1)
            let text = truncText(tracks[i], to: max(2, z.rightWidth - 4))
            if i == trCursor {
                out += "\(ANSICode.cyan)\u{25B6}\(ANSICode.reset) \(ANSICode.brightWhite)\(idx) \(text)\(ANSICode.reset)"
            } else {
                out += "\(ANSICode.dim)\(idx)\(ANSICode.reset)  \(text)"
            }
            y += 1
        }
    }
}
