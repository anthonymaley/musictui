# Real Covers in Library + Playlists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the gradient identicon in the Library and Playlists hero panes with real cover art fetched from the Apple Music REST API, cached on disk, rendered through the existing `artworkToAscii` pipeline.

**Architecture:** One new component (`ArtworkStore`) owns URL resolution, byte download (once, ever, to `~/.config/music/art-cache/`), negative caching, and rendered-line memoization behind injectable fetch/render seams. Scenes call `store.lines(...)` inside their hero render: a hit paints the cover, a miss paints today's gradient and kicks one background load whose completion sets a dirty flag drained by `tick` (the scenes' existing inbox+NSLock discipline). Spec: `docs/plans/2026-07-14-real-covers-design.md` — its "Verified facts" section is normative (album URLs are `{w}x{h}` templates; playlist URLs are pre-signed, expiring, used verbatim; cache bytes, never URLs).

**Tech Stack:** Swift 5.9 SPM package at `tools/music/` (module `music`), XCTest, no new dependencies. Build/test: `cd tools/music && swift test` (suite is offline, currently 249 tests, <1s tolerance for growth).

**Delegation note (repo standing preference):** Tasks 1–5 are sonnet-sized mechanical builds off this plan; Task 6's live verify and ship ritual stay with the driver.

---

## File structure

- **Create** `tools/music/Sources/TUI/ArtworkStore.swift` — fetch+cache+render, the only new unit
- **Create** `tools/music/Tests/MusicTests/ArtworkStoreTests.swift`
- **Modify** `tools/music/Sources/Backends/RESTAPIBackend.swift` — `LibraryAlbum` + `LibraryPlaylist` gain `artworkURL`; both parse sites read `attributes.artwork.url`
- **Modify** `tools/music/Tests/MusicTests/LibraryAPITests.swift` — parse coverage for the new field
- **Modify** `tools/music/Sources/TUI/Shell/LibraryScene.swift` — hero swap + `artDirty` inbox
- **Modify** `tools/music/Sources/TUI/PlaylistDataSources.swift` — `onArtworkMap` closure
- **Modify** `tools/music/Sources/TUI/Shell/Shell.swift` — build `onArtworkMap` when tokens exist
- **Modify** `tools/music/Sources/TUI/Shell/PlaylistsScene.swift` — map load + hero swap

All commands below run from `tools/music/`.

---

### Task 1: ArtworkStore pure helpers (resolveURL, cacheKey)

**Files:**
- Create: `Sources/TUI/ArtworkStore.swift`
- Create: `Tests/MusicTests/ArtworkStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/MusicTests/ArtworkStoreTests.swift
import XCTest
@testable import music

final class ArtworkStoreTests: XCTestCase {

    // MARK: resolveURL — both live-probed URL shapes (spec "Verified facts")

    func testResolveURLSubstitutesTemplate() {
        let t = "https://is1-ssl.mzstatic.com/image/thumb/Music112/v4/df/db/61/x/18UMGIM31076.rgb.jpg/{w}x{h}bb.jpg"
        XCTAssertEqual(
            ArtworkStore.resolveURL(t, width: 300, height: 300),
            "https://is1-ssl.mzstatic.com/image/thumb/Music112/v4/df/db/61/x/18UMGIM31076.rgb.jpg/300x300bb.jpg")
    }

    func testResolveURLPassesThroughPreSignedURL() {
        let t = "https://store-033.blobstore.apple.com/sq-mq-us/image?X-Amz-Expires=86400&X-Amz-Signature=abc"
        XCTAssertEqual(ArtworkStore.resolveURL(t, width: 300, height: 300), t)
    }

    // MARK: cacheKey — filesystem-safe, distinct-enough

    func testCacheKeySanitizesNonAlphanumerics() {
        XCTAssertEqual(ArtworkStore.cacheKey("p.abc123XY/z"), "p_abc123XY_z")
    }

    func testCacheKeyKeepsAlphanumerics() {
        XCTAssertEqual(ArtworkStore.cacheKey("l4bC9"), "l4bC9")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ArtworkStoreTests`
Expected: compile FAILURE — `cannot find 'ArtworkStore' in scope`

- [ ] **Step 3: Write minimal implementation**

```swift
// tools/music/Sources/TUI/ArtworkStore.swift
// Real cover art for the Library/Playlists hero panes. Album artwork URLs are
// stable {w}x{h} CDN templates; playlist artwork URLs are pre-signed and expire
// in 24h (both live-probed 2026-07-14) — so bytes are cached on disk forever,
// URLs never are. Rendering reuses artworkToAscii (chafa half-blocks, mono
// fallback). Every failure degrades silently to the caller's gradient
// placeholder; a per-session negative cache stops retry loops.
import Foundation

final class ArtworkStore {
    /// {w}x{h} substitution for album CDN templates; pre-signed playlist URLs
    /// contain no placeholder and pass through verbatim.
    static func resolveURL(_ template: String, width: Int, height: Int) -> String {
        template.replacingOccurrences(of: "{w}x{h}", with: "\(width)x\(height)")
    }

    /// Filesystem-safe cache key from a REST resource id.
    static func cacheKey(_ raw: String) -> String {
        String(raw.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ArtworkStoreTests`
Expected: 4 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/TUI/ArtworkStore.swift Tests/MusicTests/ArtworkStoreTests.swift
git commit -m "feat(artwork): ArtworkStore URL resolution + cache keys (TDD)"
```

---

### Task 2: ArtworkStore fetch/cache/render flow

**Files:**
- Modify: `Sources/TUI/ArtworkStore.swift`
- Modify: `Tests/MusicTests/ArtworkStoreTests.swift`

- [ ] **Step 1: Write the failing tests** (append inside `ArtworkStoreTests`)

```swift
    // MARK: lines() — fetch/cache/render via injected seams (no network, no chafa)

    private func tmpDir() -> String {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("art-test-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    func testMissFetchesRendersThenHitsMemory() {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var fetches = 0
        let ready = expectation(description: "onReady")
        let store = ArtworkStore(cacheDir: dir,
                                 fetch: { _ in fetches += 1; return Data([1, 2, 3]) },
                                 render: { _, _, _ in ["ART"] })
        // First call: miss — returns nil, kicks background load.
        XCTAssertNil(store.lines(key: "a.1", url: "u", width: 8, height: 4) { ready.fulfill() })
        wait(for: [ready], timeout: 2)
        // Second call: memory hit, no new fetch.
        XCTAssertEqual(store.lines(key: "a.1", url: "u", width: 8, height: 4) { }, ["ART"])
        XCTAssertEqual(fetches, 1)
        // Bytes landed on disk under the sanitized key.
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/a_1"))
    }

    func testDiskHitSkipsFetch() {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try? Data([9]).write(to: URL(fileURLWithPath: "\(dir)/a_2"))
        let ready = expectation(description: "onReady")
        let store = ArtworkStore(cacheDir: dir,
                                 fetch: { _ in XCTFail("fetch must not run on disk hit"); return nil },
                                 render: { _, _, _ in ["DISK"] })
        XCTAssertNil(store.lines(key: "a.2", url: "u", width: 8, height: 4) { ready.fulfill() })
        wait(for: [ready], timeout: 2)
        XCTAssertEqual(store.lines(key: "a.2", url: "u", width: 8, height: 4) { }, ["DISK"])
    }

    func testFailedFetchIsNegativeCachedForTheSession() {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        var fetches = 0
        let store = ArtworkStore(cacheDir: dir,
                                 fetch: { _ in fetches += 1; return nil },
                                 render: { _, _, _ in XCTFail("render must not run"); return [] })
        XCTAssertNil(store.lines(key: "a.3", url: "u", width: 8, height: 4) { XCTFail("onReady must not fire") })
        // Give the background queue a beat to record the failure.
        let settle = expectation(description: "settle"); DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        // Second call: negative-cached — nil, and no second fetch.
        XCTAssertNil(store.lines(key: "a.3", url: "u", width: 8, height: 4) { XCTFail("onReady must not fire") })
        let settle2 = expectation(description: "settle2"); DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle2.fulfill() }
        wait(for: [settle2], timeout: 2)
        XCTAssertEqual(fetches, 1)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ArtworkStoreTests`
Expected: compile FAILURE — `ArtworkStore` has no initializer/`lines`

- [ ] **Step 3: Implement the flow** (append inside `ArtworkStore`, below `cacheKey`)

```swift
    private let cacheDir: String
    private let fetch: (String) -> Data?
    private let render: (String, Int, Int) -> [String]
    private let queue = DispatchQueue(label: "music.artwork")
    private let lock = NSLock()
    private var rendered: [String: [String]] = [:]   // "\(key)|\(w)x\(h)" → lines
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []             // per-session negative cache

    init(cacheDir: String = NSString(string: "~/.config/music/art-cache").expandingTildeInPath,
         fetch: ((String) -> Data?)? = nil,
         render: ((String, Int, Int) -> [String])? = nil) {
        self.cacheDir = cacheDir
        self.fetch = fetch ?? { urlString in
            guard let url = URL(string: urlString) else { return nil }
            return try? Data(contentsOf: url)   // store's serial queue only, never the main thread
        }
        self.render = render ?? { path, w, h in artworkToAscii(path: path, width: w, height: h) }
    }

    /// Rendered cover lines if ready, else nil — and (once per key+size) a
    /// background fetch+render is kicked; `onReady` fires from the store's queue
    /// when lines land. Callers repaint on their next tick and get the memory hit.
    func lines(key rawKey: String, url: String, width: Int, height: Int,
               onReady: @escaping () -> Void) -> [String]? {
        let key = Self.cacheKey(rawKey)
        let memoKey = "\(key)|\(width)x\(height)"
        lock.lock()
        if let hit = rendered[memoKey] { lock.unlock(); return hit }
        if failed.contains(key) || inFlight.contains(memoKey) { lock.unlock(); return nil }
        inFlight.insert(memoKey)
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let path = "\(self.cacheDir)/\(key)"
            if !FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.createDirectory(atPath: self.cacheDir, withIntermediateDirectories: true)
                guard let data = self.fetch(url), !data.isEmpty else {
                    self.lock.lock(); self.failed.insert(key); self.inFlight.remove(memoKey); self.lock.unlock()
                    return
                }
                try? data.write(to: URL(fileURLWithPath: path))
            }
            let lines = self.render(path, width, height)
            self.lock.lock()
            if lines.isEmpty { self.failed.insert(key) } else { self.rendered[memoKey] = lines }
            self.inFlight.remove(memoKey)
            self.lock.unlock()
            if !lines.isEmpty { onReady() }
        }
        return nil
    }
```

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: all tests PASS (249 existing + 7 new)

- [ ] **Step 5: Commit**

```bash
git add Sources/TUI/ArtworkStore.swift Tests/MusicTests/ArtworkStoreTests.swift
git commit -m "feat(artwork): fetch-once disk cache + rendered-line memo + negative cache (TDD)"
```

---

### Task 3: Parse `artwork.url` into LibraryAlbum and LibraryPlaylist

**Files:**
- Modify: `Sources/Backends/RESTAPIBackend.swift:334-359` (LibraryAlbum + parseLibraryAlbums), `:137` region (LibraryPlaylist), `:145-162` (libraryPlaylists parse loop)
- Modify: `Tests/MusicTests/LibraryAPITests.swift`

- [ ] **Step 1: Write the failing tests** (append inside the existing `LibraryAPITests` class)

```swift
    func testParseLibraryAlbumsReadsArtworkURL() {
        let json = """
        {"data":[{"id":"l.1","attributes":{"name":"Crush","artistName":"Floating Points",
          "trackCount":12,"artwork":{"width":1200,"height":1200,
          "url":"https://is1-ssl.mzstatic.com/image/thumb/x.jpg/{w}x{h}bb.jpg"}}}]}
        """.data(using: .utf8)!
        let albums = parseLibraryAlbums(from: json)
        XCTAssertEqual(albums.first?.artworkURL,
                       "https://is1-ssl.mzstatic.com/image/thumb/x.jpg/{w}x{h}bb.jpg")
    }

    func testParseLibraryAlbumsMissingArtworkIsNil() {
        let json = """
        {"data":[{"id":"l.2","attributes":{"name":"X","artistName":"Y","trackCount":3}}]}
        """.data(using: .utf8)!
        XCTAssertNil(parseLibraryAlbums(from: json).first?.artworkURL)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LibraryAPITests`
Expected: compile FAILURE — `LibraryAlbum` has no member `artworkURL`

- [ ] **Step 3: Extend both models and parse sites**

In `RESTAPIBackend.swift`, replace the `LibraryAlbum` struct and the return inside `parseLibraryAlbums`:

```swift
struct LibraryAlbum { let id: String; let name: String; let artist: String; let trackCount: Int
    var artworkURL: String? = nil
    func toDict() -> [String: Any] { ["id": id, "name": name, "artist": artist, "trackCount": trackCount] } }
```

```swift
        return LibraryAlbum(id: obj["id"] as? String ?? "",
                            name: a["name"] as? String ?? "Unknown",
                            artist: a["artistName"] as? String ?? "Unknown",
                            // Library-albums trackCount = tracks of this album IN the
                            // library; a loose playlist-song stub reads as 1, which the
                            // album-artists filter uses to exclude it. Missing → 0.
                            trackCount: a["trackCount"] as? Int ?? 0,
                            artworkURL: (a["artwork"] as? [String: Any])?["url"] as? String)
```

Extend `LibraryPlaylist` (at `:137`) the same way — `var artworkURL: String? = nil` — and in `libraryPlaylists()` change the append to:

```swift
                out.append(LibraryPlaylist(id: id, name: name,
                                           artworkURL: (attrs["artwork"] as? [String: Any])?["url"] as? String))
```

Note: `LibraryAlbum(id:name:artist:trackCount:)` call sites without artwork (e.g. `LibraryScene.swift:710`) keep compiling because `artworkURL` defaults to nil — verify with the build, do NOT touch them.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: all PASS (new count: +2)

- [ ] **Step 5: Commit**

```bash
git add Sources/Backends/RESTAPIBackend.swift Tests/MusicTests/LibraryAPITests.swift
git commit -m "feat(artwork): parse artwork.url into LibraryAlbum/LibraryPlaylist (TDD)"
```

---

### Task 4: Library hero swap

**Files:**
- Modify: `Sources/TUI/Shell/LibraryScene.swift` (fields near `:159`; `tick` drain near `:295-304`; `renderHero` at `:868-905`)

No new unit tests: this is render wiring on the scene's existing inbox pattern; correctness is covered by Task 2's store tests plus Task 6's live verify.

- [ ] **Step 1: Add store + dirty flag** (next to the other inbox fields, after `previewInbox` at `:175`)

```swift
    // Real hero covers: store owns fetch/cache/render; onReady sets artDirty
    // under inboxLock (same discipline as the streaming inboxes) and tick
    // drains it into `changed` so the swap paints on the next frame.
    private let artwork = ArtworkStore()
    private var artDirty = false
```

- [ ] **Step 2: Drain in tick** — inside the existing `inboxLock.lock()` block at the top of `tick` (`:295-304`), add alongside the other drains:

```swift
        let artLanded = artDirty; artDirty = false
```

and after the unlock, with the other `changed` updates:

```swift
        if artLanded { changed = true }
```

- [ ] **Step 3: Swap the hero art block** — in `renderHero`, replace the gradient block (the lines from `let gw = min(28, z.heroWidth)` through the `for line in block { ... }` loop, currently `:879-889`) with:

```swift
        let gw = min(28, z.heroWidth)
        let gh = 10
        var artLines: [String]? = nil
        if let template = a.artworkURL {
            artLines = artwork.lines(key: a.id,
                                     url: ArtworkStore.resolveURL(template, width: 300, height: 300),
                                     width: gw, height: gh) { [weak self] in
                guard let self else { return }
                self.inboxLock.lock(); self.artDirty = true; self.inboxLock.unlock()
            }
        }
        if let art = artLines {
            // Pad/cap to exactly gh rows so the hero's height never shifts and
            // stale gradient rows are overwritten (chafa may emit fewer rows).
            let blank = String(repeating: " ", count: gw)
            let rows = art.prefix(gh) + Array(repeating: blank, count: max(0, gh - art.count))
            for line in rows {
                out += ANSICode.moveTo(row: y, col: z.heroX) + line + ANSICode.reset
                y += 1
            }
        } else {
            let block = gradientBlock(name: a.name + a.artist, width: gw, height: gh)
            var seed = 0; for b in (a.name + a.artist).unicodeScalars { seed = (seed &* 31 &+ Int(b.value)) & 0xffffff }
            let r = 80 + (seed & 0x7f), g = 80 + ((seed >> 8) & 0x7f), bl = 80 + ((seed >> 16) & 0x7f)
            let color = "\u{1B}[38;2;\(r);\(g);\(bl)m"
            for line in block {
                out += ANSICode.moveTo(row: y, col: z.heroX) + "\(color)\(line)\(ANSICode.reset)"
                y += 1
            }
        }
```

- [ ] **Step 4: Build + full suite**

Run: `swift test`
Expected: compiles, all PASS (no count change)

- [ ] **Step 5: Commit**

```bash
git add Sources/TUI/Shell/LibraryScene.swift
git commit -m "feat(library): real cover in the hero pane, gradient while loading"
```

---

### Task 5: Playlists hero swap (name→artwork map)

**Files:**
- Modify: `Sources/TUI/PlaylistDataSources.swift` (struct at top)
- Modify: `Sources/TUI/Shell/Shell.swift:30-36` (scene construction) and the bottom of `PlaylistDataSources.swift` where `makePlaylistDataSources` lives
- Modify: `Sources/TUI/Shell/PlaylistsScene.swift` (fields near `:38`; `tick`; `renderHero` at `:407-430`)

- [ ] **Step 1: Extend PlaylistDataSources** — add to the struct (after `onTracks`):

```swift
    /// One-shot REST map of lowercased-trimmed playlist name → (REST id, artwork
    /// URL), for real hero covers. nil when the user isn't signed in / no dev
    /// token — the scene keeps gradients, exactly today's token-less behavior.
    /// Name matching is heuristic (same class as albumArtistSet); built-in smart
    /// playlists aren't API-visible and simply never match.
    let onArtworkMap: (() -> [String: (id: String, url: String)])?
```

- [ ] **Step 2: Build the closure in `makePlaylistDataSources`** — find its signature at the bottom of `PlaylistDataSources.swift` and add a trailing parameter `artworkAPI: RESTAPIBackend? = nil`; in the returned struct set:

```swift
        onArtworkMap: artworkAPI.map { api in
            {
                let playlists = (try? syncRun { try await api.libraryPlaylists() }) ?? []
                var map: [String: (id: String, url: String)] = [:]
                for p in playlists {
                    guard let u = p.artworkURL else { continue }
                    map[p.name.lowercased().trimmingCharacters(in: .whitespaces)] = (p.id, u)
                }
                return map
            }
        }
```

- [ ] **Step 3: Wire Shell** — in `Shell.swift` `.playlists` branch (`:23-38`), build a best-effort api BEFORE the `PlaylistsScene(` call and pass it through (tokens optional here — unlike the Library branch, absence must NOT refuse the scene):

```swift
            let auth = AuthManager()
            var artworkAPI: RESTAPIBackend? = nil
            if let devToken = try? auth.requireDeveloperToken(), auth.userToken() != nil {
                artworkAPI = RESTAPIBackend(developerToken: devToken,
                                            userToken: auth.userToken(),
                                            storefront: auth.storefront())
            }
```

and change the sources argument to `makePlaylistDataSources(backend: backend, names: names, artworkAPI: artworkAPI)`.

- [ ] **Step 4: Load the map + swap the hero in PlaylistsScene**

Fields (after `fullInFlight` at `:52`):

```swift
    // Real hero covers. artMap lands once from a background REST walk (inbox
    // discipline: posted under inboxLock, drained in tick); ArtworkStore then
    // owns per-cover fetch/cache/render. No token → onArtworkMap is nil and
    // gradients stay.
    private let artwork = ArtworkStore()
    private var artMap: [String: (id: String, url: String)] = [:]
    private var artMapInbox: [String: (id: String, url: String)]? = nil
    private var artMapStarted = false
    private var artDirty = false
```

Kick once (in `tick`, before the existing drains — mirror how other scenes lazy-start):

```swift
        if !artMapStarted, let load = sources.onArtworkMap {
            artMapStarted = true
            Thread.detachNewThread { [weak self] in
                let map = load()
                guard let self else { return }
                self.inboxLock.lock(); self.artMapInbox = map; self.inboxLock.unlock()
            }
        }
```

Drain (inside the existing `inboxLock` drain in `tick`):

```swift
        let landedMap = artMapInbox; artMapInbox = nil
        let artLanded = artDirty; artDirty = false
```

after unlock:

```swift
        if let m = landedMap { artMap = m; changed = true }
        if artLanded { changed = true }
```

Hero swap — in `renderHero` (`:420-430`), replace from `let gw = min(28, z.heroWidth)` through the gradient `for` loop with (note the lookup key is the display `title`, radio prefix already stripped at `:410`):

```swift
        let gw = min(28, z.heroWidth)
        let gh = 10
        var artLines: [String]? = nil
        if let entry = artMap[title.lowercased().trimmingCharacters(in: .whitespaces)] {
            artLines = artwork.lines(key: entry.id,
                                     url: ArtworkStore.resolveURL(entry.url, width: 300, height: 300),
                                     width: gw, height: gh) { [weak self] in
                guard let self else { return }
                self.inboxLock.lock(); self.artDirty = true; self.inboxLock.unlock()
            }
        }
        if let art = artLines {
            let blank = String(repeating: " ", count: gw)
            let rows = art.prefix(gh) + Array(repeating: blank, count: max(0, gh - art.count))
            for line in rows {
                out += ANSICode.moveTo(row: y, col: z.heroX) + line + ANSICode.reset
                y += 1
            }
        } else {
            let block = gradientBlock(name: m.name, width: gw, height: gh)
            var seed = 0; for b in m.name.unicodeScalars { seed = (seed &* 31 &+ Int(b.value)) & 0xffffff }
            let r = 80 + (seed & 0x7f), g = 80 + ((seed >> 8) & 0x7f), bl = 80 + ((seed >> 16) & 0x7f)
            let color = "\u{1B}[38;2;\(r);\(g);\(bl)m"
            for line in block {
                out += ANSICode.moveTo(row: y, col: z.heroX) + "\(color)\(line)\(ANSICode.reset)"
                y += 1
            }
        }
```

- [ ] **Step 5: Build + full suite**

Run: `swift test`
Expected: compiles, all PASS. If `PlaylistDataSourcesTests` constructs the struct memberwise, add `onArtworkMap: nil` there — expected compile fix, nothing else.

- [ ] **Step 6: Commit**

```bash
git add Sources/TUI/PlaylistDataSources.swift Sources/TUI/Shell/Shell.swift Sources/TUI/Shell/PlaylistsScene.swift Tests/MusicTests/PlaylistDataSourcesTests.swift
git commit -m "feat(playlists): real hero covers via REST name->artwork map"
```

---

### Task 6: Live verify, docs, ship 3.5.0 (driver, not delegated)

**Files:**
- Modify: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (×2 fields), `tools/music/Sources/Music.swift` (CommandConfiguration version)
- Possibly modify: `README.md`, `skills/music/SKILL.md`, `docs/guide.md` (docs convention: they move with TUI behavior changes)

- [ ] **Step 1: Install and live-verify per the spec's plan**

Run `scripts/install.sh`, then `music` and walk: Library album focus (gradient → cover swap, re-focus instant, relaunch instant via disk cache); Playlists cloud playlist (cover) vs "Recently Played" (gradient, honest gap); move `~/.config/music/user-token` aside → both tabs behave exactly as today, restore it after. Fix-and-retest anything that fails BEFORE proceeding; findings go in the session log.

- [ ] **Step 2: Docs touch** — `grep -rn "gradient\|identicon" README.md docs/guide.md skills/music/SKILL.md`; update any hero-pane description to mention real covers (Library + Playlists), keep it one line each.

- [ ] **Step 3: Version bump ×4 + rebuild** — 3.4.2 → 3.5.0 in all four locations, re-run `scripts/install.sh`, confirm `music --version` prints 3.5.0.

- [ ] **Step 4: Full suite** — `swift test`, all green.

- [ ] **Step 5: Ship ritual (one sequence, not a follow-up)**

```bash
git add -A && git diff --cached --stat   # inspect the staged set first
git commit -m "3.5.0: real album covers in Library + Playlists heroes"
git push
git tag v3.5.0 && git push origin v3.5.0
gh release create v3.5.0 --notes-file <(printf '%s\n' "Real cover art in the Library and Playlists hero panes — fetched once from the Apple Music API, cached on disk, rendered in the terminal like the Now tab. Gradients remain as loading/offline placeholders.")
gh release view v3.5.0   # read the body back
```

---

## Self-review (done at authoring time)

- **Spec coverage:** resolveURL both shapes → T1; bytes-not-URLs cache + negative cache + injectable seams → T2; parser fields both models → T3; Library inbox wiring → T4; Playlists map + token-less unchanged → T5; live-verify plan + ship → T6. No gaps found.
- **Placeholders:** none; every code step carries the code.
- **Type consistency:** `ArtworkStore.lines(key:url:width:height:onReady:)` identical in T2/T4/T5; `onArtworkMap` optional closure identical in T5's three files; `artworkURL: String?` with nil default in both models (T3) is what T4/T5 read.
