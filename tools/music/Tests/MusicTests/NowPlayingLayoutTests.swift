// tools/music/Tests/MusicTests/NowPlayingLayoutTests.swift
import XCTest
@testable import music

/// nowPlayingLeftWidth: the Now tab's two-pane left column width. Floors at
/// 44 (the pre-existing width at the twoPane threshold, frameWidth 92) and
/// scales up to 54 (the hero tabs' width) by frameWidth 180, so wide
/// terminals get Now's art sized identically to Library/Playlists/Radio.
final class NowPlayingLayoutTests: XCTestCase {

    func testFloorsAtFortyFourAtTwoPaneThreshold() {
        XCTAssertEqual(nowPlayingLeftWidth(frameWidth: 92), 44)
    }

    func testFloorsAtFortyFourBelowTwoPaneThreshold() {
        // Callers don't actually invoke this below 92 (one-pane uses
        // `frame.width - 6` instead), but the function itself should still
        // clamp rather than go negative or below the floor.
        XCTAssertEqual(nowPlayingLeftWidth(frameWidth: 50), 44)
    }

    func testCapsAtFiftyFourOnTheUsersTerminalWidth() {
        // The user's actual terminal: 214 columns. This must match the hero
        // tabs' art width (54) exactly per the task spec.
        XCTAssertEqual(nowPlayingLeftWidth(frameWidth: 214), 54)
    }

    func testCapsAtFiftyFourAtAndAboveMaxWidth() {
        XCTAssertEqual(nowPlayingLeftWidth(frameWidth: 180), 54)
        XCTAssertEqual(nowPlayingLeftWidth(frameWidth: 400), 54)
    }

    func testScalesMonotonicallyBetweenFloorAndCap() {
        var previous = nowPlayingLeftWidth(frameWidth: 92)
        for w in stride(from: 92, through: 180, by: 4) {
            let current = nowPlayingLeftWidth(frameWidth: w)
            XCTAssertGreaterThanOrEqual(current, previous, "width \(w) regressed vs a narrower width")
            XCTAssertGreaterThanOrEqual(current, 44)
            XCTAssertLessThanOrEqual(current, 54)
            previous = current
        }
    }

    // At the twoPane boundary (92), a fixed 54-wide left column would leave
    // the Up Next list only ~34 columns (92 - 3 - 54 - 2 - 1). Confirm the
    // adaptive width doesn't regress that: at 92 it must still be 44, exactly
    // what it was before this fix, so the list keeps the room it always had.
    func testNarrowTwoPaneDoesNotSqueezeTheList() {
        let leftW = nowPlayingLeftWidth(frameWidth: 92)
        let listX = 3 + leftW + 2
        let listW = 92 - listX - 1
        XCTAssertEqual(leftW, 44)
        XCTAssertGreaterThanOrEqual(listW, 40, "Up Next list squeezed too narrow at the twoPane boundary")
    }

    // MARK: - stackedListStartY

    // Stacked mode (frame.width < 92) used to start the Up Next list at the
    // same row as the control grid, so the two overprinted each other —
    // "Up Nextle   On  [Off]" at 80x36. stackedListStartY computes where the
    // list should start instead: one blank row below wherever the grid
    // actually stopped drawing.

    func testNormalCaseStartsOneBlankRowBelowTheGridsLastRow() {
        // Plenty of room: the grid draws its full ControlGrid.rowCount (4)
        // rows uninterrupted, so its last row is gridStartY + rowCount - 1.
        let gridStartY = 10
        let gridBottom = 100
        let lastGridRow = gridStartY + ControlGrid.rowCount - 1
        let listY = NowPlayingScene.stackedListStartY(gridStartY: gridStartY, gridBottom: gridBottom)
        // One blank spacer row, then the list header.
        XCTAssertEqual(listY, lastGridRow + 2)
        XCTAssertEqual(listY, 15)
    }

    func testCrampedCaseClampedByGridBottomPushesListPastTheBottom() {
        // The grid's own `guard y <= bottom else { break }` clamps it to 2
        // rows here (10, 11) instead of its full 4 — its last drawn row is
        // gridBottom, not gridStartY + rowCount - 1.
        let gridStartY = 10
        let gridBottom = 11
        let listY = NowPlayingScene.stackedListStartY(gridStartY: gridStartY, gridBottom: gridBottom)
        // Past the bottom: the caller's `listY + 1 <= listBottom` guard (where
        // listBottom == gridBottom) then skips the list entirely — grid wins.
        XCTAssertGreaterThan(listY, gridBottom)
        XCTAssertFalse(listY + 1 <= gridBottom, "cramped listY should fail the caller's render guard")
    }

    func testGridExactlyFillsToBottomLeavesNoRoomForTheList() {
        // Boundary: the grid's full row count fits exactly up to gridBottom
        // (no clamping needed), but that leaves zero rows for a spacer + list.
        let gridStartY = 10
        let gridBottom = gridStartY + ControlGrid.rowCount - 1  // 13
        let listY = NowPlayingScene.stackedListStartY(gridStartY: gridStartY, gridBottom: gridBottom)
        XCTAssertGreaterThan(listY, gridBottom)
        XCTAssertFalse(listY + 1 <= gridBottom, "exact-fit listY should still fail the caller's render guard")
    }
}
