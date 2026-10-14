import XCTest
@testable import PianoPals

private let mutopiaFixture = """
<table class="table-bordered result-table">
<tr class="preview"><td colspan="4" align="center"><img src="https://www.mutopiaproject.org/ftp/BeethovenLv/ode/ode-preview.png" alt="Music preview image" /></td></tr>
<tr><td>Ode to Joy</td>
<td>by L. V. Beethoven (1770–1827)</td>
<td>&nbsp;</td>
<td>&nbsp;</td>
</tr><tr>
<td>for Piano</td>
<td>c. 1800</td>
<td>Hymn</td>
<td></td>
</tr><tr>
<td>Various</td>
<td><a href="../legal.html#publicdomain">Public Domain</a></td>
<td><a href="piece-info.cgi?id=528">More Information</a></td>
<td>2009/08/05</td>
</tr><tr>
<td>Download: <a href="https://www.mutopiaproject.org/ftp/BeethovenLv/ode/ode.ly">.ly file</a></td>
<td><a href="https://www.mutopiaproject.org/ftp/BeethovenLv/ode/ode.mid">.mid file</a></td>
</tr>
</table>
<table class="table-bordered result-table">
<tr><td>Ode to Joy (arr.)</td><td>by Somebody (1900–1980)</td></tr>
<tr><td>for Piano</td></tr>
<tr><td>x</td><td><a href="../legal.html#ccnc">Creative Commons Attribution-NonCommercial 4.0</a></td></tr>
<tr><td><a href="https://www.mutopiaproject.org/ftp/Somebody/arr/arr.mid">.mid file</a></td></tr>
</table>
"""

private let commonsFixture = """
{"query":{"pages":{
"1":{"pageid":1,"ns":6,"title":"File:Joy to the World (Freue dich, Welt).mid","index":1,"imageinfo":[{"size":3964,"url":"https://upload.wikimedia.org/wikipedia/commons/9/90/Joy.mid","descriptionurl":"https://commons.wikimedia.org/wiki/File:Joy.mid","extmetadata":{"Artist":{"value":"Setting by <a href=\\"//x\\">Rabanus Flavus</a>"},"LicenseShortName":{"value":"CC0"}},"mime":"audio/midi"}]},
"2":{"pageid":2,"ns":6,"title":"File:JoyToTheWorld.MID","index":2,"imageinfo":[{"size":1528,"url":"https://upload.wikimedia.org/wikipedia/commons/d/d9/JoyToTheWorld.MID","extmetadata":{"LicenseShortName":{"value":"Public domain"}},"mime":"audio/midi"}]},
"3":{"pageid":3,"ns":6,"title":"File:Joy picture.png","index":3,"imageinfo":[{"size":99,"url":"https://upload.wikimedia.org/x.png","extmetadata":{"LicenseShortName":{"value":"CC0"}},"mime":"image/png"}]},
"4":{"pageid":4,"ns":6,"title":"File:Joy NC.mid","index":4,"imageinfo":[{"size":99,"url":"https://upload.wikimedia.org/nc.mid","extmetadata":{"LicenseShortName":{"value":"CC BY-NC 4.0"}},"mime":"audio/midi"}]}
}}}
"""

/// Format-1 SMF: track 1 = melody (C5 D5 E5 … 12 quarter notes), track 2 = a bass note held for the whole piece.
private func scoreFile(melody: [UInt8] = [72, 74, 76, 77, 79, 77, 76, 74, 72, 74, 76, 72], bassHeld: Bool = true) -> Data {
    func vlq(_ value: Int) -> [UInt8] {
        var bytes = [UInt8(value & 0x7F)]
        var rest = value >> 7
        while rest > 0 { bytes.insert(UInt8(rest & 0x7F) | 0x80, at: 0); rest >>= 7 }
        return bytes
    }
    func chunk(_ events: [UInt8]) -> Data {
        var data = Data("MTrk".utf8)
        let length = events.count
        data.append(contentsOf: [UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
        data.append(contentsOf: events)
        return data
    }
    var tune: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]
    for pitch in melody {
        tune += vlq(0) + [0x90, pitch, 90] + vlq(480) + [0x80, pitch, 0]
    }
    tune += [0x00, 0xFF, 0x2F, 0x00]
    var bass: [UInt8] = vlq(0) + [0x91, 48, 70] + vlq(480 * melody.count) + [0x81, 48, 0, 0x00, 0xFF, 0x2F, 0x00]
    if !bassHeld { bass = [0x00, 0xFF, 0x2F, 0x00] }
    var data = Data("MThd".utf8)
    data.append(contentsOf: [0, 0, 0, 6, 0, 1, 0, 2, 0x01, 0xE0])
    data.append(chunk(tune))
    data.append(chunk(bass))
    return data
}

private struct StubFetcher: HTTPFetching {
    var responses: [String: Data]
    var failing: Set<String> = []
    func fetch(_ url: URL) async throws -> Data {
        for (key, value) in responses where url.absoluteString.contains(key) { return value }
        throw OnlineSearchError.badStatus(404)
    }
}

final class LicensePolicyTests: XCTestCase {
    func testOnlyOpenLicencesAreAllowed() {
        for ok in ["Public Domain", "Public domain", "CC0", "CC BY 4.0", "CC BY-SA 3.0", "Creative Commons Attribution 4.0",
                   "Creative Commons Attribution-ShareAlike 4.0", "PD-old-100", "CC-BY-SA-4.0"] {
            XCTAssertTrue(LicensePolicy.isAllowed(ok), ok)
        }
        for bad in ["", "Unknown", "All rights reserved", "CC BY-NC 4.0", "CC BY-ND 4.0", "CC BY-NC-SA 3.0", "GFDL", "Fair use",
                    "Creative Commons Attribution-NonCommercial 4.0", "Creative Commons Attribution-NoDerivatives 4.0", "Copyrighted free use"] {
            XCTAssertFalse(LicensePolicy.isAllowed(bad), bad)
        }
    }
}

final class WebSearchParsingTests: XCTestCase {
    func testMutopiaResultsGiveTitleComposerInstrumentLicenceAndMidiLink() throws {
        let found = MutopiaParser.parse(mutopiaFixture)
        XCTAssertEqual(found.count, 2)
        let ode = try XCTUnwrap(found.first)
        XCTAssertEqual(ode.title, "Ode to Joy")
        XCTAssertEqual(ode.composer, "L. V. Beethoven")
        XCTAssertEqual(ode.instrument, "Piano")
        XCTAssertEqual(ode.licence, "Public Domain")
        XCTAssertEqual(ode.midiURL.absoluteString, "https://www.mutopiaproject.org/ftp/BeethovenLv/ode/ode.mid")
        XCTAssertEqual(ode.pageURL?.absoluteString, "https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=528")
        XCTAssertEqual(found[1].licence, "Creative Commons Attribution-NonCommercial 4.0")
    }

    func testCommonsResultsKeepMidiOnlyWithSizeAndLicence() throws {
        let found = CommonsParser.parse(Data(commonsFixture.utf8))
        XCTAssertEqual(found.map(\.title), ["Joy to the World (Freue dich, Welt)", "JoyToTheWorld", "Joy NC"], "images dropped; extension trimmed; order kept")
        XCTAssertEqual(found[0].licence, "CC0")
        XCTAssertEqual(found[0].composer, "Setting by Rabanus Flavus")
        XCTAssertEqual(found[0].sizeBytes, 3964)
        XCTAssertEqual(CommonsParser.parse(Data("not json".utf8)), [])
    }

    func testGarbageHTMLGivesNothingNotACrash() {
        XCTAssertEqual(MutopiaParser.parse("<html>no results</html>"), [])
        XCTAssertEqual(MutopiaParser.parse("result-table\">"), [])
    }
}

final class WebSearchServiceTests: XCTestCase {
    private func service(_ extra: [String: Data] = [:]) -> OnlineMelodySearch {
        var responses: [String: Data] = ["mutopiaproject.org/cgibin": Data(mutopiaFixture.utf8), "commons.wikimedia.org/w/api.php": Data(commonsFixture.utf8)]
        responses.merge(extra) { $1 }
        return OnlineMelodySearch(fetcher: StubFetcher(responses: responses))
    }

    func testNonOpenLicencesNeverReachTheGrownUp() async throws {
        let found = try await service().search("ode to joy")
        XCTAssertEqual(found.first?.title, "Ode to Joy", "best title match first")
        XCTAssertFalse(found.contains { $0.title.contains("arr.") || $0.title == "Joy NC" }, "NC pieces dropped")
        XCTAssertTrue(found.allSatisfy { LicensePolicy.isAllowed($0.licence) })
        let joy = try await service().search("joy to the world")
        XCTAssertTrue(joy.allSatisfy { LicensePolicy.isAllowed($0.licence) })
        XCTAssertEqual(joy.first?.site, .commons)
        XCTAssertFalse(joy.contains { $0.title == "Joy NC" })
    }

    func testStopwordsAloneDoNotMatch() async throws {
        let found = try await service().search("the of to")
        XCTAssertTrue(found.isEmpty)
    }

    func testOneSiteDownStillReturnsTheOther() async throws {
        let only = OnlineMelodySearch(fetcher: StubFetcher(responses: ["mutopiaproject.org": Data(mutopiaFixture.utf8)]))
        let found = try await only.search("ode to joy")
        XCTAssertEqual(found.first?.site, .mutopia)
    }

    func testSearchSendsOnlyTheWords() async throws {
        final class Recorder: HTTPFetching, @unchecked Sendable {
            let lock = NSLock(); var urls: [URL] = []
            func fetch(_ url: URL) async throws -> Data { lock.lock(); urls.append(url); lock.unlock(); return Data() }
        }
        let recorder = Recorder()
        _ = try await OnlineMelodySearch(fetcher: recorder).search("Für Elise & friends")
        XCTAssertEqual(Set(recorder.urls.compactMap(\.host)), ["www.mutopiaproject.org", "commons.wikimedia.org"])
        for url in recorder.urls { XCTAssertFalse(url.absoluteString.contains("&friends"), "ampersand in the words is encoded: \(url)") }
    }

    func testDownloadRefusesBigFilesNonMidiAndClosedLicences() async throws {
        let candidate = try XCTUnwrap(MutopiaParser.parse(mutopiaFixture).first)
        let big = service([candidate.midiURL.absoluteString: Data(count: OnlineMelodySearch.maximumBytes + 1)])
        do { _ = try await big.download(candidate); XCTFail("too large") } catch { XCTAssertEqual(error as? OnlineSearchError, .tooLarge) }
        let html = service([candidate.midiURL.absoluteString: Data("<html>login</html>".utf8)])
        do { _ = try await html.download(candidate); XCTFail("not midi") } catch { XCTAssertEqual(error as? OnlineSearchError, .notMIDI) }
        let closed = try XCTUnwrap(MutopiaParser.parse(mutopiaFixture).last)
        do { _ = try await service([closed.midiURL.absoluteString: scoreFile()]).download(closed); XCTFail("closed") } catch { XCTAssertNotNil(error) }
        let declared = OnlineCandidate(site: .commons, title: "x", composer: nil, instrument: nil, licence: "CC0",
                                       midiURL: URL(string: "https://upload.wikimedia.org/a.mid")!, pageURL: nil, sizeBytes: 5_000_000)
        do { _ = try await service().download(declared); XCTFail("declared size") } catch { XCTAssertEqual(error as? OnlineSearchError, .tooLarge) }
        let good = try await service([candidate.midiURL.absoluteString: scoreFile()]).download(candidate)
        XCTAssertTrue(good.starts(with: Array("MThd".utf8)))
    }
}

final class OnlineImportTests: XCTestCase {
    private let candidate = OnlineCandidate(site: .mutopia, title: "Ode to Joy", composer: "L. V. Beethoven", instrument: "Piano",
                                            licence: "Public Domain", midiURL: URL(string: "https://example.org/a.mid")!, pageURL: nil, sizeBytes: nil)

    func testMultiTrackScoreBecomesARightHandMelodyIgnoringTheHeldBass() throws {
        let lesson = try OnlineImport.lesson(from: scoreFile(), candidate: candidate, hand: .right)
        XCTAssertEqual(lesson.title, "Ode to Joy")
        XCTAssertEqual(lesson.notes.count, 12)
        XCTAssertTrue(lesson.notes.allSatisfy { (1...5).contains($0.assignedFinger) })
        let pitches = lesson.notes.map(\.noteNumber)
        XCTAssertEqual(pitches.map { $0 - pitches[0] }, [0, 2, 4, 5, 7, 5, 4, 2, 0, 2, 4, 0], "melody intervals preserved, bass excluded")
        XCTAssertTrue(lesson.sourceDescription.contains("Mutopia Project") && lesson.sourceDescription.contains("Public Domain"), "credit kept")
    }

    func testLeftHandTakesTheBassLine() throws {
        let skyline = OnlineImport.skyline(try StandardMIDIFile.parse(scoreFile()), hand: .left)
        XCTAssertEqual(skyline.first?.pitch, 48)
    }

    func testExcerptIsCappedAndInHandRange() throws {
        let long = (0..<100).map { UInt8(60 + ($0 % 8)) }
        let lesson = try OnlineImport.lesson(from: scoreFile(melody: long), candidate: candidate, hand: .right)
        XCTAssertLessThanOrEqual(lesson.notes.count, 64)
        let left = try OnlineImport.lesson(from: scoreFile(melody: [96, 98, 100, 101, 103, 101, 100, 98], bassHeld: false), candidate: candidate, hand: .left)
        XCTAssertLessThanOrEqual(left.notes.map(\.noteNumber).max() ?? 0, 72, "register shifted into the left hand's range")
    }

    func testTooFewNotesIsAnHonestError() {
        XCTAssertThrowsError(try OnlineImport.lesson(from: scoreFile(melody: [60, 62]), candidate: candidate, hand: .right)) {
            XCTAssertEqual($0 as? OnlineSearchError, .nothingPlayable)
        }
    }

    func testOverlappingHeldNotesAreTrimmedToTheNextOnset() {
        let notes = [RawNote(pitch: 72, start: 0, duration: 4), RawNote(pitch: 74, start: 1, duration: 1)]
        XCTAssertEqual(OnlineImport.skyline(notes, hand: .right).first?.duration ?? 0, 1, accuracy: 1e-9)
    }
}

@MainActor
final class WebSearchModelTests: XCTestCase {
    func testSearchThenAddPutsALicencedLessonInTheList() async throws {
        let app = AppModel(settings: AppSettings())
        let candidate = try XCTUnwrap(MutopiaParser.parse(mutopiaFixture).first)
        app.onlineSearch = OnlineMelodySearch(fetcher: StubFetcher(responses: [
            "mutopiaproject.org/cgibin": Data(mutopiaFixture.utf8), "ode.mid": scoreFile()]))
        await app.searchWeb(for: "ode to joy")
        guard case .results(_, let found) = app.webSearch else { return XCTFail("\(app.webSearch)") }
        XCTAssertEqual(found.first, candidate)
        await app.addOnline(candidate, from: "ode to joy")
        XCTAssertEqual(app.webSearch, .idle)
        guard case .added(let message, let lesson) = app.generation else { return XCTFail("\(app.generation)") }
        XCTAssertTrue(message.contains("Public Domain") && message.contains("Mutopia"))
        XCTAssertTrue(app.songs.contains { $0.id == lesson.id })
    }

    func testNothingFoundAndOfflineAreGentle() async {
        let app = AppModel(settings: AppSettings())
        app.onlineSearch = OnlineMelodySearch(fetcher: StubFetcher(responses: [:]))
        await app.searchWeb(for: "zzzz qqqq")
        guard case .failed(let message) = app.webSearch else { return XCTFail("\(app.webSearch)") }
        let banned = ["wrong", "bad", "fail", "error", "mistake"]
        XCTAssertFalse(banned.contains { message.lowercased().contains($0) }, message)
    }
}
