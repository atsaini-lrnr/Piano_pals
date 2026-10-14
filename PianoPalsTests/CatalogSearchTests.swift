import XCTest
@testable import PianoPals

private let appleFixture = """
{"resultCount":3,"results":[
{"wrapperType":"track","kind":"song","trackId":1,"artistName":"Adele","trackName":"When We Were Young","collectionName":"25","artworkUrl100":"https://is1-ssl.mzstatic.com/a.jpg","previewUrl":"https://audio-ssl.itunes.apple.com/p1.m4a","releaseDate":"2015-11-20T08:00:00Z"},
{"wrapperType":"track","kind":"song","trackId":2,"artistName":"The Killers","trackName":"When You Were Young","collectionName":"Sam's Town","artworkUrl100":"https://is1-ssl.mzstatic.com/b.jpg","previewUrl":"https://audio-ssl.itunes.apple.com/p2.m4a","releaseDate":"2006-01-01T08:00:00Z"},
{"wrapperType":"collection","collectionName":"no track name here"}
]}
"""

private let brainzFixture = """
{"recordings":[
{"id":"r1","score":100,"title":"When We Were Young","artist-credit":[{"name":"Adele"}],"first-release-date":"2015-10-23"},
{"id":"r2","score":100,"title":"When We Were Young","artist-credit":[{"name":"Human Nature"}],"first-release-date":"1998"},
{"id":"r3","score":40,"title":"Weak match","artist-credit":[{"name":"Nobody"}]},
{"id":"r4","score":95,"title":"No artist"}
]}
"""

private struct StubFetcher: HTTPFetching {
    var apple: Data? = Data(appleFixture.utf8)
    var brainz: Data? = Data(brainzFixture.utf8)
    func fetch(_ url: URL) async throws -> Data {
        if url.host == "itunes.apple.com", let apple { return apple }
        if url.host == "musicbrainz.org", let brainz { return brainz }
        throw OnlineSearchError.badStatus(503)
    }
}

private struct StubOnline: OnlineMelodySearching {
    var files: [OnlineCandidate] = []
    var fails = false
    func search(_ query: String) async throws -> [OnlineCandidate] { if fails { throw OnlineSearchError.badStatus(500) }; return files }
    func download(_ candidate: OnlineCandidate) async throws -> Data { Data() }
}

private func file(_ title: String, licence: String = "Public Domain") -> OnlineCandidate {
    OnlineCandidate(site: .mutopia, title: title, composer: "Someone", instrument: "Piano", licence: licence,
                    midiURL: URL(string: "https://example.org/\(title.hashValue).mid")!, pageURL: nil, sizeBytes: nil)
}

final class CatalogParserTests: XCTestCase {
    func testAppleResultsKeepTitleArtistYearArtworkAndPreview() throws {
        let found = CatalogParser.iTunes(Data(appleFixture.utf8))
        XCTAssertEqual(found.map(\.title), ["When We Were Young", "When You Were Young"], "the non-song row is dropped")
        let adele = try XCTUnwrap(found.first)
        XCTAssertEqual(adele.artist, "Adele")
        XCTAssertEqual(adele.album, "25")
        XCTAssertEqual(adele.year, 2015)
        XCTAssertEqual(adele.previewURL?.absoluteString, "https://audio-ssl.itunes.apple.com/p1.m4a")
        XCTAssertNotNil(adele.artworkURL)
        XCTAssertEqual(CatalogParser.iTunes(Data("nope".utf8)), [])
    }

    func testMusicBrainzDropsWeakMatchesAndEntriesWithoutAnArtist() {
        let found = CatalogParser.musicBrainz(Data(brainzFixture.utf8))
        XCTAssertEqual(found.map(\.artist), ["Adele", "Human Nature"])
        XCTAssertEqual(found.map(\.year), [2015, 1998])
        XCTAssertEqual(CatalogParser.musicBrainz(Data("{}".utf8)), [])
    }

    func testMergeKeepsApplesRichEntryAndNeverListsASongTwice() {
        let merged = CatalogParser.merge([CatalogParser.iTunes(Data(appleFixture.utf8)), CatalogParser.musicBrainz(Data(brainzFixture.utf8))], limit: 8)
        XCTAssertEqual(merged.map(\.artist), ["Adele", "The Killers", "Human Nature"])
        XCTAssertNotNil(merged[0].previewURL, "Apple's entry wins over MusicBrainz's duplicate")
        XCTAssertEqual(CatalogParser.merge([CatalogParser.iTunes(Data(appleFixture.utf8))], limit: 1).count, 1)
    }
}

final class SongSearcherTests: XCTestCase {
    private func searcher(fetcher: StubFetcher = StubFetcher(), online: StubOnline = StubOnline()) -> SongSearcher {
        SongSearcher(fetcher: fetcher, online: online)
    }

    func testAllFourStepsRunAndReportInOrder() async {
        let log = Locked<[String]>([])
        let results = await searcher(online: StubOnline(files: [file("Ode to Joy")])).search("when we were young", songs: []) { step, state in
            log.withLock { $0.append("\(step.rawValue):\(state)") }
        }
        XCTAssertEqual(results.catalogue.count, 3)
        XCTAssertEqual(results.files.count, 1)
        for step in SearchStep.allCases { XCTAssertNotEqual(results.steps[step], .waiting); XCTAssertNotEqual(results.steps[step], .working) }
        let order = log.current
        XCTAssertLessThan(order.firstIndex(of: "yourSongs:done(0)") ?? 99, order.firstIndex(of: "freeLibrary:done(0)") ?? -1, "local steps come first: \(order)")
        XCTAssertTrue(order.contains("catalogue:working") && order.contains("openFiles:working"))
    }

    func testYourSongsAndTheFreeLibraryAreSearchedOffline() async {
        let mine = SongLibrary.all.first { $0.title.contains("Twinkle") }!.lesson()
        let results = await searcher(fetcher: StubFetcher(apple: nil, brainz: nil), online: StubOnline(fails: true)).search("twinkle twinkle", songs: [mine])
        XCTAssertEqual(results.yours.map(\.title), [mine.title])
        XCTAssertEqual(results.library.first?.title, mine.title)
        XCTAssertEqual(results.steps[.catalogue], .failed)
        XCTAssertEqual(results.steps[.openFiles], .failed)
        XCTAssertEqual(results.steps[.freeLibrary], .done(results.library.count), "a site being down never stops the offline steps")
    }

    func testOneCatalogueDownStillGivesTheOther() async {
        let results = await searcher(fetcher: StubFetcher(apple: nil)).search("when we were young", songs: [])
        XCTAssertEqual(results.catalogue.map(\.artist), ["Adele", "Human Nature"])
        XCTAssertEqual(results.steps[.catalogue], .done(2))
    }

    func testEmptyOrSymbolOnlyQueriesDoNothing() async {
        let results = await searcher().search("  ?!  ", songs: [])
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(results.steps.isEmpty)
    }

    func testOnlyTheWordsAreSentAndSpecialCharactersAreEncoded() async {
        final class Recorder: HTTPFetching, @unchecked Sendable {
            let lock = NSLock(); var urls: [URL] = []
            func fetch(_ url: URL) async throws -> Data { lock.lock(); urls.append(url); lock.unlock(); return Data() }
        }
        let recorder = Recorder()
        _ = await SongSearcher(fetcher: recorder, online: StubOnline()).search("Für Elise & friends/../x", songs: [])
        XCTAssertEqual(Set(recorder.urls.compactMap(\.host)), ["itunes.apple.com", "musicbrainz.org"])
        for url in recorder.urls {
            XCTAssertFalse(url.absoluteString.contains("&friends"), "\(url)")
            XCTAssertFalse(url.absoluteString.contains("/../"), "\(url)")
            XCTAssertTrue(url.absoluteString.contains("fur%20elise"), "accents folded, spaces encoded: \(url)")
        }
    }
}

final class SongOptionsTests: XCTestCase {
    func testACopyrightedSongOffersNoFreeNotes() {
        let adele = CatalogSong(id: "1", title: "When We Were Young", artist: "Adele")
        let options = SongOptions.make(for: adele, library: SongLibrary.all, files: [file("Ode to Joy")])
        XCTAssertNil(options.library)
        XCTAssertTrue(options.files.isEmpty)
        XCTAssertTrue(options.needsOwnSource)
    }

    func testAPublicDomainSongFindsTheLibraryEntryAndRelatedOpenFiles() {
        let ode = CatalogSong(id: "2", title: "Ode to Joy", artist: "Beethoven")
        let options = SongOptions.make(for: ode, library: SongLibrary.all, files: [file("Ode to Joy (arr.)"), file("Fur Elise")])
        XCTAssertEqual(options.library?.title, "Ode to Joy")
        XCTAssertEqual(options.files.map(\.title), ["Ode to Joy (arr.)"], "only files that share a title word")
        XCTAssertFalse(options.needsOwnSource)
    }

    func testAnArtistWordAloneDoesNotPullInAFile() {
        let song = CatalogSong(id: "3", title: "Hello", artist: "Adele")
        XCTAssertTrue(SongOptions.make(for: song, library: [], files: [file("Adele tribute")]).files.isEmpty)
    }
}

@MainActor
final class SongSearchModelTests: XCTestCase {
    func testSearchThenChooseShowsTheRealOptions() async throws {
        let app = AppModel(settings: AppSettings())
        app.songSearcher = SongSearcher(fetcher: StubFetcher(), online: StubOnline())
        await app.searchSongs("when we were young")
        XCTAssertFalse(app.songSearch.running)
        let results = try XCTUnwrap(app.songSearch.results)
        XCTAssertEqual(results.catalogue.first?.artist, "Adele")
        app.chooseCatalogSong(results.catalogue.first)
        XCTAssertEqual(app.songSearch.chosen?.artist, "Adele")
        XCTAssertEqual(app.songSearch.options?.needsOwnSource, true)
        app.clearSongSearch()
        XCTAssertNil(app.songSearch.results)
    }

    func testBlankSearchIsIgnored() async {
        let app = AppModel(settings: AppSettings())
        await app.searchSongs("   ")
        XCTAssertNil(app.songSearch.results)
    }
}
