import Foundation
import Darwin

struct MultiSelectItem {
    let label: String
    var sublabel: String
    var selected: Bool
}

enum MultiSelectAction {
    case confirmed([Int])
    case played(Int)
    case shuffled([Int])
    case addedToLibrary([Int])
    case createPlaylist([Int])
    case cancelled
}

func runMultiSelectList(
    title: String,
    items: inout [MultiSelectItem],
    actions: [(key: Character, label: String, action: (Int, [Int]) -> MultiSelectAction)] = [],
    onToggle: ((Int, Bool) -> Void)? = nil,
    onAdjust: ((Int, Int) -> String)? = nil  // (index, delta) -> new sublabel
) -> MultiSelectAction {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }

    var cursor = 0
    var scrollOffset = 0

    // Shared shell coordinates
    let appX = 3
    let appY = 2
    let titleY = 4
    let ruleY = 5
    let bodyY = 7

    let nameW = 28
    let barW = 18

    let hasSpeakerMode = onAdjust != nil

    func termSize() -> (height: Int, width: Int) {
        var ws = winsize()
        _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws)
        let w = Int(ws.ws_col) > 0 ? Int(ws.ws_col) : 120
        let h = Int(ws.ws_row) > 0 ? Int(ws.ws_row) : 30
        return (h, w)
    }

    func selectedIndices() -> [Int] {
        items.enumerated().compactMap { $0.element.selected ? $0.offset : nil }
    }

    func parseVolume(_ sublabel: String) -> Int {
        if let range = sublabel.range(of: "vol: "),
           let vol = Int(sublabel[range.upperBound...].trimmingCharacters(in: .whitespaces)) {
            return vol
        }
        return 0
    }

    func buildBar(volume: Int) -> String {
        let filled = Int(Double(volume) / 100.0 * Double(barW))
        let empty = barW - filled
        return "\(ANSICode.green)\(String(repeating: "█", count: filled))\(ANSICode.reset)\(ANSICode.dim)\(String(repeating: "░", count: empty))\(ANSICode.reset)"
    }

    func render() {
        let (termHeight, _) = termSize()
        let footerY = termHeight - 1
        let statusY = footerY - 1
        let maxVisible = max(1, termHeight - bodyY - 4)

        // Adjust scroll offset to keep cursor visible
        if cursor < scrollOffset {
            scrollOffset = cursor
        } else if cursor >= scrollOffset + maxVisible {
            scrollOffset = cursor - maxVisible + 1
        }

        let visibleEnd = min(items.count, scrollOffset + maxVisible)

        var out = ANSICode.cursorHome + ANSICode.clearScreen

        // App label
        out += ANSICode.moveTo(row: appY, col: appX)
        out += "\(ANSICode.dim)music\(ANSICode.reset)"

        // Title
        out += ANSICode.moveTo(row: titleY, col: appX)
        out += "\(ANSICode.bold)\(ANSICode.cyan)♫ \(title)\(ANSICode.reset)"

        // Accent rule
        out += ANSICode.moveTo(row: ruleY, col: appX)
        out += "\(ANSICode.dim)\(String(repeating: "─", count: min(40, title.count + 4)))\(ANSICode.reset)"

        // Item rows
        for i in scrollOffset..<visibleEnd {
            let item = items[i]
            let row = bodyY + (i - scrollOffset)
            out += ANSICode.moveTo(row: row, col: appX)

            let pointer = i == cursor ? "\(ANSICode.cyan)▶\(ANSICode.reset)" : " "
            let marker = item.selected ? "\(ANSICode.green)●\(ANSICode.reset)" : "\(ANSICode.dim)○\(ANSICode.reset)"

            if hasSpeakerMode {
                let vol = parseVolume(item.sublabel)
                let padded = item.label.padding(toLength: nameW, withPad: " ", startingAt: 0)
                let bar = buildBar(volume: vol)
                let pct = String(format: "%3d%%", vol)
                out += "\(pointer) \(marker) \(padded)  \(bar) \(pct)"
            } else {
                let num = String(format: "%02d", i + 1)
                out += "\(pointer) \(marker) \(num). \(item.label)"
            }
        }

        // Status row
        let sel = selectedIndices()
        if !sel.isEmpty {
            out += ANSICode.moveTo(row: statusY, col: appX)
            out += "\(ANSICode.green)\(sel.count) selected\(ANSICode.reset)"
        }

        // Footer
        out += ANSICode.moveTo(row: footerY, col: appX)
        if hasSpeakerMode {
            out += "\(ANSICode.dim)↑↓ Navigate   Space Toggle   ←→ Volume   Enter Confirm   q Quit\(ANSICode.reset)"
        } else {
            var line = "↑↓ Navigate   Space Select   Enter Confirm"
            for a in actions {
                line += "   \(a.key) \(a.label)"
            }
            line += "   q Quit"
            out += "\(ANSICode.dim)\(line)\(ANSICode.reset)"
        }

        print(out, terminator: "")
        fflush(stdout)
    }

    render()

    while true {
        guard let key = KeyPress.read() else { continue }
        switch key {
        case .up:
            cursor = max(0, cursor - 1)
        case .down:
            cursor = min(items.count - 1, cursor + 1)
        case .space:
            items[cursor].selected.toggle()
            onToggle?(cursor, items[cursor].selected)
        case .left:
            if let onAdjust = onAdjust {
                items[cursor].sublabel = onAdjust(cursor, -5)
            }
        case .right:
            if let onAdjust = onAdjust {
                items[cursor].sublabel = onAdjust(cursor, 5)
            }
        case .char("q"), .escape:
            return .cancelled
        case .enter:
            let sel = selectedIndices()
            return .confirmed(sel.isEmpty ? [cursor] : sel)
        case .char(let c):
            for a in actions {
                if c == a.key {
                    return a.action(cursor, selectedIndices())
                }
            }
        }
        render()
    }
}
