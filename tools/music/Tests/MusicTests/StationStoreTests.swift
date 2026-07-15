import XCTest
@testable import music

final class StationStoreTests: XCTestCase {
    private var tmp: String!

    override func setUp() {
        super.setUp()
        tmp = NSTemporaryDirectory() + "station-store-\(UUID().uuidString).json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
        super.tearDown()
    }

    private func station(_ id: String, _ name: String = "N") -> Station {
        Station(id: id, name: name, url: "https://music.apple.com/us/station/s/\(id)",
                isLive: nil, artworkURL: nil)
    }

    func testEmptyWhenFileMissing() {
        XCTAssertEqual(StationStore(path: tmp).favorites(), [])
    }

    func testAddThenRoundTripFromDisk() throws {
        let s = StationStore(path: tmp)
        try s.add(station("ra.1", "Apple Music 1"))
        XCTAssertEqual(StationStore(path: tmp).favorites().map(\.id), ["ra.1"])
        XCTAssertEqual(StationStore(path: tmp).favorites().first?.name, "Apple Music 1")
    }

    func testAddIsIdempotentOnID() throws {
        let s = StationStore(path: tmp)
        try s.add(station("ra.1"))
        try s.add(station("ra.1"))
        XCTAssertEqual(s.favorites().count, 1)
    }

    /// Re-adding refreshes metadata (a later API resolve may supply a real name).
    func testReAddReplacesMetadata() throws {
        let s = StationStore(path: tmp)
        try s.add(station("ra.1", "Bbc Radio 1"))
        try s.add(station("ra.1", "BBC Radio 1"))
        XCTAssertEqual(s.favorites().count, 1)
        XCTAssertEqual(s.favorites().first?.name, "BBC Radio 1")
    }

    func testRemove() throws {
        let s = StationStore(path: tmp)
        try s.add(station("ra.1"))
        try s.add(station("ra.2"))
        try s.remove(id: "ra.1")
        XCTAssertEqual(s.favorites().map(\.id), ["ra.2"])
    }

    func testRemoveMissingIsNoOp() throws {
        let s = StationStore(path: tmp)
        try s.add(station("ra.1"))
        try s.remove(id: "nope")
        XCTAssertEqual(s.favorites().count, 1)
    }

    func testIsFavorite() throws {
        let s = StationStore(path: tmp)
        try s.add(station("ra.1"))
        XCTAssertTrue(s.isFavorite(id: "ra.1"))
        XCTAssertFalse(s.isFavorite(id: "ra.2"))
    }

    func testInsertionOrderPreserved() throws {
        let s = StationStore(path: tmp)
        try s.add(station("ra.1")); try s.add(station("ra.2")); try s.add(station("ra.3"))
        XCTAssertEqual(s.favorites().map(\.id), ["ra.1", "ra.2", "ra.3"])
    }

    func testCorruptFileDegradesToEmpty() throws {
        try "not json".write(toFile: tmp, atomically: true, encoding: .utf8)
        XCTAssertEqual(StationStore(path: tmp).favorites(), [])
    }
}
