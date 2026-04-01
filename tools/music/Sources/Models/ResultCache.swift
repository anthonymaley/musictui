import Foundation

struct SongResult: Codable, Equatable {
    let index: Int
    let title: String
    let artist: String
    let album: String
    let catalogId: String
}

struct SpeakerResult: Codable, Equatable {
    let index: Int
    let name: String
    let selected: Bool
    let volume: Int
}

enum CacheError: Error, LocalizedError {
    case noCache(String)
    case indexOutOfRange(Int)

    var errorDescription: String? {
        switch self {
        case .noCache(let domain): return "No cached \(domain) results. Run a search or list command first."
        case .indexOutOfRange(let i): return "Index \(i) is out of range."
        }
    }
}

struct ResultCache {
    let directory: String

    init(directory: String? = nil) {
        if let dir = directory {
            self.directory = dir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            self.directory = "\(home)/.config/music"
        }
    }

    private var songsPath: String { "\(directory)/last-songs.json" }
    private var speakersPath: String { "\(directory)/last-speakers.json" }

    func writeSongs(_ songs: [SongResult]) throws {
        let data = try JSONEncoder().encode(songs)
        try ensureDirectory()
        try data.write(to: URL(fileURLWithPath: songsPath))
    }

    func readSongs() throws -> [SongResult] {
        guard FileManager.default.fileExists(atPath: songsPath) else {
            throw CacheError.noCache("songs")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: songsPath))
        return try JSONDecoder().decode([SongResult].self, from: data)
    }

    func lookupSong(index: Int) throws -> SongResult {
        let songs = try readSongs()
        guard let song = songs.first(where: { $0.index == index }) else {
            throw CacheError.indexOutOfRange(index)
        }
        return song
    }

    func writeSpeakers(_ speakers: [SpeakerResult]) throws {
        let data = try JSONEncoder().encode(speakers)
        try ensureDirectory()
        try data.write(to: URL(fileURLWithPath: speakersPath))
    }

    func readSpeakers() throws -> [SpeakerResult] {
        guard FileManager.default.fileExists(atPath: speakersPath) else {
            throw CacheError.noCache("speakers")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: speakersPath))
        return try JSONDecoder().decode([SpeakerResult].self, from: data)
    }

    func lookupSpeaker(index: Int) throws -> SpeakerResult {
        let speakers = try readSpeakers()
        guard let speaker = speakers.first(where: { $0.index == index }) else {
            throw CacheError.indexOutOfRange(index)
        }
        return speaker
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
    }
}
