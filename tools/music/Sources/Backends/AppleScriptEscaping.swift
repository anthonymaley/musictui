import Foundation

/// Escapes a string for safe interpolation inside an AppleScript double-quoted
/// string literal. Backslash must be escaped first, then the double-quote —
/// otherwise the backslashes introduced for quotes would themselves be doubled.
///
/// Names containing `\` (e.g. a playlist named `AC\DC`) or `"` previously
/// corrupted the generated script or mis-targeted the query; route every
/// user/catalog-supplied value through here before interpolation.
func escapeAppleScriptString(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

/// Field delimiter for multi-field AppleScript output. Track titles can
/// legally contain `|` (the old delimiter — "Intro | Outro" shifted every
/// field after it); the ASCII unit separator cannot appear in real names.
/// Script side: `set fs to (ASCII character 31)`.
let asFieldSep: Character = "\u{001F}"
