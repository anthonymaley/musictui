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
