import Foundation

/// A bundled public-domain song, stored as note-name notation and fingered on demand by `FingeringEngine`.
struct LibrarySong: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let title: String
    let composer: String
    let emoji: String
    let tempoBPM: Double
    let notation: String
    /// Lower-case phrases that should match this song in a text search.
    let aliases: [String]
    /// Licence / public-domain basis for the melody.
    let license: String
    /// Where the transcription came from.
    let source: String

    func lesson(hand: HandSide = .right, source: Lesson.Source = .library) -> Lesson {
        let raw = NoteNameParser.parse(notation, bpm: tempoBPM) ?? []
        return Lesson(
            id: UUID(),
            title: title,
            composer: composer,
            hand: hand,
            tempoBPM: tempoBPM,
            notes: FingeringEngine.assign(raw, hand: hand),
            source: source,
            sourceDescription: source == .library ? "Built-in song" : "Matched a built-in song",
            emoji: emoji
        )
    }
}

enum SongLibrary {
    /// Songs from the bundled `SongIndex.json` (curated + anything added by `tools/build_song_index.py`).
    static let all: [LibrarySong] = load()

    static func load(bundle: Bundle = .main) -> [LibrarySong] {
        let candidates = [bundle, Bundle(for: BundleToken.self)]
        for candidate in candidates {
            if let url = candidate.url(forResource: "SongIndex", withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let songs = try? JSONDecoder().decode([LibrarySong].self, from: data), !songs.isEmpty {
                return songs
            }
        }
        return []
    }

    /// Best match for a free-text query (title and/or composer), or nil when nothing is a convincing match.
    private final class BundleToken {}
}
