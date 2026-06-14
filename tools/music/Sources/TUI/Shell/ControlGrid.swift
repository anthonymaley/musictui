// Pure model for the Now Playing playback-control grid: fixed rows of option
// cells, which cell is the active value given current modes, and cursor
// clamping. Rendering, focus, and the AppleScript writes live in the scene.
import Foundation

enum ControlRow: Int, CaseIterable {
    case shuffle, order, repeatMode, genius
}

enum ControlGrid {
    static let labels = ["Shuffle", "Order", "Repeat", "Genius"]
    static let cells: [[String]] = [
        ["On", "Off"],
        ["Songs", "Albums", "Grp"],
        ["Off", "All", "One"],
        ["Shuffle now"],
    ]
    // Value mappings, aligned to the cell columns above.
    static let orderModes: [ShuffleMode] = [.songs, .albums, .groupings]
    static let repeatModes: [RepeatMode] = [.off, .all, .one]

    static var rowCount: Int { cells.count }
    static func cellCount(row: Int) -> Int { cells[row].count }

    /// The active column for a row, derived from current modes (nil = no active
    /// value, e.g. the Genius action row).
    static func activeColumn(row: Int, modes: PlaybackModes) -> Int? {
        switch ControlRow(rawValue: row) {
        case .shuffle:    return modes.shuffleEnabled ? 0 : 1
        case .order:      return orderModes.firstIndex(of: modes.shuffleMode)
        case .repeatMode: return repeatModes.firstIndex(of: modes.songRepeat)
        case .genius, .none: return nil
        }
    }

    /// Clamp a (row, col) to valid bounds — col clamps to the new row's width,
    /// so moving up/down onto a narrower row keeps the cursor in range.
    static func clamp(row: Int, col: Int) -> (row: Int, col: Int) {
        let r = min(max(0, row), rowCount - 1)
        let c = min(max(0, col), cellCount(row: r) - 1)
        return (r, c)
    }
}
