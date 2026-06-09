// tools/music/Sources/Backends/LibraryLookup.swift
import Foundation

/// The exact-then-contains library track lookup every "find a library track by
/// title/artist" script shares. Leaves the matches in `results`; the caller
/// appends its action (play / duplicate / ...). One definition instead of ~10
/// hand-rolled copies, each with its own manual escaping.
func libraryTrackLookupScript(title: String, artist: String) -> String {
    let t = escapeAppleScriptString(title)
    let a = escapeAppleScriptString(artist)
    return """
    set results to (every track of playlist "Library" whose name is "\(t)" and artist is "\(a)")
    if (count of results) = 0 then
        set results to (every track of playlist "Library" whose name contains "\(t)" and artist contains "\(a)")
    end if
    """
}

/// AppleScript fallback for playlist adds when the REST API can't see the
/// target playlist (not yet synced): duplicate a library track into it.
/// Returns false when the script failed or no library track matched.
@discardableResult
func duplicateLibraryTrack(backend: AppleScriptBackend, title: String, artist: String, toPlaylist playlist: String) -> Bool {
    guard let result = try? syncRun({
        try await backend.runMusic("""
            \(libraryTrackLookupScript(title: title, artist: artist))
            if (count of results) > 0 then
                duplicate item 1 of results to playlist "\(escapeAppleScriptString(playlist))"
                return "OK"
            end if
            return "NOT_FOUND"
        """)
    }) else { return false }
    return result.trimmingCharacters(in: .whitespacesAndNewlines) == "OK"
}

/// Wait (bounded) for an API-created playlist to sync to the local Music.app —
/// needed before AppleScript can play it. Polls instead of a fixed sleep: the
/// wait ends the moment the tracks are visible. Returns false on timeout.
func waitForLocalPlaylist(backend: AppleScriptBackend, name: String, minTracks: Int, timeoutSeconds: Double = 15) -> Bool {
    let esc = escapeAppleScriptString(name)
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        let count = (try? syncRun {
            try await backend.runMusic("""
                if exists playlist "\(esc)" then
                    return (count of tracks of playlist "\(esc)") as text
                end if
                return "-1"
            """)
        }).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? -1
        if count >= minTracks { return true }
        usleep(500_000)
    }
    return false
}
