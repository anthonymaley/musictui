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

private let gradientGlyph = "\u{2588}"   // solid block — colour carries the shading now, not glyph density
private let gradientSteps = 16           // quantisation: bounds the escape count (see below), still reads smooth

/// Build a deterministic block of `height` rows, each exactly `width` VISIBLE
/// columns — the caller renders each row as-is (`ANSICode.moveTo(...) + row`),
/// no further color wrapping needed; every row already carries its own 24-bit
/// colour escapes and ends with `ANSICode.reset`. Escape sequences do not
/// count toward the `width` columns (see `PlaylistBrowserModelTests`'
/// `visibleWidth` helper, which strips them before measuring).
///
/// This is a smooth directional ramp, not noise: the seed picks one of four
/// ramp angles (horizontal, vertical, and the two diagonals) and whether it
/// runs forward or reversed, so different names read as visibly different
/// gradients. The ramp itself is drawn in HSL: a base hue from the seed and a
/// second hue 40°...103° around the wheel (never the ~180° complementary
/// angle, which would force the straight-RGB path through a muddy grey
/// midpoint), fixed saturation, rising lightness — so every step along the
/// ramp stays vivid, never desaturates.
///
/// Colour is quantised to `gradientSteps` levels, and a colour escape is only
/// emitted when the quantised colour actually CHANGES from the previous cell
/// IN THAT ROW — never unconditionally per cell (that would be ~1200 escapes
/// at a 54x22 hero). A vertical-leaning ramp (colour constant across a row)
/// costs one escape per row; a horizontal/diagonal one costs up to
/// `gradientSteps` per row, since the colour sweeps that row's full width.
func gradientBlock(name: String, width: Int, height: Int) -> [String] {
    guard width > 0, height > 0 else { return [] }
    var seed = 5381
    for b in name.unicodeScalars { seed = ((seed << 5) &+ seed) &+ Int(b.value) }

    let direction = seed & 0x3           // 0=horizontal 1=vertical 2=diagonal ↘ 3=diagonal ↙
    let reversed = (seed >> 2) & 0x1 == 1

    let hue1 = Double((seed >> 3) & 0x1ff) / 511.0 * 360.0
    let hueShift = 40.0 + Double((seed >> 12) & 0x3f)   // 40...103 degrees
    let sat = 0.55
    let light1 = 0.40, light2 = 0.64

    // Normalize row/col to 0...1 across the block; guard the 1-row/1-col
    // degenerate case so we never divide by zero.
    let maxRow = Double(max(height - 1, 1))
    let maxCol = Double(max(width - 1, 1))

    var rows: [String] = []
    rows.reserveCapacity(height)
    for r in 0..<height {
        let rNorm = Double(r) / maxRow
        var line = ""
        line.reserveCapacity(width * 4)
        var lastStep = -1   // per-row: forces the first cell to always emit its colour
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
            let step = min(gradientSteps - 1, Int(t * Double(gradientSteps)))
            if step != lastStep {
                let st = Double(step) / Double(gradientSteps - 1)
                let hue = (hue1 + hueShift * st).truncatingRemainder(dividingBy: 360)
                let light = light1 + (light2 - light1) * st
                let (r8, g8, b8) = hslToRGB255(h: hue, s: sat, l: light)
                line += "\u{1B}[38;2;\(r8);\(g8);\(b8)m"
                lastStep = step
            }
            line += gradientGlyph
        }
        line += ANSICode.reset
        rows.append(line)
    }
    return rows
}

/// HSL -> 8-bit RGB. `h` in degrees (any range; normalized mod 360 here so
/// callers don't have to), `s`/`l` in 0...1. Pure.
private func hslToRGB255(h: Double, s: Double, l: Double) -> (Int, Int, Int) {
    let hNorm = h.truncatingRemainder(dividingBy: 360)
    let hh = hNorm < 0 ? hNorm + 360 : hNorm
    let c = (1 - abs(2 * l - 1)) * s
    let hp = hh / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    let (r1, g1, b1): (Double, Double, Double)
    switch hp {
    case 0..<1: (r1, g1, b1) = (c, x, 0)
    case 1..<2: (r1, g1, b1) = (x, c, 0)
    case 2..<3: (r1, g1, b1) = (0, c, x)
    case 3..<4: (r1, g1, b1) = (0, x, c)
    case 4..<5: (r1, g1, b1) = (x, 0, c)
    default:    (r1, g1, b1) = (c, 0, x)
    }
    let m = l - c / 2
    let r = Int(((r1 + m) * 255).rounded())
    let g = Int(((g1 + m) * 255).rounded())
    let b = Int(((b1 + m) * 255).rounded())
    return (max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
}

// MARK: - Rail name truncation

/// Truncate a playlist name to exactly fit `nameWidth` columns, ellipsis if cut.
func railName(_ name: String, nameWidth: Int) -> String {
    guard nameWidth > 0 else { return "" }
    if name.count <= nameWidth { return name }
    if nameWidth == 1 { return "\u{2026}" }
    return String(name.prefix(nameWidth - 1)) + "\u{2026}"
}
