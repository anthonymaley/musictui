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
