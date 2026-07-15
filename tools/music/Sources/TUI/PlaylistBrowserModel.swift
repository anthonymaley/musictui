import Foundation

// MARK: - Metadata

/// Per-playlist metadata. Optional fields are `nil` until enrichment loads
/// them; the UI renders a reserved placeholder so values land without shifting
/// layout.
struct PlaylistMeta {
    let name: String
    var trackCount: Int?
    var durationSec: Int?
    var isSmart: Bool?
    var specialKind: String?
    var loaded: Bool = false
}

enum PlaylistBadge: Equatable {
    case smart, recent, apple, none
}

private let recentPlaylistNames: Set<String> = ["Recently Played", "Top 25 Most Played"]

/// Pure badge derivation. recent > apple > smart > none.
/// `isSubscription` marks Apple-curated playlists added to the library
/// (AppleScript class `subscription playlist`) — they update on Apple's
/// schedule and are read-only.
func playlistBadge(name: String, isSmart: Bool, specialKind: String, isSubscription: Bool = false) -> PlaylistBadge {
    if recentPlaylistNames.contains(name) { return .recent }
    if isSubscription { return .apple }
    if isSmart { return .smart }
    return .none
}

/// Format a duration in seconds as "Hh Mm" (or "Mm" under an hour).
func formatPlaylistDuration(_ seconds: Int) -> String {
    let totalMin = max(0, seconds) / 60
    let h = totalMin / 60
    let m = totalMin % 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

// MARK: - Zone geometry

enum PlaylistZoneMode { case one, two, three }

struct PlaylistZones {
    let mode: PlaylistZoneMode
    let railX: Int
    let railWidth: Int
    let heroX: Int
    let heroWidth: Int
    let rightX: Int?      // nil unless mode == .three
    let rightWidth: Int
}

/// Compute zone geometry from terminal width. Pure.
/// >=138: three zones; 96..137: rail+hero; <96: rail + compact hero.
func playlistZones(width: Int) -> PlaylistZones {
    let railX = 3
    let gutter = 3
    if width >= 138 {
        let railWidth = 34
        let heroX = railX + railWidth + gutter
        let heroWidth = min(54, (width - heroX - gutter - railX) / 2 + 6)
        let rightX = heroX + heroWidth + gutter
        let rightWidth = min(52, width - rightX - 2)
        return PlaylistZones(mode: .three, railX: railX, railWidth: railWidth,
                             heroX: heroX, heroWidth: heroWidth,
                             rightX: rightX, rightWidth: max(0, rightWidth))
    } else if width >= 96 {
        let railWidth = 34
        let heroX = railX + railWidth + gutter
        let heroWidth = max(0, width - heroX - 2)
        return PlaylistZones(mode: .two, railX: railX, railWidth: railWidth,
                             heroX: heroX, heroWidth: heroWidth,
                             rightX: nil, rightWidth: 0)
    } else {
        let railWidth = min(30, max(18, width / 2))
        let heroX = railX + railWidth + gutter
        let heroWidth = max(0, width - heroX - 2)
        return PlaylistZones(mode: .one, railX: railX, railWidth: railWidth,
                             heroX: heroX, heroWidth: heroWidth,
                             rightX: nil, rightWidth: 0)
    }
}

// MARK: - Gradient block (deterministic identity, not real artwork)

private let gradientGlyphs = "\u{2588}\u{2593}\u{2592}\u{2591}"  // full/dark/medium/light shade — dark→light ramp

/// Build a deterministic block of `height` strings, each `width` glyphs,
/// seeded by the playlist name. No color codes here — caller wraps with color.
///
/// This is a smooth directional ramp, not noise: the seed picks one of four
/// ramp angles (horizontal, vertical, and the two diagonals) and whether it
/// runs forward or reversed, so different names read as visibly different
/// gradients while the shading itself stays a monotonic dark→light sweep
/// across the block (never a repeating tile).
func gradientBlock(name: String, width: Int, height: Int) -> [String] {
    guard width > 0, height > 0 else { return [] }
    var seed = 5381
    for b in name.unicodeScalars { seed = ((seed << 5) &+ seed) &+ Int(b.value) }
    let glyphs = Array(gradientGlyphs)
    let glyphCount = glyphs.count

    let direction = seed & 0x3           // 0=horizontal 1=vertical 2=diagonal ↘ 3=diagonal ↙
    let reversed = (seed >> 2) & 0x1 == 1

    // Normalize row/col to 0...1 across the block; guard the 1-row/1-col
    // degenerate case so we never divide by zero.
    let maxRow = Double(max(height - 1, 1))
    let maxCol = Double(max(width - 1, 1))

    var rows: [String] = []
    rows.reserveCapacity(height)
    for r in 0..<height {
        let rNorm = Double(r) / maxRow
        var line = ""
        line.reserveCapacity(width)
        for c in 0..<width {
            let cNorm = Double(c) / maxCol
            var t: Double
            switch direction {
            case 0: t = cNorm
            case 1: t = rNorm
            case 2: t = (rNorm + cNorm) / 2
            default: t = (rNorm + (1 - cNorm)) / 2
            }
            if reversed { t = 1 - t }
            let idx = min(glyphCount - 1, Int(t * Double(glyphCount)))
            line.append(glyphs[idx])
        }
        rows.append(line)
    }
    return rows
}

// MARK: - Rail name truncation

/// Truncate a playlist name to exactly fit `nameWidth` columns, ellipsis if cut.
func railName(_ name: String, nameWidth: Int) -> String {
    guard nameWidth > 0 else { return "" }
    if name.count <= nameWidth { return name }
    if nameWidth == 1 { return "\u{2026}" }
    return String(name.prefix(nameWidth - 1)) + "\u{2026}"
}
