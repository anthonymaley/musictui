// tools/music/Sources/Commands/HistoryCommands.swift
import ArgumentParser
import Foundation

// Listening history via the REST API (endpoints verified against Apple's
// docs JSON). Results land in the shared ResultCache, so `music play 3`,
// `music add 2`, and `music playlist create X 1 2 3` chain off them.

struct Recent: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Recently played tracks.")
    @Option(name: .long, help: "Max results (API caps at 10 per page)") var limit: Int = 10
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let api = try makeUserAPI()
        // Apple's docs slug says "played-tracks" but the live API serves
        // /recent/played/tracks (the hyphenated path 404s — verified live).
        let lim = min(10, max(1, limit))
        var (data, status) = try syncRun { try await api.get("/v1/me/recent/played/tracks?limit=\(lim)") }
        if status == 404 {
            (data, status) = try syncRun { try await api.get("/v1/me/recent/played-tracks?limit=\(lim)") }
        }
        guard (200...299).contains(status) else { throw APIError.requestFailed(status) }
        try printHistorySongs(data: data, label: "recent", json: json)
    }
}

struct Rotation: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Your heavy-rotation music.")
    @Option(name: .long, help: "Max results") var limit: Int = 10
    @Flag(name: .long, help: "Output JSON") var json = false

    func run() throws {
        let api = try makeUserAPI()
        let (data, status) = try syncRun { try await api.get("/v1/me/history/heavy-rotation?limit=\(min(10, max(1, limit)))") }
        guard (200...299).contains(status) else { throw APIError.requestFailed(status) }
        try printHistorySongs(data: data, label: "heavy rotation", json: json)
    }
}

private func makeUserAPI() throws -> RESTAPIBackend {
    let auth = AuthManager()
    let devToken = try auth.requireDeveloperToken()
    let userToken = try auth.requireUserToken()
    return RESTAPIBackend(developerToken: devToken, userToken: userToken, storefront: auth.storefront())
}

/// Print a history response. Items can be mixed resource types (songs,
/// albums, playlists, stations); song-shaped items go into the ResultCache so
/// index chaining works, others are listed with their type.
private func printHistorySongs(data: Data, label: String, json: Bool) throws {
    let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let items = parsed?["data"] as? [[String: Any]] ?? []
    guard !items.isEmpty else {
        print(json ? "{\"\(label.replacingOccurrences(of: " ", with: "-"))\":[]}" : "No \(label) history.")
        return
    }

    var cacheable: [SongResult] = []
    var lines: [String] = []
    var dicts: [[String: Any]] = []
    for item in items {
        let attrs = item["attributes"] as? [String: Any] ?? [:]
        let type = item["type"] as? String ?? ""
        let name = attrs["name"] as? String ?? "Unknown"
        let artist = attrs["artistName"] as? String ?? ""
        let album = attrs["albumName"] as? String ?? ""
        let isSong = type.contains("song")
        let catalogId = (attrs["playParams"] as? [String: Any])?["catalogId"] as? String
            ?? (isSong ? (item["id"] as? String ?? "") : "")
        if isSong {
            cacheable.append(SongResult(index: cacheable.count + 1, title: name, artist: artist, album: album, catalogId: catalogId))
            lines.append("\(cacheable.count). \(name) — \(artist)\(album.isEmpty ? "" : " [\(album)]")")
        } else {
            let kind = type.replacingOccurrences(of: "library-", with: "").replacingOccurrences(of: "s", with: "", options: [.anchored, .backwards])
            lines.append("   \(name)\(artist.isEmpty ? "" : " — \(artist)") (\(kind))")
        }
        dicts.append(["type": type, "name": name, "artist": artist, "album": album])
    }
    if !cacheable.isEmpty { try? ResultCache().writeSongs(cacheable) }

    if json {
        let output = OutputFormat(mode: .json)
        print(output.render(["items": dicts]))
    } else {
        for line in lines { print(line) }
    }
}
