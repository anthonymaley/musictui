import XCTest
@testable import music

final class ControlGridTests: XCTestCase {
    func testCellCounts() {
        XCTAssertEqual(ControlGrid.rowCount, 4)
        XCTAssertEqual(ControlGrid.cellCount(row: 0), 2)  // Shuffle On/Off
        XCTAssertEqual(ControlGrid.cellCount(row: 1), 3)  // Order
        XCTAssertEqual(ControlGrid.cellCount(row: 2), 3)  // Repeat
        XCTAssertEqual(ControlGrid.cellCount(row: 3), 1)  // Genius
    }

    func testActiveColumnFromModes() {
        let m = PlaybackModes(shuffleEnabled: false, shuffleMode: .songs, songRepeat: .off)
        XCTAssertEqual(ControlGrid.activeColumn(row: 0, modes: m), 1)  // Off
        XCTAssertEqual(ControlGrid.activeColumn(row: 1, modes: m), 0)  // Songs
        XCTAssertEqual(ControlGrid.activeColumn(row: 2, modes: m), 0)  // Off
        XCTAssertNil(ControlGrid.activeColumn(row: 3, modes: m))       // Genius

        let m2 = PlaybackModes(shuffleEnabled: true, shuffleMode: .groupings, songRepeat: .one)
        XCTAssertEqual(ControlGrid.activeColumn(row: 0, modes: m2), 0) // On
        XCTAssertEqual(ControlGrid.activeColumn(row: 1, modes: m2), 2) // Groupings
        XCTAssertEqual(ControlGrid.activeColumn(row: 2, modes: m2), 2) // One
    }

    func testClampKeepsCursorInRow() {
        // Moving onto a narrower row clamps the column.
        XCTAssertEqual(ControlGrid.clamp(row: 0, col: 2).col, 1)  // Shuffle has 2 cells
        XCTAssertEqual(ControlGrid.clamp(row: 3, col: 2).col, 0)  // Genius has 1 cell
        XCTAssertEqual(ControlGrid.clamp(row: 1, col: 2).col, 2)  // Order keeps col 2
        // Bounds.
        XCTAssertEqual(ControlGrid.clamp(row: -1, col: -1).row, 0)
        XCTAssertEqual(ControlGrid.clamp(row: 99, col: 0).row, 3)
    }
}
