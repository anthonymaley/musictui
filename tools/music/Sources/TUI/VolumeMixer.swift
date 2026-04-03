import Foundation
import Darwin

struct MixerSpeaker {
    let name: String
    var volume: Int
}

func runVolumeMixer(
    speakers: inout [MixerSpeaker],
    onVolumeChange: (String, Int) -> Void
) {
    let terminal = TerminalState.shared
    terminal.enterRawMode()
    defer { terminal.exitRawMode() }

    var cursor = 0
    var digitBuffer = ""

    // Shared shell coordinates
    let appX = 3
    let appY = 2
    let titleY = 4
    let ruleY = 5
    let bodyY = 7

    let barWidth = 20

    func termSize() -> (height: Int, width: Int) {
        var ws = winsize()
        _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws)
        let w = Int(ws.ws_col) > 0 ? Int(ws.ws_col) : 120
        let h = Int(ws.ws_row) > 0 ? Int(ws.ws_row) : 30
        return (h, w)
    }

    func render() {
        let (termHeight, _) = termSize()
        let footerY = termHeight - 1
        let statusY = footerY - 1

        let maxNameLen = speakers.map(\.name.count).max() ?? 0
        let padLen = maxNameLen + 2

        var out = ANSICode.cursorHome + ANSICode.clearScreen

        // App label
        out += ANSICode.moveTo(row: appY, col: appX)
        out += "\(ANSICode.dim)music\(ANSICode.reset)"

        // Title
        out += ANSICode.moveTo(row: titleY, col: appX)
        out += "\(ANSICode.bold)\(ANSICode.cyan)♫ Volume Mixer\(ANSICode.reset)"

        // Accent rule
        out += ANSICode.moveTo(row: ruleY, col: appX)
        out += "\(ANSICode.dim)\(String(repeating: "─", count: 18))\(ANSICode.reset)"

        // Speaker rows
        for (i, spk) in speakers.enumerated() {
            let row = bodyY + i
            out += ANSICode.moveTo(row: row, col: appX)

            let pointer = i == cursor ? "\(ANSICode.cyan)▶\(ANSICode.reset)" : " "
            let padded = spk.name.padding(toLength: padLen, withPad: " ", startingAt: 0)

            let filled = Int(Double(spk.volume) / 100.0 * Double(barWidth))
            let empty = barWidth - filled
            let bar = "\(ANSICode.green)\(String(repeating: "█", count: filled))\(ANSICode.reset)\(ANSICode.dim)\(String(repeating: "░", count: empty))\(ANSICode.reset)"
            let pct = String(format: "%3d%%", spk.volume)

            if i == cursor {
                out += "\(pointer) \(ANSICode.bold)\(padded)\(ANSICode.reset) \(bar)  \(pct)"
            } else {
                out += "\(pointer) \(padded) \(bar)  \(pct)"
            }
        }

        // Status row
        let activeCount = speakers.filter { $0.volume > 0 }.count
        out += ANSICode.moveTo(row: statusY, col: appX)
        out += "\(ANSICode.dim)\(activeCount) active output\(activeCount == 1 ? "" : "s")\(ANSICode.reset)"

        // Footer
        out += ANSICode.moveTo(row: footerY, col: appX)
        out += "\(ANSICode.dim)↑↓ Speaker   ←→ Adjust 5%   0-9 Quick Set   q Quit\(ANSICode.reset)"

        print(out, terminator: "")
        fflush(stdout)
    }

    render()

    while true {
        guard let key = KeyPress.read() else { continue }
        switch key {
        case .up:
            cursor = max(0, cursor - 1)
            digitBuffer = ""
        case .down:
            cursor = min(speakers.count - 1, cursor + 1)
            digitBuffer = ""
        case .left:
            speakers[cursor].volume = max(0, speakers[cursor].volume - 5)
            onVolumeChange(speakers[cursor].name, speakers[cursor].volume)
            digitBuffer = ""
        case .right:
            speakers[cursor].volume = min(100, speakers[cursor].volume + 5)
            onVolumeChange(speakers[cursor].name, speakers[cursor].volume)
            digitBuffer = ""
        case .char(let c) where c.isNumber:
            digitBuffer.append(c)
            if digitBuffer.count >= 2 {
                if let vol = Int(digitBuffer) {
                    speakers[cursor].volume = min(100, max(0, vol))
                    onVolumeChange(speakers[cursor].name, speakers[cursor].volume)
                }
                digitBuffer = ""
            }
        case .char("q"), .escape:
            return
        default:
            digitBuffer = ""
        }
        render()
    }
}
