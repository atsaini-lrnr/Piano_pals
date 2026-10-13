import XCTest
@testable import PianoPals

final class SongIndexTests: XCTestCase {
    private let songs = SongLibrary.all

    // MARK: M5 — index quality

    func testIndexIsBundledAndLarge() {
        XCTAssertGreaterThanOrEqual(songs.count, 18)
        XCTAssertEqual(Set(songs.map(\.id)).count, songs.count, "ids are unique")
    }

    func testEverySongIsValidLicencedAndFingered() {
        for song in songs {
            XCTAssertFalse(song.license.isEmpty, "\(song.id) needs a licence")
            XCTAssertFalse(song.source.isEmpty, "\(song.id) needs a source")
            XCTAssertNotNil(NoteNameParser.parse(song.notation, bpm: song.tempoBPM), "\(song.id) notation parses")
            let lesson = song.lesson()
            XCTAssertGreaterThanOrEqual(lesson.notes.count, 8, song.id)
            XCTAssertTrue(lesson.notes.allSatisfy { (21...108).contains($0.noteNumber) }, song.id)
            XCTAssertTrue(lesson.notes.allSatisfy { (1...5).contains($0.assignedFinger) }, song.id)
            XCTAssertTrue(lesson.duration > 0, song.id)
            // Kid-friendly: a melody spanning more than an octave and a half is too big for a first lesson.
            let span = (lesson.highestNote ?? 0) - (lesson.lowestNote ?? 0)
            XCTAssertLessThanOrEqual(span, 19, "\(song.id) range")
        }
    }

    // MARK: M3 — matching accuracy

    private func swapAdjacent(in title: String) -> String? {
        var words = title.split(separator: " ").map(String.init)
        guard let index = words.indices.max(by: { words[$0].count < words[$1].count }), words[index].count >= 6 else { return nil }
        var chars = Array(words[index])
        let mid = chars.count / 2
        chars.swapAt(mid, mid + 1)
        words[index] = String(chars)
        return words.joined(separator: " ")
    }

    func testMatchingAccuracyOverManyQueryVariants() {
        var total = 0
        var correct = 0
        var failures: [String] = []
        func check(_ query: String, expects id: String) {
            total += 1
            if SongMatcher.bestMatch(query: query, in: songs)?.song.id == id { correct += 1 } else { failures.append("\(query) → \(id)") }
        }
        for song in songs {
            let title = song.title.replacingOccurrences(of: " (opening)", with: "")
            check(title, expects: song.id)
            check(title.lowercased(), expects: song.id)
            check("\(title) (Official Video)", expects: song.id)
            check("\(title) | Easy Piano Tutorial", expects: song.id)
            check("Piano Tutorial: \(title) with lyrics [HD]", expects: song.id)
            if song.composer != "Traditional", !song.composer.hasPrefix("Traditional"), song.composer != "Warm-up" {
                check("\(title) by \(song.composer)", expects: song.id)
            }
            if let typo = swapAdjacent(in: title) { check(typo, expects: song.id) }
            if let alias = song.aliases.first(where: { SongMatcher.tokens($0).count >= 2 }) { check(alias, expects: song.id) }
        }
        // Hand-picked real-world phrasing.
        check("twinkle twinkle little star nursery rhyme", expects: "twinkle")
        check("Mozart", expects: "twinkle")
        check("old mcdonald had a farm", expects: "old-macdonald")
        check("Ode an die Freude Beethoven 9th symphony", expects: "ode-to-joy")
        check("fur elise beethoven", expects: "fur-elise")
        check("brother john", expects: "frere-jacques")
        check("are you sleeping", expects: "frere-jacques")
        check("the alphabet song", expects: "twinkle")
        check("row row row your boat", expects: "row-boat")
        check("merrily we roll along", expects: "mary-lamb")
        check("deck the halls with boughs of holly", expects: "deck-the-halls")
        check("joy to the world the lord is come", expects: "joy-to-the-world")
        XCTAssertGreaterThanOrEqual(total, 60, "need a meaningful sample")
        let accuracy = Double(correct) / Double(total)
        XCTAssertGreaterThanOrEqual(accuracy, 0.95, "accuracy \(accuracy) failures: \(failures)")
    }

    // MARK: M4 — no false matches

    func testUnknownTitlesNeverMatch() {
        let unknown = [
            "Bohemian Rhapsody", "Shape of You", "Let It Go", "Happy Birthday to You", "Baby Shark", "Despacito", "Imagine",
            "Yesterday", "Hello Adele", "Thunderstruck", "Smells Like Teen Spirit", "Old Town Road", "Wedding Bells",
            "Jingle Bell Rock", "Lightly Toasted", "Mary Poppins Supercalifornia", "Row Row Fight the Power", "Hot Dog Song",
            "Joy Division Love Will Tear Us Apart", "Deck Out My Room", "Frozen Do You Want to Build a Snowman",
            "Bad Guy Billie Eilish", "Moonlight Sonata", "Canon in D", "Blinding Lights", "The Lion Sleeps Tonight"
        ]
        XCTAssertGreaterThanOrEqual(unknown.count, 20)
        for title in unknown {
            XCTAssertNil(SongMatcher.bestMatch(query: title, in: songs), "'\(title)' must not match anything")
            XCTAssertNil(SongMatcher.bestMatch(query: "\(title) (Official Video)", in: songs), "'\(title)' with noise")
        }
    }

    func testStopwordsAndGibberishNeverMatch() {
        for query in ["the", "a the of", "song", "!!!", "", "   ", "zzzzzz", "qwerty asdf"] {
            XCTAssertNil(SongMatcher.bestMatch(query: query, in: songs), query)
        }
    }

    func testAmbiguousSingleWordsReturnNilButSuggestBoth() {
        XCTAssertNil(SongMatcher.bestMatch(query: "joy", in: songs), "'joy' is in two titles")
        let ids = Set(SongMatcher.rank(query: "joy", in: songs).map(\.song.id))
        XCTAssertTrue(ids.isSuperset(of: ["ode-to-joy", "joy-to-the-world"]))
    }

    func testTitleNormalizerStripsNoise() {
        let candidates = TitleNormalizer.candidates(from: "Twinkle Twinkle Little Star - Nursery Rhyme with Lyrics | Kids Songs [HD]")
        XCTAssertTrue(candidates.contains("twinkle twinkle little star"), "\(candidates)")
        XCTAssertEqual(TitleNormalizer.stripNoise("Easy Piano Tutorial Ode to Joy Official Video"), "ode to joy")
        XCTAssertEqual(TitleNormalizer.stripBrackets("Für Elise (opening) [x]").split(separator: " ").joined(separator: " "), "Für Elise")
        XCTAssertTrue(TitleNormalizer.candidates(from: "").isEmpty)
    }

    func testLevenshtein() {
        XCTAssertEqual(SongMatcher.levenshtein(Array("kitten"), Array("sitting")), 3)
        XCTAssertEqual(SongMatcher.levenshtein(Array("finger"), Array("finegr")), 1, "swapping neighbours is one typo")
        XCTAssertEqual(SongMatcher.levenshtein([], Array("abc")), 3)
        XCTAssertEqual(SongMatcher.similarity("twinkel", "twinkle"), 1 - 1.0 / 7, accuracy: 1e-9)
        XCTAssertEqual(SongMatcher.similarity("to", "go"), 0, "short words must match exactly")
    }
}
