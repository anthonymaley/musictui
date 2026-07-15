import XCTest
@testable import music

final class PlaylistBrowserModelTests: XCTestCase {
    // badge derivation
    func testRecentBadgeFromKnownName() {
        XCTAssertEqual(playlistBadge(name: "Recently Played", isSmart: true, specialKind: "Music"), .recent)
        XCTAssertEqual(playlistBadge(name: "Top 25 Most Played", isSmart: true, specialKind: "Music"), .recent)
    }
    func testSmartBadge() {
        XCTAssertEqual(playlistBadge(name: "Deep House Finds", isSmart: true, specialKind: "none"), .smart)
    }
    func testNoneBadgeForPlainUserPlaylist() {
        XCTAssertEqual(playlistBadge(name: "Bluecoats 2024", isSmart: false, specialKind: "none"), .none)
    }
    func testAppleBadgeForSubscriptionPlaylist() {
        XCTAssertEqual(playlistBadge(name: "Loops", isSmart: false, specialKind: "none", isSubscription: true), .apple)
    }
    func testAppleWinsOverSmart() {
        // `smart` errors on subscription playlists and defaults false, but if a
        // future read ever reports true, the Apple identity is the useful badge.
        XCTAssertEqual(playlistBadge(name: "Replay 2022", isSmart: true, specialKind: "none", isSubscription: true), .apple)
    }
    func testRecentWinsOverApple() {
        XCTAssertEqual(playlistBadge(name: "Recently Played", isSmart: false, specialKind: "none", isSubscription: true), .recent)
    }

    // subscription-aware rail fetch parsing
    func testParseRailNamesSplitsUserAndSubscription() {
        let raw = "U\u{1F}Working Vibes\nS\u{1F}Loops\nU\u{1F}__queue__ leftover\nS\u{1F}Replay 2022\n"
        let parsed = parseRailPlaylistNames(raw)
        XCTAssertEqual(parsed.names, ["Working Vibes", "Loops", "Replay 2022"])
        XCTAssertEqual(parsed.subscription, ["Loops", "Replay 2022"])
    }
    func testParseRailNamesTolerantOfMalformedLines() {
        let raw = "garbage-no-sep\nU\u{1F}Real One\n\n"
        let parsed = parseRailPlaylistNames(raw)
        XCTAssertEqual(parsed.names, ["Real One"])
        XCTAssertTrue(parsed.subscription.isEmpty)
    }

    // duration formatting
    func testFormatDurationHoursAndMinutes() {
        XCTAssertEqual(formatPlaylistDuration(15132), "4h 12m")
    }
    func testFormatDurationMinutesOnly() {
        XCTAssertEqual(formatPlaylistDuration(360), "6m")
    }
    func testFormatDurationZero() {
        XCTAssertEqual(formatPlaylistDuration(0), "0m")
    }
    func testFormatDurationRoundsDownToMinute() {
        XCTAssertEqual(formatPlaylistDuration(59), "0m")
    }

    // zone layout
    func testThreeZonesWhenWide() {
        let z = playlistZones(width: 188)
        XCTAssertEqual(z.mode, .three)
        XCTAssertGreaterThanOrEqual(z.railWidth, 30)
        XCTAssertNotNil(z.rightX)
        XCTAssertGreaterThan(z.heroX, z.railX + z.railWidth)
        XCTAssertGreaterThan(z.rightX!, z.heroX + z.heroWidth)
    }
    func testTwoZonesMidWidth() {
        let z = playlistZones(width: 120)
        XCTAssertEqual(z.mode, .two)
        XCTAssertNil(z.rightX)
    }
    func testOneZoneNarrow() {
        let z = playlistZones(width: 80)
        XCTAssertEqual(z.mode, .one)
        XCTAssertNil(z.rightX)
    }

    // gradient determinism
    func testGradientDeterministicAndSized() {
        let a = gradientBlock(name: "House Classics", width: 12, height: 5)
        let b = gradientBlock(name: "House Classics", width: 12, height: 5)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 5)
    }
    func testGradientDiffersByName() {
        let a = gradientBlock(name: "House Classics", width: 12, height: 5)
        let c = gradientBlock(name: "Jazz Nights", width: 12, height: 5)
        XCTAssertNotEqual(a, c)
    }

    // Old buggy formula was `idx = abs(seed + r*31 + c*7) % 4`. Since
    // 31 % 4 == 3 and 7 % 4 == 3, idx(r, c) == idx(r + 4, c) == idx(r, c + 4)
    // for every r, c — a strict 4x4 repeating tile (a basket-weave lattice),
    // not a gradient. A real ramp must show variation across a 4-row or
    // 4-column shift somewhere in the block; the old lattice never did,
    // for any name. Verified this assertion fails against the pre-fix
    // implementation (reverted locally, ran the test, saw it fail) before
    // restoring the fix.
    func testGradientIsNotAPeriodicLattice() {
        let width = 16, height = 16
        for name in ["House Classics", "Jazz Nights", "Deep House Finds", "Bluecoats 2024", "Replay 2022", "Loops"] {
            let block = gradientBlock(name: name, width: width, height: height)
            let grid = block.map { Array($0) }

            var rowShiftDiffers = false
            for r in 0..<(height - 4) where grid[r] != grid[r + 4] {
                rowShiftDiffers = true
                break
            }
            var colShiftDiffers = false
            outer: for r in 0..<height {
                for c in 0..<(width - 4) where grid[r][c] != grid[r][c + 4] {
                    colShiftDiffers = true
                    break outer
                }
            }
            XCTAssertTrue(rowShiftDiffers || colShiftDiffers,
                           "\(name): gradient must vary across a 4-row or 4-col shift, not tile like the old lattice bug")
        }
    }

    func testGradientRowWidthMatchesRequestedWidth() {
        for (w, h) in [(1, 1), (3, 7), (12, 5), (54, 22)] {
            let block = gradientBlock(name: "Deep House Finds", width: w, height: h)
            XCTAssertEqual(block.count, h)
            for row in block {
                XCTAssertEqual(row.count, w, "row width mismatch for size \(w)x\(h)")
            }
        }
    }

    func testGradientDegenerateSizesDoNotCrash() {
        XCTAssertEqual(gradientBlock(name: "Loops", width: 0, height: 10), [])
        XCTAssertEqual(gradientBlock(name: "Loops", width: 10, height: 0), [])
        XCTAssertEqual(gradientBlock(name: "Loops", width: 0, height: 0), [])
        let single = gradientBlock(name: "Loops", width: 1, height: 1)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].count, 1)
    }

    func testGradientDeterministicAcrossSizes() {
        for (w, h) in [(1, 1), (12, 5), (54, 22)] {
            let a = gradientBlock(name: "Bluecoats 2024", width: w, height: h)
            let b = gradientBlock(name: "Bluecoats 2024", width: w, height: h)
            XCTAssertEqual(a, b, "size \(w)x\(h) must be deterministic")
        }
    }

    // rail name truncation
    func testRailNameTruncatesWithEllipsis() {
        let r = railName("A Very Long Playlist Name That Overflows", nameWidth: 10)
        XCTAssertEqual(r.count, 10)
        XCTAssertTrue(r.hasSuffix("\u{2026}"))
    }
    func testRailNameShortUnchanged() {
        XCTAssertEqual(railName("Short", nameWidth: 10), "Short")
    }
}
