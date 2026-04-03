import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct PlaylistPreview {
    let name: String
    let trackCount: Int
    let tracks: [String]  // formatted as "Title — Artist"
}

func renderArtwork(path: String, width: Int, height: Int) -> [String] {
    guard let chafaPath = findExecutable("chafa") else { return [] }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: chafaPath)
    proc.arguments = [
        "--format", "symbols",
        "--size", "\(width)x\(height)",
        "--symbols", "block+border+space",
        "--color-space", "rgb",
        "--work", "9",
        path
    ]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8), !output.isEmpty {
            return output.components(separatedBy: "\n").filter { !$0.isEmpty }
        }
    } catch {}
    return []
}

func runListPicker(
    title: String,
    items: [String],
    onPreview: ((Int) -> PlaylistPreview?)? = nil,
    onArtwork: ((Int) -> String?)? = nil
) -> Int? {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }

    var cursor = 0
    var scrollOffset = 0

    // Terminal size
    func termSize() -> (rows: Int, cols: Int) {
        var ws = winsize()
        _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws)
        return (Int(ws.ws_row), Int(ws.ws_col))
    }

    // Shared coordinates
    let appX = 3
    let appY = 2
    let titleX = 3
    let titleY = 4
    let ruleX = 3
    let ruleY = 5
    let bodyY = 7

    func render() {
        let (termHeight, termWidth) = termSize()
        let footerY = termHeight - 1
        let statusY = footerY - 1
        let maxVisible = max(1, termHeight - bodyY - 4)

        let useTwoPane = onPreview != nil && termWidth >= 95

        // Scrolling
        if cursor < scrollOffset {
            scrollOffset = cursor
        } else if cursor >= scrollOffset + maxVisible {
            scrollOffset = cursor - maxVisible + 1
        }

        var out = ANSICode.cursorHome + ANSICode.clearScreen

        // App label
        out += ANSICode.moveTo(row: appY, col: appX)
        out += "\(ANSICode.dim)music\(ANSICode.reset)"

        // Title
        out += ANSICode.moveTo(row: titleY, col: titleX)
        out += "\(ANSICode.bold)\(ANSICode.cyan)♫ \(title)\(ANSICode.reset)"

        // Accent rule
        out += ANSICode.moveTo(row: ruleY, col: ruleX)
        out += "\(ANSICode.dim)\(String(repeating: "─", count: min(40, title.count + 4)))\(ANSICode.reset)"

        if useTwoPane {
            // --- Two-pane layout ---
            let leftX = 3
            let leftW = 38
            let rightX = leftX + leftW + 4
            let rightW = termWidth - rightX - 3

            // Left pane: playlist list
            let end = min(items.count, scrollOffset + maxVisible)
            for i in scrollOffset..<end {
                let row = bodyY + (i - scrollOffset)
                out += ANSICode.moveTo(row: row, col: leftX)

                let pointer: String
                let label: String
                let maxLen = leftW - 4
                let truncated: String
                if items[i].count > maxLen {
                    truncated = String(items[i].prefix(maxLen - 1)) + "…"
                } else {
                    truncated = items[i]
                }

                if i == cursor {
                    pointer = "\(ANSICode.cyan)▶\(ANSICode.reset)"
                    label = "\(ANSICode.bold)\(truncated)\(ANSICode.reset)"
                } else {
                    pointer = " "
                    label = truncated
                }
                out += "\(pointer) \(label)"
            }

            // Right pane
            if rightW > 10 {
                var rightRow = bodyY

                // Preview header + rule
                out += ANSICode.moveTo(row: rightRow, col: rightX)
                out += "\(ANSICode.bold)Preview\(ANSICode.reset)"
                rightRow += 1
                out += ANSICode.moveTo(row: rightRow, col: rightX)
                out += "\(ANSICode.dim)\(String(repeating: "─", count: min(7, rightW)))\(ANSICode.reset)"
                rightRow += 1

                if let onPreview = onPreview, let preview = onPreview(cursor) {
                    // Playlist name (bold)
                    out += ANSICode.moveTo(row: rightRow, col: rightX)
                    let nameStr = preview.name.count > rightW
                        ? String(preview.name.prefix(rightW - 1)) + "…"
                        : preview.name
                    out += "\(ANSICode.bold)\(nameStr)\(ANSICode.reset)"
                    rightRow += 1

                    // Track count (dim)
                    out += ANSICode.moveTo(row: rightRow, col: rightX)
                    out += "\(ANSICode.dim)\(preview.trackCount) tracks\(ANSICode.reset)"
                    rightRow += 1

                    // Blank line
                    rightRow += 1

                    // Artwork
                    if let onArtwork = onArtwork, let artPath = onArtwork(cursor) {
                        let artW = min(16, rightW / 2)
                        let artH = artW  // square using half-blocks
                        let artLines = renderArtwork(path: artPath, width: artW, height: artH)
                        for line in artLines {
                            if rightRow >= statusY - 1 { break }
                            out += ANSICode.moveTo(row: rightRow, col: rightX)
                            out += line
                            rightRow += 1
                        }
                        // Blank line after art
                        rightRow += 1
                    }

                    // Track list
                    let maxTrackRows = max(0, statusY - 1 - rightRow)
                    for (idx, track) in preview.tracks.prefix(maxTrackRows).enumerated() {
                        out += ANSICode.moveTo(row: rightRow, col: rightX)
                        let num = "\(ANSICode.dim)\(idx + 1).\(ANSICode.reset) "
                        let trackStr = track.count > (rightW - 5)
                            ? String(track.prefix(rightW - 6)) + "…"
                            : track
                        out += num + trackStr
                        rightRow += 1
                    }
                }
            }
        } else {
            // --- Single-pane layout ---
            let end = min(items.count, scrollOffset + maxVisible)
            for i in scrollOffset..<end {
                let row = bodyY + (i - scrollOffset)
                out += ANSICode.moveTo(row: row, col: appX)

                if i == cursor {
                    out += "\(ANSICode.cyan)▶\(ANSICode.reset) \(ANSICode.bold)\(items[i])\(ANSICode.reset)"
                } else {
                    out += "  \(items[i])"
                }
            }
        }

        // Status row
        out += ANSICode.moveTo(row: statusY, col: appX)
        out += "\(ANSICode.dim)\(items.count) \(items.count == 1 ? "playlist" : "playlists")\(ANSICode.reset)"

        // Footer
        out += ANSICode.moveTo(row: footerY, col: appX)
        out += "\(ANSICode.dim)↑↓ Navigate   Enter Open   p Play   q Quit\(ANSICode.reset)"

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
        case .enter, .space, .char("p"):
            return cursor
        case .char("q"), .escape:
            return nil
        default:
            break
        }
        render()
    }
}
