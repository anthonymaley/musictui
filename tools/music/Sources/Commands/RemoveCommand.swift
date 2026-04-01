import ArgumentParser
import Foundation

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Remove current song from a playlist.")
    @Argument(help: "Playlist name, or 'all' to remove from all playlists") var target: [String] = []
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let backend = AppleScriptBackend()

        let trackResult = try syncRun {
            try await backend.runMusic("return name of current track & \"|\" & artist of current track")
        }
        let parts = trackResult.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        guard parts.count >= 2 else {
            print("Nothing playing.")
            throw ExitCode.failure
        }
        let title = String(parts[0])
        let artist = String(parts[1])
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedArtist = artist.replacingOccurrences(of: "\"", with: "\\\"")

        func deleteTrack(from playlist: String) throws -> Bool {
            let check = try? syncRun {
                try await backend.runMusic("""
                    set matches to (every track of playlist "\(playlist)" whose name is "\(escapedTitle)" and artist is "\(escapedArtist)")
                    if (count of matches) = 0 then
                        set matches to (every track of playlist "\(playlist)" whose name contains "\(escapedTitle)" and artist contains "\(escapedArtist)")
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
                print("Not playing from a playlist.")
                throw ExitCode.failure
            }
            if try deleteTrack(from: playlistName) {
                print("Removed '\(title)' from '\(playlistName)'.")
            } else {
                print("'\(title)' not found in '\(playlistName)'.")
            }

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
            if removedFrom.isEmpty {
                print("'\(title)' not found in any playlist.")
            } else {
                print("Removed '\(title)' from: \(removedFrom.joined(separator: ", "))")
            }

        } else {
            let playlistName = target.joined(separator: " ")
            if try deleteTrack(from: playlistName) {
                print("Removed '\(title)' from '\(playlistName)'.")
            } else {
                print("'\(title)' not found in '\(playlistName)'.")
            }
        }
    }
}
