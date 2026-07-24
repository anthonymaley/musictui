// tools/music/Tests/MusicTests/AppQueueTests.swift
import XCTest
@testable import music

final class AppQueueTests: XCTestCase {
    private func makeQueue(_ count: Int, at index: Int = 1) -> AppQueue {
        AppQueue(
            playlistName: "P",
            tracks: (1...count).map { TrackListEntry(index: $0, name: "T\($0)", artist: "A", isCurrent: false) },
            currentIndex: index
        )
    }

    // MARK: - step

    func testStepAdvancesAndReturnsSourcePosition() {
        let store = AppQueueStore()
        store.set(makeQueue(5, at: 2))
        let r = store.step(1)
        XCTAssertEqual(r?.playlist, "P")
        XCTAssertEqual(r?.position, 3)
        XCTAssertEqual(store.read()?.currentIndex, 3)
    }

    func testStepBackwardReachesTrackOne() {
        // The whole point of the app-owned queue: backward nav must not floor
        // mid-list the way Music's sticky resume position did.
        let store = AppQueueStore()
        store.set(makeQueue(5, at: 2))
        XCTAssertEqual(store.step(-1)?.position, 1)
    }

    func testStepOffEitherEndReturnsNilAndKeepsPosition() {
        let store = AppQueueStore()
        store.set(makeQueue(3, at: 3))
        XCTAssertNil(store.step(1))
        XCTAssertEqual(store.read()?.currentIndex, 3, "a refused step must not move the queue")
        store.set(makeQueue(3, at: 1))
        XCTAssertNil(store.step(-1))
    }

    func testStepWithNoQueueIsNil() {
        XCTAssertNil(AppQueueStore().step(1))
    }

    // MARK: - jump

    func testJumpToAbsolutePosition() {
        let store = AppQueueStore()
        store.set(makeQueue(5, at: 1))
        XCTAssertEqual(store.jump(to: 4)?.position, 4)
        XCTAssertEqual(store.read()?.currentIndex, 4)
    }

    func testJumpOutOfRangeIsNil() {
        let store = AppQueueStore()
        store.set(makeQueue(3, at: 1))
        XCTAssertNil(store.jump(to: 0))
        XCTAssertNil(store.jump(to: 4))
    }

    // MARK: - shuffled queues: play-order index vs source position

    func testShuffledQueueStepReturnsSourcePositionNotPlayOrder() {
        // Play order [3, 1, 2]: stepping from play-order 1 to 2 must play
        // SOURCE track 1 (`play track N of playlist` needs source positions).
        let tracks = [3, 1, 2].map { TrackListEntry(index: $0, name: "T\($0)", artist: "A", isCurrent: false) }
        let store = AppQueueStore()
        store.set(AppQueue(playlistName: "P", tracks: tracks, currentIndex: 1))
        XCTAssertEqual(store.step(1)?.position, 1)
        XCTAssertEqual(store.step(1)?.position, 2)
    }

    // MARK: - window

    func testWindowMarksCurrentByPlayOrder() {
        let q = makeQueue(4, at: 3)
        let w = appQueueWindow(q)
        XCTAssertEqual(w.name, "P")
        XCTAssertEqual(w.tracks.count, 4)
        XCTAssertTrue(w.tracks[2].isCurrent)
        XCTAssertEqual(w.tracks.filter(\.isCurrent).count, 1)
        XCTAssertEqual(w.tracks[0].index, 1, "window indices are play-order positions for Enter-jump")
    }

    // MARK: - tolerant album matching (strict-clause fallback for artist drift)

    func testNormalizeCreditFoldsSeparatorPunctuation() {
        // Apple Music's display credit uses ", " where the local library stores
        // " & " (observed live on the pre-release "Mere Mortals" — Floating Points,
        // San Francisco Ballet Orchestra). Both must fold to one key so an exact
        // whose-clause miss can still be reconciled.
        XCTAssertEqual(
            normalizeCredit("Floating Points, San Francisco Ballet Orchestra"),
            normalizeCredit("Floating Points & San Francisco Ballet Orchestra"))
        // But genuinely different ensembles must NOT collapse together.
        XCTAssertNotEqual(
            normalizeCredit("Floating Points & San Francisco Ballet Orchestra"),
            normalizeCredit("Floating Points & San Francisco Symphony"))
    }

    func testParseLibraryAlbumRowsReadsAlbumArtistAndCloudStatus() {
        let fs = String(asFieldSep)
        let raw = "3\(fs)Movement 1 - Fire\(fs)Floating Points & SF Ballet\(fs)Floating Points & San Francisco Ballet Orchestra\(fs)prerelease\n"
                + "4\(fs)Movement 5 - Pandora’s Creation\(fs)FP\(fs)Floating Points & San Francisco Ballet Orchestra\(fs)subscription"
        let rows = parseLibraryAlbumRows(raw)
        XCTAssertEqual(rows.map(\.index), [3, 4])
        XCTAssertEqual(rows[1].name, "Movement 5 - Pandora’s Creation")
        XCTAssertEqual(rows[0].albumArtist, "Floating Points & San Francisco Ballet Orchestra")
        XCTAssertEqual(rows[0].cloudStatus, "prerelease")
        XCTAssertEqual(rows[1].cloudStatus, "subscription")
    }

    func testParseLibraryAlbumRowsSkipsMalformed() {
        let fs = String(asFieldSep)
        // non-numeric index, blank line, and a 4-field line (missing cloud status) all dropped
        let raw = "x\(fs)a\(fs)b\(fs)c\(fs)d\n\n7\(fs)only\(fs)four\(fs)fields\n9\(fs)Fire\(fs)FP\(fs)FP & SFBO\(fs)subscription"
        XCTAssertEqual(parseLibraryAlbumRows(raw).map(\.index), [9])
    }

    func testSelectAlbumTracksReturnsAllWhenOneAlbumArtist() {
        // The reported bug: every track shares one album artist, but the requested
        // artist string (from REST) matches none of them. A title-scoped fetch has
        // no ambiguity to resolve, so all of it must play.
        let aa = "Floating Points & San Francisco Ballet Orchestra"
        let rows = [
            LibraryAlbumRow(index: 1, name: "M1", artist: "FP & Merks", albumArtist: aa, cloudStatus: "subscription"),
            LibraryAlbumRow(index: 2, name: "M2", artist: "FP & Adefris", albumArtist: aa, cloudStatus: "subscription"),
        ]
        let picked = selectAlbumTracks(rows, requestedArtist: "Floating Points, San Francisco Ballet Orchestra")
        XCTAssertEqual(picked.map(\.index), [1, 2])
    }

    func testSelectAlbumTracksDisambiguatesSameTitleCollisionByArtist() {
        // Two different albums both titled "Greatest Hits" in one library: play the
        // group whose album artist matches the requested one (punctuation-tolerant).
        let rows = [
            LibraryAlbumRow(index: 1, name: "a", artist: "Queen", albumArtist: "Queen", cloudStatus: "subscription"),
            LibraryAlbumRow(index: 2, name: "b", artist: "Queen", albumArtist: "Queen", cloudStatus: "subscription"),
            LibraryAlbumRow(index: 3, name: "c", artist: "TLC", albumArtist: "TLC", cloudStatus: "subscription"),
        ]
        XCTAssertEqual(selectAlbumTracks(rows, requestedArtist: "Queen").map(\.index), [1, 2])
    }

    func testSelectAlbumTracksAmbiguousUnmatchedReturnsEmpty() {
        // A same-title collision where the requested artist matches neither group:
        // refuse to guess — a "couldn't load" beats playing the wrong album.
        let rows = [
            LibraryAlbumRow(index: 1, name: "a", artist: "Queen", albumArtist: "Queen", cloudStatus: "subscription"),
            LibraryAlbumRow(index: 2, name: "c", artist: "TLC", albumArtist: "TLC", cloudStatus: "subscription"),
        ]
        XCTAssertTrue(selectAlbumTracks(rows, requestedArtist: "Nirvana").isEmpty)
    }

    func testSelectAlbumTracksEmptyInputReturnsEmpty() {
        XCTAssertTrue(selectAlbumTracks([], requestedArtist: "X").isEmpty)
    }

    func testIsPlayableCloudStatus() {
        // Denylist, not allowlist: only genuinely-unavailable statuses are excluded,
        // so local files (unknown / other) and streamable tracks stay playable.
        XCTAssertFalse(isPlayableCloudStatus("prerelease"))          // verified live: play track no-ops
        XCTAssertFalse(isPlayableCloudStatus("no longer available"))
        XCTAssertFalse(isPlayableCloudStatus("removed"))
        XCTAssertFalse(isPlayableCloudStatus("Prerelease"))          // case-insensitive
        XCTAssertTrue(isPlayableCloudStatus("subscription"))
        XCTAssertTrue(isPlayableCloudStatus("purchased"))
        XCTAssertTrue(isPlayableCloudStatus("unknown"))              // local files must not be dropped
        XCTAssertTrue(isPlayableCloudStatus(""))
    }

    func testPrereleaseAlbumResolvesToPlayableSubsetOnly() {
        // The exact Mere Mortals scenario at the unit level: 14 title-matched rows,
        // one album artist, only Movements 5 & 10 streamable — the rest prerelease.
        // Disambiguation keeps the whole album; the playability filter leaves the two
        // that can actually play, and the matched count (14) survives for "N of M".
        let aa = "Floating Points & San Francisco Ballet Orchestra"
        let rows = (1...14).map { i in
            LibraryAlbumRow(index: i, name: "Movement \(i)", artist: "FP", albumArtist: aa,
                            cloudStatus: (i == 5 || i == 10) ? "subscription" : "prerelease")
        }
        let album = selectAlbumTracks(rows, requestedArtist: "Floating Points, San Francisco Ballet Orchestra")
        XCTAssertEqual(album.count, 14, "one album — disambiguation keeps all 14")
        let playable = album.filter { isPlayableCloudStatus($0.cloudStatus) }
        XCTAssertEqual(playable.map(\.index), [5, 10], "only the two subscription movements can play")
    }

    // MARK: - seek parsing (CLI)

    func testParseSeekTargets() {
        XCTAssertEqual(parseSeekTarget("+30")?.delta, 30)
        XCTAssertEqual(parseSeekTarget("-15")?.delta, -15)
        XCTAssertEqual(parseSeekTarget("90")?.absolute, 90)
        XCTAssertEqual(parseSeekTarget("1:30")?.absolute, 90)
        XCTAssertEqual(parseSeekTarget("0:05")?.absolute, 5)
        XCTAssertNil(parseSeekTarget("abc"))
        XCTAssertNil(parseSeekTarget("1:75"))
        XCTAssertNil(parseSeekTarget(""))
    }
}
