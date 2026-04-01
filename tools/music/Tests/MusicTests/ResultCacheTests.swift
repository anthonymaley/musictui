import XCTest
@testable import music

final class ResultCacheTests: XCTestCase {
    let testDir = FileManager.default.temporaryDirectory.appendingPathComponent("music-test-\(UUID().uuidString)")

    override func setUp() {
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
    }

    func testWriteAndReadSongs() throws {
        let cache = ResultCache(directory: testDir.path)
        let songs: [SongResult] = [
            SongResult(index: 1, title: "Alpha", artist: "ArtistA", album: "AlbumA", catalogId: "id1"),
            SongResult(index: 2, title: "Beta", artist: "ArtistB", album: "AlbumB", catalogId: "id2"),
        ]
        try cache.writeSongs(songs)
        let loaded = try cache.readSongs()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].title, "Alpha")
        XCTAssertEqual(loaded[1].catalogId, "id2")
    }

    func testWriteAndReadSpeakers() throws {
        let cache = ResultCache(directory: testDir.path)
        let speakers: [SpeakerResult] = [
            SpeakerResult(index: 1, name: "Kitchen", selected: true, volume: 60),
            SpeakerResult(index: 2, name: "MacBook Pro", selected: false, volume: 15),
        ]
        try cache.writeSpeakers(speakers)
        let loaded = try cache.readSpeakers()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "Kitchen")
        XCTAssertEqual(loaded[1].volume, 15)
    }

    func testLookupSongByIndex() throws {
        let cache = ResultCache(directory: testDir.path)
        let songs = [
            SongResult(index: 1, title: "Alpha", artist: "ArtistA", album: "AlbumA", catalogId: "id1"),
            SongResult(index: 2, title: "Beta", artist: "ArtistB", album: "AlbumB", catalogId: "id2"),
        ]
        try cache.writeSongs(songs)
        let song = try cache.lookupSong(index: 2)
        XCTAssertEqual(song.title, "Beta")
    }

    func testLookupSongOutOfRange() {
        let cache = ResultCache(directory: testDir.path)
        XCTAssertThrowsError(try cache.lookupSong(index: 1)) { error in
            XCTAssertTrue(error is CacheError)
        }
    }

    func testLookupSpeakerByIndex() throws {
        let cache = ResultCache(directory: testDir.path)
        let speakers = [
            SpeakerResult(index: 1, name: "Kitchen", selected: true, volume: 60),
        ]
        try cache.writeSpeakers(speakers)
        let speaker = try cache.lookupSpeaker(index: 1)
        XCTAssertEqual(speaker.name, "Kitchen")
    }

    func testMissingCacheFileThrows() {
        let cache = ResultCache(directory: testDir.path)
        XCTAssertThrowsError(try cache.readSongs()) { error in
            XCTAssertTrue(error is CacheError)
        }
    }
}
