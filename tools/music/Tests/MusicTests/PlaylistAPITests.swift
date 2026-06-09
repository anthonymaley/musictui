// tools/music/Tests/MusicTests/PlaylistAPITests.swift
import XCTest
@testable import music

final class PlaylistAPITests: XCTestCase {
    // MARK: - Request body builders (shapes verified against Apple's
    // LibraryPlaylistTracksRequest / LibraryPlaylistCreationRequest docs)

    func testTracksRequestBodyShape() {
        let body = playlistTracksRequestBody(songIDs: ["123", "456"])
        let data = body["data"] as? [[String: Any]]
        XCTAssertEqual(data?.count, 2)
        XCTAssertEqual(data?[0]["id"] as? String, "123")
        XCTAssertEqual(data?[0]["type"] as? String, "songs")
    }

    func testCreationBodyWithoutTracksHasNoRelationships() {
        let body = playlistCreationRequestBody(name: "Mix", songIDs: [])
        XCTAssertEqual((body["attributes"] as? [String: Any])?["name"] as? String, "Mix")
        XCTAssertNil(body["relationships"])
    }

    func testCreationBodyWithTracksNestsTracksRelationship() {
        let body = playlistCreationRequestBody(name: "Mix", songIDs: ["9"])
        let rel = body["relationships"] as? [String: Any]
        let tracks = rel?["tracks"] as? [String: Any]
        let data = tracks?["data"] as? [[String: Any]]
        XCTAssertEqual(data?.first?["id"] as? String, "9")
        XCTAssertEqual(data?.first?["type"] as? String, "songs")
    }

    // MARK: - Shared library lookup script

    func testLookupScriptEscapesAndUsesExactThenContains() {
        let script = libraryTrackLookupScript(title: "Say \"Yes\"", artist: "AC\\DC")
        XCTAssertTrue(script.contains("whose name is \"Say \\\"Yes\\\"\""))
        XCTAssertTrue(script.contains("artist is \"AC\\\\DC\""))
        XCTAssertTrue(script.contains("whose name contains"), "must fall back to a contains match")
        XCTAssertTrue(script.contains("set results to"))
    }
}
