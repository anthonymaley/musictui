import ArgumentParser
import Foundation

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search and add a track to your library, or add to a playlist.")
    @Argument(help: "Search query or result index") var query: [String] = []
    @Option(name: .long, help: "Add by catalog ID directly") var id: String?
    @Option(name: .long, help: "Add to playlist(s)") var to: [String] = []
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        let userToken = try auth.requireUserToken()
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())

        var songToAdd: CatalogSong?
        var trackTitle: String?
        var trackArtist: String?

        if let catalogID = id {
            try syncRun { try await api.addToLibrary(songIDs: [catalogID]) }
            // The API playlist-add only needs the ID (this path used to fall
            // through silently because it had no title for the AppleScript lookup).
            let backend = AppleScriptBackend()
            for pl in to {
                try addSongs([CatalogSong(id: catalogID, title: "(id \(catalogID))", artist: "", album: "")],
                             to: pl, api: api, backend: backend)
                print("Added to '\(pl)'.")
            }
            print(json ? "{\"added\":\"\(catalogID)\"}" : "Added (id: \(catalogID)).")
            return
        } else if query.count == 1, let index = Int(query[0]) {
            let cache = ResultCache()
            let song = try cache.lookupSong(index: index)
            songToAdd = CatalogSong(id: song.catalogId, title: song.title, artist: song.artist, album: song.album)
        } else if !query.isEmpty {
            let searchQuery = query.joined(separator: " ")
            let songs = try syncRun { try await api.searchSongs(query: searchQuery, limit: 1) }
            guard let song = songs.first else {
                print("No results for '\(searchQuery)'")
                throw ExitCode.failure
            }
            songToAdd = song
        } else if !to.isEmpty {
            let backend = AppleScriptBackend()
            let result = try syncRun {
                try await backend.runMusic("return name of current track & \"|\" & artist of current track")
            }
            let parts = result.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
            if parts.count >= 2 {
                trackTitle = String(parts[0])
                trackArtist = String(parts[1])
            }
        } else {
            print("Usage: music add <query>, music add <index>, or music add --to <playlist>")
            throw ExitCode.failure
        }

        if let song = songToAdd {
            print("Found: \(song.title) — \(song.artist) [\(song.album)]")
            try syncRun { try await api.addToLibrary(songIDs: [song.id]) }

            if to.isEmpty {
                if json {
                    let output = OutputFormat(mode: .json)
                    print(output.render(["added": true, "track": song.title, "artist": song.artist, "id": song.id]))
                } else {
                    print("Added to library.")
                }
                return
            }
        }

        if !to.isEmpty {
            let backend = AppleScriptBackend()
            if let song = songToAdd {
                // Catalog ID known: direct API add per playlist (no sync sleep).
                for pl in to {
                    try addSongs([song], to: pl, api: api, backend: backend)
                    print("Added to '\(pl)'.")
                }
            } else if let title = trackTitle, let artist = trackArtist {
                // Current track (no catalog ID): it's already in the library, so
                // the AppleScript duplicate is direct — no sync wait needed.
                for pl in to {
                    if duplicateLibraryTrack(backend: backend, title: title, artist: artist, toPlaylist: pl) {
                        print("Added to '\(pl)'.")
                    } else {
                        print("Couldn't add '\(title)' to '\(pl)'.")
                    }
                }
            }
        }
    }
}
