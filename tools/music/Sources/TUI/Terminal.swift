// Sources/TUI/Terminal.swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct ANSICode {
    static let clearScreen = "\u{1B}[2J"
    static let cursorHome = "\u{1B}[H"
    static let hideCursor = "\u{1B}[?25l"
    static let showCursor = "\u{1B}[?25h"
    static let altScreenOn = "\u{1B}[?1049h"
    static let altScreenOff = "\u{1B}[?1049l"
    static let clearLine = "\u{1B}[2K"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let reset = "\u{1B}[0m"
    static let inverse = "\u{1B}[7m"
    static let red = "\u{1B}[31m"
    static let green = "\u{1B}[32m"
    static let cyan = "\u{1B}[36m"
    static let yellow = "\u{1B}[33m"
    static let brightWhite = "\u{1B}[97m"
    static let lime = "\u{1B}[92m"
    static let amber = "\u{1B}[38;2;255;176;0m"
    static let white = "\u{1B}[37m"

    static func moveTo(row: Int, col: Int) -> String {
        "\u{1B}[\(row);\(col)H"
    }
}

enum KeyPress {
    case up, down, left, right
    case pageUp, pageDown, home, end
    case shiftTab
    case f7, f9
    case enter, space, escape
    case char(Character)

    /// Read one byte from stdin. Returns nil on failure.
    private static func readByte() -> UInt8? {
        var byte: UInt8 = 0
        guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
        return byte
    }

    /// Parse a single keypress by reading one byte at a time.
    private static func parseKey() -> KeyPress? {
        guard let byte = readByte() else { return nil }

        if byte == 0x1B {
            // ESC received — check for escape sequence
            guard let seq1 = readByte() else { return .escape }
            if seq1 == 0x5B {
                guard let seq2 = readByte() else { return .escape }
                switch seq2 {
                case 0x41: return .up
                case 0x42: return .down
                case 0x43: return .right
                case 0x44: return .left
                case 0x48: return .home      // ESC [ H
                case 0x46: return .end       // ESC [ F
                case 0x5A: return .shiftTab  // ESC [ Z
                case 0x31...0x39:
                    var sequence = String(UnicodeScalar(seq2))
                    var bytesRead = 0
                    while bytesRead < 8, let next = readByte() {
                        bytesRead += 1
                        sequence.append(Character(UnicodeScalar(next)))
                        if next == 0x7E || (next >= 0x40 && next <= 0x7E) {
                            break
                        }
                    }
                    switch sequence {
                    case "5~": return .pageUp
                    case "6~": return .pageDown
                    case "1~", "7~": return .home
                    case "4~", "8~": return .end
                    case "18~": return .f7
                    case "20~": return .f9
                    default: return nil
                    }
                default: return nil
                }
            }
            if seq1 == 0x4F {
                // Application-mode Home/End (ESC O H / ESC O F).
                guard let seq2 = readByte() else { return .escape }
                switch seq2 {
                case 0x48: return .home
                case 0x46: return .end
                default: return nil
                }
            }
            return .escape
        }

        switch byte {
        case 0x0A, 0x0D: return .enter
        case 0x20: return .space
        default:
            return .char(Character(Unicode.Scalar(byte)))
        }
    }

    /// Blocking read — waits indefinitely for a keypress.
    static func read() -> KeyPress? {
        return parseKey()
    }

    /// Read with timeout in seconds. Returns nil if no key pressed within timeout.
    static func read(timeout: Double) -> KeyPress? {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ms = Int32(timeout * 1000)
        let ready = poll(&pfd, 1, ms)
        guard ready > 0, pfd.revents & Int16(POLLIN) != 0 else { return nil }
        return parseKey()
    }
}

/// Global flag set by SIGWINCH handler — check and reset in render loops.
var terminalResized = false

class TerminalState {
    private var originalTermios: termios?
    private var isRaw = false

    static let shared = TerminalState()

    func enterRawMode() {
        guard !isRaw else { return }
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        originalTermios = raw
        raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG)
        withUnsafeMutablePointer(to: &raw.c_cc) { ptr in
            let base = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: cc_t.self)
            base[Int(VMIN)] = 1
            base[Int(VTIME)] = 0
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        isRaw = true
        print(ANSICode.altScreenOn + ANSICode.hideCursor, terminator: "")
        fflush(stdout)

        signal(SIGINT) { _ in
            TerminalState.shared.exitRawMode()
            exit(0)
        }
        signal(SIGWINCH) { _ in
            terminalResized = true
        }
    }

    func exitRawMode() {
        guard isRaw, var original = originalTermios else { return }
        isRaw = false
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        print(ANSICode.showCursor + ANSICode.altScreenOff, terminator: "")
        fflush(stdout)
        signal(SIGINT, SIG_DFL)
        signal(SIGWINCH, SIG_DFL)
    }
}

func isTTY() -> Bool {
    isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
}

/// Returns true if the user typed ONLY "music <command>" with no additional args or flags.
/// Checks CommandLine.arguments directly so default values can't fool it.
func isBareInvocation(command: String) -> Bool {
    let args = CommandLine.arguments.dropFirst() // drop binary path
    return args.count == 1 && args.first?.lowercased() == command.lowercased()
}
