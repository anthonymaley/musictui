import ArgumentParser
import Foundation

struct Mix: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build a mixed playlist from multiple artists.")
    @Option(name: .long, help: "Comma-separated artist names") var artists: String
    @Option(name: .long, help: "Total track count") var count: Int = 20
    @Option(name: .long, help: "Playlist name") var name: String = "Mix"
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let auth = AuthManager()
        let devToken = try auth.requireDeveloperToken()
        let userToken = try auth.requireUserToken()
        let api = RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())

        let artistList = artists.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let perArtist = max(count / artistList.count, 2)

        var allSongs: [CatalogSong] = []
        for artist in artistList {
            let songs = try syncRun { try await api.searchSongs(query: artist, limit: perArtist) }
            allSongs.append(contentsOf: songs)
        }

        // One API call creates and populates — no library detour, no sync sleep.
        _ = try syncRun { try await api.createPlaylist(name: name, songIDs: allSongs.map(\.id)) }

        let output = OutputFormat(mode: json ? .json : .human)
        if json {
            print(output.render(["playlist": name, "tracks": allSongs.count, "artists": artistList]))
        } else {
            print("Created '\(name)' with \(allSongs.count) tracks from \(artistList.joined(separator: ", ")).")
        }
    }
}
