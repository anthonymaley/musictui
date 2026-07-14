import XCTest
@testable import music

final class ArtworkStoreTests: XCTestCase {

    // MARK: resolveURL — both live-probed URL shapes

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
        XCTAssertNil(store.lines(key: "a.1", url: "u", width: 8, height: 4) { ready.fulfill() })
        wait(for: [ready], timeout: 2)
        XCTAssertEqual(store.lines(key: "a.1", url: "u", width: 8, height: 4) { }, ["ART"])
        XCTAssertEqual(fetches, 1)
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
        let settle = expectation(description: "settle"); DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertNil(store.lines(key: "a.3", url: "u", width: 8, height: 4) { XCTFail("onReady must not fire") })
        let settle2 = expectation(description: "settle2"); DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle2.fulfill() }
        wait(for: [settle2], timeout: 2)
        XCTAssertEqual(fetches, 1)
    }
}
