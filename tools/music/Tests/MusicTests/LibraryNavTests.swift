// tools/music/Tests/MusicTests/LibraryNavTests.swift
import XCTest
@testable import music

final class LibraryNavTests: XCTestCase {
    private let albumSel = LibrarySelection(id: "l.aaa", primary: "Kid A", secondary: "Radiohead")

    // Explicit level roots so the album/song tests don't depend on the sub-view
    // cycle order (which is exercised on its own below).
    private var albumsNav: LibraryNav { LibraryNav(subView: .albums, stack: [.albumList], cursor: 0) }
    private var songsNav: LibraryNav { LibraryNav(subView: .songs, stack: [.songList], cursor: 0) }

    func testStartsOnArtistsRoot() {
        let s = LibraryNav.initial
        XCTAssertEqual(s.subView, .artists)
        XCTAssertEqual(s.current, .artistList)
        XCTAssertEqual(s.cursor, 0)
    }

    func testSubViewCycleIsArtistsAlbumsSongs() {
        var s = LibraryNav.initial
        XCTAssertEqual(s.subView, .artists)
        (s, _) = libraryReduce(s, .switchNext, itemCount: 0, selection: nil)
        XCTAssertEqual(s.subView, .albums)
        (s, _) = libraryReduce(s, .switchNext, itemCount: 0, selection: nil)
        XCTAssertEqual(s.subView, .songs)
        (s, _) = libraryReduce(s, .switchNext, itemCount: 0, selection: nil)
        XCTAssertEqual(s.subView, .artists)              // wraps forward
        (s, _) = libraryReduce(s, .switchPrev, itemCount: 0, selection: nil)
        XCTAssertEqual(s.subView, .songs)                // wraps back
    }

    func testDownMovesCursorClamped() {
        var (s, _) = libraryReduce(albumsNav, .down, itemCount: 2, selection: albumSel)
        XCTAssertEqual(s.cursor, 1)
        (s, _) = libraryReduce(s, .down, itemCount: 2, selection: albumSel)  // clamp at last
        XCTAssertEqual(s.cursor, 1)
    }

    func testSwitchResetsCursorAndLevel() {
        var (s, _) = libraryReduce(albumsNav, .down, itemCount: 5, selection: albumSel)
        XCTAssertEqual(s.cursor, 1)
        (s, _) = libraryReduce(s, .switchNext, itemCount: 5, selection: albumSel)
        XCTAssertEqual(s.subView, .songs)
        XCTAssertEqual(s.current, .songList)
        XCTAssertEqual(s.cursor, 0)
    }

    func testEnterOnAlbumListPushesTracksAndFetches() {
        let (s, action) = libraryReduce(albumsNav, .enter, itemCount: 2, selection: albumSel)
        XCTAssertEqual(s.current, .tracks(albumID: "l.aaa", albumTitle: "Kid A", artist: "Radiohead"))
        XCTAssertEqual(action, .fetchAlbumTracks(albumID: "l.aaa", albumTitle: "Kid A", artist: "Radiohead"))
    }

    func testBackPopsToAlbumRoot() {
        var (s, _) = libraryReduce(albumsNav, .enter, itemCount: 2, selection: albumSel)
        (s, _) = libraryReduce(s, .back, itemCount: 10, selection: nil)
        XCTAssertEqual(s.current, .albumList)
    }

    func testPlayOnAlbumListEmitsAlbumPlay() {
        let (_, action) = libraryReduce(albumsNav, .play, itemCount: 2, selection: albumSel)
        XCTAssertEqual(action, .play(.album(id: "l.aaa", title: "Kid A", artist: "Radiohead")))
    }

    func testShuffleOnAlbumListEmitsAlbumShuffle() {
        let (_, action) = libraryReduce(albumsNav, .shuffle, itemCount: 2, selection: albumSel)
        XCTAssertEqual(action, .shuffle(.album(id: "l.aaa", title: "Kid A", artist: "Radiohead")))
    }

    func testArtistsEnterDrillsToArtistAlbums() {
        let s = LibraryNav.initial   // already on the Artists root
        let artistSel = LibrarySelection(id: "r.1", primary: "Radiohead", secondary: "")
        let (s2, action) = libraryReduce(s, .enter, itemCount: 3, selection: artistSel)
        XCTAssertEqual(s2.current, .artistAlbums(artistID: "r.1", artistName: "Radiohead"))
        XCTAssertEqual(action, .fetchArtistAlbums(artistID: "r.1", artistName: "Radiohead"))
    }

    func testShuffleOnArtistListEmitsArtistShuffle() {
        let s = LibraryNav.initial   // Artists root
        let artistSel = LibrarySelection(id: "r.1", primary: "Radiohead", secondary: "")
        let (_, action) = libraryReduce(s, .shuffle, itemCount: 3, selection: artistSel)
        XCTAssertEqual(action, .shuffle(.artist(id: "r.1", name: "Radiohead")))
    }

    func testSongsEnterPlaysTheSong() {
        let songSel = LibrarySelection(id: "i.s1", primary: "Idioteque", secondary: "Radiohead")
        let (_, action) = libraryReduce(songsNav, .enter, itemCount: 3, selection: songSel)
        XCTAssertEqual(action, .play(.song(id: "i.s1", title: "Idioteque", artist: "Radiohead")))
    }
}
