import Foundation

/// A bundled beginner song, stored as note-name notation and fingered on demand by `FingeringEngine`.
struct LibrarySong: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let composer: String
    let emoji: String
    let tempoBPM: Double
    let notation: String
    /// Lower-case phrases that should match this song in a text search.
    let aliases: [String]

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
    static let all: [LibrarySong] = [
        LibrarySong(
            id: "five-finger-walk", title: "Five Finger Walk", composer: "Warm-up", emoji: "🐛", tempoBPM: 80,
            notation: "C4 D4 E4 F4 G4 F4 E4 D4 C4:2",
            aliases: ["five finger", "warm up", "scale", "c major scale", "walk"]),
        LibrarySong(
            id: "twinkle", title: "Twinkle Twinkle", composer: "Traditional", emoji: "⭐", tempoBPM: 84,
            notation: "C4 C4 G4 G4 A4 A4 G4:2 F4 F4 E4 E4 D4 D4 C4:2",
            aliases: ["twinkle", "little star", "ah vous dirai-je", "ah vous dirai je", "alphabet song", "abc song", "mozart"]),
        LibrarySong(
            id: "mary-lamb", title: "Mary Had a Little Lamb", composer: "Traditional", emoji: "🐑", tempoBPM: 92,
            notation: "E4 D4 C4 D4 E4 E4 E4:2 D4 D4 D4:2 E4 G4 G4:2 E4 D4 C4 D4 E4 E4 E4 E4 D4 D4 E4 D4 C4:4",
            aliases: ["mary", "lamb", "little lamb"]),
        LibrarySong(
            id: "hot-cross-buns", title: "Hot Cross Buns", composer: "Traditional", emoji: "🥐", tempoBPM: 88,
            notation: "E4 D4 C4:2 E4 D4 C4:2 C4 C4 C4 C4 D4 D4 D4 D4 E4 D4 C4:2",
            aliases: ["hot cross", "buns"]),
        LibrarySong(
            id: "ode-to-joy", title: "Ode to Joy", composer: "Ludwig van Beethoven", emoji: "🎉", tempoBPM: 96,
            notation: "E4 E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 E4:1.5 D4:0.5 D4:2",
            aliases: ["ode", "joy", "beethoven", "ninth symphony", "9th symphony"]),
        LibrarySong(
            id: "jingle-bells", title: "Jingle Bells", composer: "James Lord Pierpont", emoji: "🔔", tempoBPM: 100,
            notation: "E4 E4 E4:2 E4 E4 E4:2 E4 G4 C4:1.5 D4:0.5 E4:4",
            aliases: ["jingle", "bells", "pierpont", "christmas"]),
        LibrarySong(
            id: "row-boat", title: "Row Your Boat", composer: "Traditional", emoji: "🚣", tempoBPM: 100,
            notation: "C4 C4 C4:0.75 D4:0.25 E4 E4:0.75 D4:0.25 E4:0.75 F4:0.25 G4:2",
            aliases: ["row row", "row your boat", "boat", "gently down the stream"])
    ]

    /// Best match for a free-text query (title and/or composer), or nil.
    static func match(title: String, composer: String? = nil, in songs: [LibrarySong] = all) -> LibrarySong? {
        let haystack = normalize([title, composer ?? ""].joined(separator: " "))
        guard !haystack.isEmpty else { return nil }
        var best: (song: LibrarySong, score: Int)?
        for song in songs {
            var score = 0
            let songTitle = normalize(song.title)
            if haystack.contains(songTitle) { score += 10 }
            for alias in song.aliases where haystack.contains(normalize(alias)) {
                score += 4 + alias.count / 4
            }
            if score > 0, score > (best?.score ?? 0) { best = (song, score) }
        }
        return best?.song
    }

    static func normalize(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let cleaned = text.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }
}
