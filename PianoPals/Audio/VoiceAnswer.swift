import Foundation

/// What a child said (or did) at the end of a song.
enum VoiceAnswer: Equatable, Sendable {
    case again
    case next

    private static let againWords: Set<String> = ["again", "repeat", "replay", "same", "retry", "encore", "yes", "yeah", "yep"]
    private static let nextWords: Set<String> = ["new", "next", "another", "different", "more", "song", "songs", "skip", "no", "nope"]

    /// Reads words from speech recognition. "again" wins when both kinds are heard ("play it again"), because the question offers it first.
    static func parse(_ text: String) -> VoiceAnswer? {
        let words = Set(SongMatcher.tokens(text))
        if !words.isDisjoint(with: againWords) { return .again }
        if !words.isDisjoint(with: nextWords) { return .next }
        return nil
    }
}
