import Foundation

struct SongMatch: Equatable, Sendable {
    let song: LibrarySong
    /// 0…1. ≥ `SongMatcher.acceptThreshold` counts as a confident match.
    let score: Double
}

/// Offline fuzzy search over the bundled song index. Designed to be strict: a wrong song shown to a child is worse than
/// a "couldn't find it" screen with suggestions, so extra unexplained words in the query reduce the score.
enum SongMatcher {
    static let acceptThreshold = 0.62
    static let suggestionThreshold = 0.30
    /// Words that carry no identity ("the", "by", …).
    static let stopwords: Set<String> = ["the", "a", "an", "by", "of", "and", "in", "on", "to", "my", "for", "with", "from", "is", "at", "had"]

    // MARK: Normalisation

    static func normalize(_ text: String) -> String { tokens(text).joined(separator: " ") }

    static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let mapped = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(mapped).split(separator: " ").map(String.init)
    }

    // MARK: Search

    /// Every song with a non-trivial score, best first. The query is cleaned of YouTube-style noise first.
    static func rank(query: String, in songs: [LibrarySong]) -> [SongMatch] {
        let candidates = [query] + TitleNormalizer.candidates(from: query)
        return songs.compactMap { song -> SongMatch? in
            let best = candidates.map { score(candidate: $0, song: song) }.max() ?? 0
            return best >= suggestionThreshold ? SongMatch(song: song, score: best) : nil
        }
        .sorted { ($0.score, $1.song.title) > ($1.score, $0.song.title) }
    }

    /// The single confident match, or nil when nothing convinces or the top two are indistinguishable.
    static func bestMatch(query: String, in songs: [LibrarySong]) -> SongMatch? {
        let ranked = rank(query: query, in: songs)
        guard let top = ranked.first, top.score >= acceptThreshold else { return nil }
        if ranked.count > 1, top.score < 0.9, abs(ranked[1].score - top.score) < 0.02 { return nil }
        return top
    }

    // MARK: Scoring

    static func score(candidate: String, song: LibrarySong) -> Double {
        let query = tokens(candidate)
        let distinctive = query.filter { !stopwords.contains($0) }
        guard !distinctive.isEmpty else { return 0 }

        let titleTokens = tokens(TitleNormalizer.stripBrackets(song.title))
        let titleDistinctive = titleTokens.filter { !stopwords.contains($0) }
        let composerTokens = Set(tokens(song.composer).filter { $0.count >= 4 && $0 != "traditional" })
        let glue: Set<String> = ["by", "composer", "composed"]

        /// Every word that is part of this song's identity (title or any alias) is never counted as an extra.
        let known = Set(titleTokens).union(song.aliases.flatMap { tokens($0) })

        /// Query words that explain nothing about the song count against it. Exact phrase evidence tolerates a couple of
        /// extra words (lyrics, "official"…); approximate (typo) evidence tolerates fewer.
        func penalty(explained: Set<String>, perExtra: Double) -> Double {
            let extras = distinctive.filter { !explained.contains($0) && !known.contains($0) && !composerTokens.contains($0) && !glue.contains($0) }
            return perExtra * Double(extras.count)
        }

        var best = 0.0

        if query == titleTokens { best = 1.0 }

        if contains(query, sub: titleTokens) {
            best = max(best, 0.96 - penalty(explained: Set(titleTokens), perExtra: 0.12))
        }
        if distinctive.count >= 2, contains(titleTokens, sub: query) {
            best = max(best, 0.9)
        } else if distinctive.count == 1, let word = distinctive.first, word.count >= 3, titleDistinctive.contains(word) {
            best = max(best, 0.7)
        }

        for alias in song.aliases {
            let aliasTokens = tokens(alias)
            let aliasDistinctive = aliasTokens.filter { !stopwords.contains($0) }
            guard !aliasDistinctive.isEmpty else { continue }
            if aliasTokens.count >= 2 {
                if contains(query, sub: aliasTokens) { best = max(best, 0.88 - penalty(explained: Set(aliasTokens), perExtra: 0.15)) }
            } else if distinctive.filter({ !composerTokens.contains($0) }) == aliasTokens {
                best = max(best, 0.8)
            } else if distinctive.contains(aliasTokens[0]) {
                best = max(best, 0.4)
            }
        }

        // Typo-tolerant: every distinctive title word must be found (approximately) in the query.
        if !titleDistinctive.isEmpty {
            var sims: [Double] = []
            var explained = Set<String>()
            for word in titleDistinctive {
                let match = distinctive.map { (token: $0, sim: similarity(word, $0)) }.max { $0.sim < $1.sim }
                if let match, match.sim >= 0.75 { sims.append(match.sim); explained.insert(match.token) }
            }
            if sims.count == titleDistinctive.count {
                let base = 0.9 * sims.reduce(0, +) / Double(sims.count)
                best = max(best, base - penalty(explained: explained, perExtra: 0.25))
            }
        }

        // Composer-only queries are suggestions, never confident matches.
        if !composerTokens.isEmpty, distinctive.allSatisfy({ composerTokens.contains($0) || glue.contains($0) }) {
            best = max(best, 0.5)
        }
        return min(max(best, 0), 1)
    }

    // MARK: Helpers

    /// True when `sub` appears as a contiguous run inside `array`.
    private static func contains(_ array: [String], sub: [String]) -> Bool {
        guard !sub.isEmpty, array.count >= sub.count else { return false }
        for start in 0...(array.count - sub.count) where Array(array[start..<start + sub.count]) == sub { return true }
        return false
    }

    /// 1 − normalised Levenshtein distance. Short words must match exactly.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let length = max(a.count, b.count)
        guard length > 3 else { return 0 }
        return 1 - Double(levenshtein(Array(a), Array(b))) / Double(length)
    }

    /// Optimal-string-alignment distance: insert / delete / substitute / swap-neighbours each cost 1.
    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[a.count][b.count]
    }
}
