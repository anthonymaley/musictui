// Music.app equalizer access — two transports, by necessity:
//
//  * EQ PRESET objects (create / read bands / delete) script fine through
//    the normal Music dictionary and go through runMusic.
//  * LIVE state (EQ enabled, current preset) is severed in current
//    Music.app builds: writes error (-10006 / -1731 in every reference
//    form) and reads return stale values even while the real Equalizer
//    is on — verified live 2026-06-12. The Equalizer window's own
//    controls are the only working interface, so live state goes through
//    System Events UI scripting. That requires Accessibility permission
//    for the host terminal, and opens the Equalizer window (leaving it
//    open) on first use.
//
// Free-function style mirrors fetchSpeakerDevices() in SpeakerCommands.swift.
import Foundation

struct EQSnapshot: Equatable {
    var enabled: Bool
    var current: String?      // nil when no preset has ever been chosen
    var presets: [String]
}

let eqAccessibilityHint = """
EQ control drives Music's Equalizer window and needs Accessibility permission: \
System Settings → Privacy & Security → Accessibility → enable your terminal app, then retry.
"""

/// Pure parse of the UI status script output: "<0|1><RS><preset name>".
func parseEQUIStatus(_ raw: String) -> (enabled: Bool, current: String?)? {
    let fields = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: "\u{1E}")
    guard fields.count == 2, fields[0] == "0" || fields[0] == "1" else { return nil }
    return (fields[0] == "1", fields[1].isEmpty ? nil : fields[1])
}

/// Wraps a System Events body targeting the Equalizer window, opening the
/// window via Music's Window menu when it isn't showing. `launch` (not
/// `activate`) avoids stealing focus from the user's terminal.
private func eqUIScript(_ body: String) -> String {
    """
    tell application "Music" to launch
    tell application "System Events"
        tell process "Music"
            if not (exists window "Equalizer") then
                click menu item "Equalizer" of menu "Window" of menu bar 1
                delay 0.5
            end if
            tell window "Equalizer"
                \(body)
            end tell
        end tell
    end tell
    """
}

/// Runs an Equalizer-window UI script, translating an assistive-access
/// denial into an actionable message.
private func eqUIRun(_ backend: AppleScriptBackend, _ body: String) throws -> String {
    do {
        return try syncRun { try await backend.run(eqUIScript(body)) }
    } catch let error as AppleScriptBackend.ScriptError {
        if case .executionFailed(let msg) = error,
           msg.contains("assistive") || msg.contains("-1719") || msg.contains("-25211") {
            throw AppleScriptBackend.ScriptError.executionFailed(eqAccessibilityHint)
        }
        throw error
    }
}

func fetchEQSnapshot(_ backend: AppleScriptBackend) throws -> EQSnapshot {
    // Preset names: the scripting dictionary path still works for these.
    let names = try syncRun {
        try await backend.runMusic("""
            set us to character id 31
            set nameList to ""
            repeat with p in EQ presets
                if nameList is not "" then set nameList to nameList & us
                set nameList to nameList & (name of p)
            end repeat
            return nameList
            """)
    }.trimmingCharacters(in: .whitespacesAndNewlines)
    // Live state: only the window tells the truth.
    // Dereference into variables before coercing — `(value of checkbox 1)
    // as string` coerces the unresolved specifier and errors -1700.
    let raw = try eqUIRun(backend, """
        set cbv to value of checkbox 1
        set pv to ""
        try
            set pv to value of pop up button 1
        end try
        return (cbv as string) & (character id 30) & pv
        """)
    guard let ui = parseEQUIStatus(raw) else {
        throw AppleScriptBackend.ScriptError.executionFailed("unparseable EQ state: \(raw.prefix(80))")
    }
    return EQSnapshot(enabled: ui.enabled, current: ui.current,
                      presets: names.isEmpty ? [] : names.components(separatedBy: "\u{1F}"))
}

/// Ten band gains (32 Hz–16 kHz) of a named preset, for the status
/// sparkline. Preamp is not included.
func fetchEQBands(_ backend: AppleScriptBackend, name: String) throws -> [Double] {
    let esc = escapeAppleScriptString(name)
    let raw = try syncRun {
        try await backend.runMusic("""
            tell EQ preset "\(esc)"
                return (band 1 as string) & "," & (band 2 as string) & "," & (band 3 as string) & "," & (band 4 as string) & "," & (band 5 as string) & "," & (band 6 as string) & "," & (band 7 as string) & "," & (band 8 as string) & "," & (band 9 as string) & "," & (band 10 as string)
            end tell
            """)
    }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: ",").compactMap(Double.init)
}

func eqSetEnabled(_ backend: AppleScriptBackend, _ on: Bool) throws {
    _ = try eqUIRun(backend, """
        set cbv to value of checkbox 1
        if (cbv as integer) is not \(on ? 1 : 0) then click checkbox 1
        """)
}

func eqSetCurrent(_ backend: AppleScriptBackend, name: String) throws {
    let esc = escapeAppleScriptString(name)
    _ = try eqUIRun(backend, """
        tell pop up button 1
            click
            delay 0.2
            if exists menu item "\(esc)" of menu 1 then
                click menu item "\(esc)" of menu 1
            else
                key code 53
                error "preset '\(esc)' is not in the Equalizer menu"
            end if
        end tell
        """)
}

/// Create a venue preset if absent. An existing preset with the same name is
/// used as-is — we never overwrite bands (spec: lifecycle semantics).
func eqEnsurePreset(_ backend: AppleScriptBackend, preset: VenuePreset) throws {
    let esc = escapeAppleScriptString(preset.name)
    let bandSets = preset.bands.enumerated()
        .map { "set band \($0.offset + 1) to \($0.element)" }
        .joined(separator: "\n                ")
    _ = try syncRun {
        try await backend.runMusic("""
            if not (exists EQ preset "\(esc)") then
                make new EQ preset with properties {name:"\(esc)"}
                tell EQ preset "\(esc)"
                    \(bandSets)
                    set preamp to \(preset.preamp)
                end tell
            end if
            """)
    }
}

/// Returns true if a preset was deleted, false if it didn't exist.
func eqDeletePreset(_ backend: AppleScriptBackend, name: String) throws -> Bool {
    let esc = escapeAppleScriptString(name)
    let raw = try syncRun {
        try await backend.runMusic("""
            if exists EQ preset "\(esc)" then
                delete EQ preset "\(esc)"
                return "deleted"
            end if
            return "absent"
            """)
    }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "deleted"
}
