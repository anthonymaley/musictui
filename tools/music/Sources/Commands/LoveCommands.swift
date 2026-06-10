// tools/music/Sources/Commands/LoveCommands.swift
import ArgumentParser
import Foundation

// macOS 26 renamed the AppleScript property: `loved` errors with a descriptor
// type mismatch (-10001, verified live); `favorited` is the live property.

struct Love: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Favorite the current track.")
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        try setFavorited(true, json: json)
    }
}

struct Unlove: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unfavorite the current track.")
    @Flag(name: .long, help: "Output JSON") var json = false
    func run() throws {
        try setFavorited(false, json: json)
    }
}

private func setFavorited(_ value: Bool, json: Bool) throws {
    let backend = AppleScriptBackend()
    let result = try syncRun {
        try await backend.runMusic("""
            if player state is stopped then return "NOTHING"
            set favorited of current track to \(value)
            return name of current track & (ASCII character 31) & artist of current track
        """)
    }
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed == "NOTHING" {
        print(json ? "{\"ok\":false,\"error\":\"nothing playing\"}" : "Nothing playing.")
        throw ExitCode.failure
    }
    let parts = trimmed.split(separator: asFieldSep).map(String.init)
    let title = parts.first ?? "current track"
    if json {
        print("{\"ok\":true,\"favorited\":\(value),\"track\":\"\(title.replacingOccurrences(of: "\"", with: "\\\""))\"}")
    } else {
        print(value ? "\u{2665} Favorited '\(title)'." : "Unfavorited '\(title)'.")
    }
}
