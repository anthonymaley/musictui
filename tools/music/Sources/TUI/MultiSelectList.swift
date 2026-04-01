import Foundation

struct MultiSelectItem {
    let label: String
    let sublabel: String
    var selected: Bool
}

enum MultiSelectAction {
    case confirmed([Int])
    case played(Int)
    case addedToLibrary([Int])
    case createPlaylist([Int])
    case cancelled
}

func runMultiSelectList(
    title: String,
    items: inout [MultiSelectItem],
    actions: [(key: Character, label: String, action: (Int, [Int]) -> MultiSelectAction)] = []
) -> MultiSelectAction {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }

    var cursor = 0
    let pageSize = 20

    func selectedIndices() -> [Int] {
        items.enumerated().compactMap { $0.element.selected ? $0.offset : nil }
    }

    func render() {
        var out = ANSICode.cursorHome + ANSICode.clearScreen
        out += "\(ANSICode.bold)\(title)\(ANSICode.reset)\n\n"

        let start = max(0, cursor - pageSize / 2)
        let end = min(items.count, start + pageSize)

        for i in start..<end {
            let item = items[i]
            let marker = item.selected ? "\(ANSICode.green)✓\(ANSICode.reset)" : " "
            let highlight = i == cursor ? ANSICode.inverse : ""
            let resetH = i == cursor ? ANSICode.reset : ""
            let sub = item.sublabel.isEmpty ? "" : " \(ANSICode.dim)— \(item.sublabel)\(ANSICode.reset)"
            out += " \(marker) \(highlight)\(i + 1). \(item.label)\(resetH)\(sub)\n"
        }

        let selected = selectedIndices()
        out += "\n\(ANSICode.dim)↑↓ navigate  ␣ select  "
        for a in actions {
            out += "\(a.key) \(a.label)  "
        }
        out += "q quit"
        if !selected.isEmpty {
            out += "  (\(selected.count) selected)"
        }
        out += "\(ANSICode.reset)"

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
        default:
            break
        }
        render()
    }
}
