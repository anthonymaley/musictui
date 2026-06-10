// tools/music/Tests/MusicTests/PlaybackContextTests.swift
import XCTest
@testable import music

final class PlaybackContextTests: XCTestCase {
    func testParsesWindowMarksCurrentByIndex() {
        // Format: "name\ncurrentIndex\ntotal\nwindowStart\nidx␟title␟artist..."
        // (fields are ASCII unit separator — titles can legally contain "|")
        let fs = String(asFieldSep)
        let raw = "Friday Mix\n3\n42\n2\n2\(fs)Song B\(fs)Artist B\n3\(fs)Song C\(fs)Artist C\n4\(fs)Song C\(fs)Artist C"
        let q = parseContextQueue(raw)
        XCTAssertEqual(q.name, "Friday Mix")
        XCTAssertEqual(q.currentIndex, 3)
        XCTAssertEqual(q.total, 42)
        XCTAssertEqual(q.tracks.count, 3)
        XCTAssertEqual(q.tracks[1].index, 3)
        XCTAssertTrue(q.tracks[1].isCurrent)
        XCTAssertFalse(q.tracks[2].isCurrent)
    }
    func testEmptyOnMalformed() {
        let q = parseContextQueue("")
        XCTAssertEqual(q.name, "")
        XCTAssertTrue(q.tracks.isEmpty)
    }
}
