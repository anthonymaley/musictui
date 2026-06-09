import Foundation

struct CatalogSong {
    let id: String
    let title: String
    let artist: String
    let album: String

    func toDict() -> [String: Any] {
        ["id": id, "title": title, "artist": artist, "album": album]
    }
}

struct RESTAPIBackend {
    let developerToken: String
    let userToken: String?
    let storefront: String

    // MARK: - Raw requests

    func get(_ path: String) async throws -> (Data, Int) {
        let url = URL(string: "https://api.music.apple.com\(path)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        if let userToken = userToken {
            request.setValue(userToken, forHTTPHeaderField: "Music-User-Token")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as! HTTPURLResponse).statusCode)
    }

    func post(_ path: String, body: Data? = nil) async throws -> (Data, Int) {
        let url = URL(string: "https://api.music.apple.com\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        if let userToken = userToken {
            request.setValue(userToken, forHTTPHeaderField: "Music-User-Token")
        }
        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as! HTTPURLResponse).statusCode)
    }

    // MARK: - Catalog Search

    func searchSongs(query: String, limit: Int = 10) async throws -> [CatalogSong] {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let (data, status) = try await get("/v1/catalog/\(storefront)/search?term=\(encoded)&types=songs&limit=\(limit)")
        guard (200...299).contains(status) else {
            throw APIError.requestFailed(status)
        }
        return try parseSongs(from: data)
    }

    func song(id: String) async throws -> CatalogSong {
        let (data, status) = try await get("/v1/catalog/\(storefront)/songs/\(id)")
        guard (200...299).contains(status) else {
            throw APIError.requestFailed(status)
        }
        return try parseCatalogSong(from: data)
    }

    // MARK: - Library Operations (require user token)

    func addToLibrary(songIDs: [String]) async throws {
        guard userToken != nil else { throw AuthError.userTokenRequired }
        let ids = songIDs.joined(separator: ",")
        let path = "/v1/me/library?ids%5Bsongs%5D=\(ids)"
        let (_, status) = try await post(path)
        guard (200...299).contains(status) else {
            if status == 401 || status == 403 { throw AuthError.userTokenExpired(status) }
            throw APIError.requestFailed(status)
        }
    }

    // MARK: - Library Playlists (require user token)

    struct LibraryPlaylist {
        let id: String
        let name: String
    }

    /// All library playlists, following pagination. User-created playlists are
    /// all API-visible (verified live); only the built-in smart playlists
    /// (Music, Recently Added, ...) are AppleScript-only.
    func libraryPlaylists() async throws -> [LibraryPlaylist] {
        guard userToken != nil else { throw AuthError.userTokenRequired }
        var out: [LibraryPlaylist] = []
        var path: String? = "/v1/me/library/playlists?limit=100"
        while let p = path {
            let (data, status) = try await get(p)
            guard (200...299).contains(status) else { throw APIError.requestFailed(status) }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            for item in json?["data"] as? [[String: Any]] ?? [] {
                let attrs = item["attributes"] as? [String: Any] ?? [:]
                guard let id = item["id"] as? String, let name = attrs["name"] as? String else { continue }
                out.append(LibraryPlaylist(id: id, name: name))
            }
            path = json?["next"] as? String
        }
        return out
    }

    /// API ID of the library playlist with this exact name, or nil if the API
    /// can't see it (built-in smart playlists; a locally-created playlist that
    /// hasn't synced yet).
    func playlistID(named name: String) async throws -> String? {
        try await libraryPlaylists().first { $0.name == name }?.id
    }

    /// Add catalog songs to a library playlist directly — no add-to-library,
    /// no sync sleep, no AppleScript title lookup. POST returns 204.
    func addTracksToPlaylist(playlistID: String, songIDs: [String]) async throws {
        guard userToken != nil else { throw AuthError.userTokenRequired }
        guard !songIDs.isEmpty else { return }
        let body = try JSONSerialization.data(withJSONObject: playlistTracksRequestBody(songIDs: songIDs))
        let (_, status) = try await post("/v1/me/library/playlists/\(playlistID)/tracks", body: body)
        guard (200...299).contains(status) else {
            if status == 401 || status == 403 { throw AuthError.userTokenExpired(status) }
            throw APIError.requestFailed(status)
        }
    }

    /// Create a library playlist (optionally with catalog songs in one call)
    /// and return its API ID.
    func createPlaylist(name: String, songIDs: [String] = []) async throws -> String {
        guard userToken != nil else { throw AuthError.userTokenRequired }
        let body = try JSONSerialization.data(withJSONObject: playlistCreationRequestBody(name: name, songIDs: songIDs))
        let (data, status) = try await post("/v1/me/library/playlists", body: body)
        guard (200...299).contains(status) else {
            if status == 401 || status == 403 { throw AuthError.userTokenExpired(status) }
            throw APIError.requestFailed(status)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = (json?["data"] as? [[String: Any]])?.first?["id"] as? String else {
            throw APIError.noData
        }
        return id
    }

    // MARK: - Parsing

    private func parseSongs(from data: Data) throws -> [CatalogSong] {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = json?["results"] as? [String: Any]
        let songs = results?["songs"] as? [String: Any]
        let songData = songs?["data"] as? [[String: Any]] ?? []

        return songData.map(parseCatalogSongObject)
    }

    private func parseCatalogSong(from data: Data) throws -> CatalogSong {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let songData = json?["data"] as? [[String: Any]] ?? []
        guard let song = songData.first else {
            throw APIError.noData
        }
        return parseCatalogSongObject(song)
    }

    private func parseCatalogSongObject(_ song: [String: Any]) -> CatalogSong {
        let attrs = song["attributes"] as? [String: Any] ?? [:]
        return CatalogSong(
            id: song["id"] as? String ?? "",
            title: attrs["name"] as? String ?? "Unknown",
            artist: attrs["artistName"] as? String ?? "Unknown",
            album: attrs["albumName"] as? String ?? ""
        )
    }
}

/// Body for POST /v1/me/library/playlists/{id}/tracks (verified against the
/// LibraryPlaylistTracksRequest schema: the wrapper field is `data`, catalog
/// songs use type `songs`). Pure, for testability.
func playlistTracksRequestBody(songIDs: [String]) -> [String: Any] {
    ["data": songIDs.map { ["id": $0, "type": "songs"] }]
}

/// Body for POST /v1/me/library/playlists, optionally seeding tracks via the
/// `relationships.tracks` shape so create+populate is a single request. Pure.
func playlistCreationRequestBody(name: String, songIDs: [String]) -> [String: Any] {
    var body: [String: Any] = ["attributes": ["name": name]]
    if !songIDs.isEmpty {
        body["relationships"] = ["tracks": playlistTracksRequestBody(songIDs: songIDs)]
    }
    return body
}

enum APIError: Error, LocalizedError {
    case requestFailed(Int)
    case noData

    var errorDescription: String? {
        switch self {
        case .requestFailed(let code): return "API request failed with status \(code)"
        case .noData: return "API response did not include data"
        }
    }
}
