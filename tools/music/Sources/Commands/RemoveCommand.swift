import ArgumentParser
import Foundation

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove current song from a playlist.")
    @Argument(help: "Playlist name, or 'all' to remove from all playlists") var target: [String] = []
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let backend = AppleScriptBackend()

        let trackResult = try syncRun {
            try await backend.runMusic("return name of current track & (ASCII character 31) & artist of current track")
        }
        let parts = trackResult.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: asFieldSep)
        guard parts.count >= 2 else {
            print("Nothing playing.")
            throw ExitCode.failure
        }
        let title = String(parts[0])
        let artist = String(parts[1])
        let escapedTitle = escapeAppleScriptString(title)
        let escapedArtist = escapeAppleScriptString(artist)

        func deleteTrack(from playlist: String) throws -> Bool {
            let escapedPlaylist = escapeAppleScriptString(playlist)
            let check = try? syncRun {
                try await backend.runMusic("""
                    set matches to (every track of playlist "\(escapedPlaylist)" whose name is "\(escapedTitle)" and artist is "\(escapedArtist)")
                    if (count of matches) = 0 then
                        set matches to (every track of playlist "\(escapedPlaylist)" whose name contains "\(escapedTitle)" and artist contains "\(escapedArtist)")
                    end if
                    if (count of matches) > 0 then
                        delete item 1 of matches
                        return "DELETED"
                    else
                        return "NOT_FOUND"
                    end if
                """)
            }
            return check?.trimmingCharacters(in: .whitespacesAndNewlines) == "DELETED"
        }

        // One output path so --json is honored everywhere (the flag used to be
        // declared and never read).
        func report(removedFrom: [String]) {
            if json {
                let output = OutputFormat(mode: .json)
                print(output.render(["removed": !removedFrom.isEmpty, "track": title, "artist": artist, "playlists": removedFrom]))
            } else if removedFrom.isEmpty {
                print("'\(title)' not found.")
            } else {
                print("Removed '\(title)' from: \(removedFrom.joined(separator: ", "))")
            }
        }

        if target.isEmpty {
            let playlistResult = try syncRun {
                try await backend.runMusic("""
                    if exists current playlist then
                        return name of current playlist
                    else
                        return "NO_PLAYLIST"
                    end if
                """)
            }
            let playlistName = playlistResult.trimmingCharacters(in: .whitespacesAndNewlines)
            if playlistName == "NO_PLAYLIST" {
                print(json ? "{\"removed\":false,\"error\":\"not playing from a playlist\"}" : "Not playing from a playlist.")
                throw ExitCode.failure
            }
            report(removedFrom: try deleteTrack(from: playlistName) ? [playlistName] : [])

        } else if target.count == 1 && target[0].lowercased() == "all" {
            let allPlaylists = try syncRun {
                try await backend.runMusic("get name of every user playlist")
            }
            let names = allPlaylists.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            var removedFrom: [String] = []
            for pl in names {
                if (try? deleteTrack(from: pl)) == true {
                    removedFrom.append(pl)
                }
            }
            report(removedFrom: removedFrom)

        } else {
            let playlistName = target.joined(separator: " ")
            report(removedFrom: try deleteTrack(from: playlistName) ? [playlistName] : [])
        }
    }
}
