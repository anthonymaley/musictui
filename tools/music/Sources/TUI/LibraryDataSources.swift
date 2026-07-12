// tools/music/Sources/TUI/LibraryDataSources.swift
// The I/O the Library scene depends on, packaged as closures so the scene holds
// no direct REST/AppleScript knowledge (mirrors PlaylistDataSources). Albums are
// the only wired sub-view for now; Artists/Songs land in later tasks.
import Foundation

struct LibraryDataSources {
    let onAlbums: () -> [LibraryAlbum]
    let onAlbumTracks: (_ albumTitle: String, _ artist: String) -> [String]
    let onSongs: () -> [LibrarySong]
    let onArtists: () -> [LibraryArtist]
    let onArtistAlbums: (_ artistID: String) -> [LibraryAlbum]
}

/// Walk every page of a paginated library list. The REST endpoints cap a single
/// response at `pageSize` (100), so fetching one page stranded large libraries
/// at the first ~100 items (artists dead-ended mid-alphabet). `page` is the
/// single-page fetch (it does its own syncRun); we advance `offset` until a short
/// page signals exhaustion, or `cap` trips as a safety valve against an endpoint
/// that never returns a short page. Pure w.r.t. the paging logic, so it's unit-
/// testable with a synchronous fake. A mid-walk failure (page returns []) reads
/// as a short page and stops early — partial is better than a crash.
func fetchAllPages<T>(pageSize: Int = 100, cap: Int = 10_000,
                      _ page: (_ limit: Int, _ offset: Int) -> [T]) -> [T] {
    var all: [T] = []
    var offset = 0
    while all.count < cap {
        let batch = page(pageSize, offset)
        all.append(contentsOf: batch)
        if batch.count < pageSize { break }
        offset += pageSize
    }
    return all
}

/// Build the Library closures. `onAlbums`/`onSongs`/`onArtists` hit the REST
/// library endpoints and page through them fully (see fetchAllPages);
/// `onAlbumTracks` reads the whole-library "Library" source playlist via
/// AppleScript, matching by album+artist (the same predicate the play path uses).
/// All are called off the main thread by the scene.
func makeLibraryDataSources(api: RESTAPIBackend, backend: AppleScriptBackend) -> LibraryDataSources {
    LibraryDataSources(
        onAlbums: {
            fetchAllPages { limit, offset in
                (try? syncRun { try await api.libraryAlbums(limit: limit, offset: offset) }) ?? []
            }
        },
        onAlbumTracks: { title, artist in
            let script = """
            set out to ""
            repeat with t in (every track of playlist "Library" whose album is "\(escapeAppleScriptString(title))" and artist is "\(escapeAppleScriptString(artist))")
                set out to out & (name of t) & linefeed
            end repeat
            return out
            """
            let raw = (try? syncRun { try await backend.runMusic(script, timeout: 30) }) ?? ""
            return raw.split(separator: "\n").map(String.init)
        },
        onSongs: {
            fetchAllPages { limit, offset in
                (try? syncRun { try await api.librarySongs(limit: limit, offset: offset) }) ?? []
            }
        },
        onArtists: {
            fetchAllPages { limit, offset in
                (try? syncRun { try await api.libraryArtists(limit: limit, offset: offset) }) ?? []
            }
        },
        // One artist's albums are few and the endpoint already asks for 100 — no paging.
        onArtistAlbums: { id in (try? syncRun { try await api.artistAlbums(artistID: id) }) ?? [] }
    )
}
