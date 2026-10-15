import Foundation

// MARK: - Catalogue entries (what the grown-up picks from: "is this the song?")

/// A song as the free public catalogues know it. Only the words, never audio, are used to find it.
struct CatalogSong: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let artist: String
    var album: String?
    var year: Int?
    var artworkURL: URL?
    /// Apple's 30 second sample: for the grown-up to play and confirm the song. It is never analysed.
    var previewURL: URL?
    /// The song's page in Apple Music / the iTunes Store, where the full song can be heard.
    var trackViewURL: URL?

    /// Opens a web search for the song on YouTube (a link, nothing is downloaded or analysed by the app).
    var youTubeSearchURL: URL? { Self.webURL("https://www.youtube.com/results", query: "\(title) \(artist)") }
    /// Opens a web search for piano chords of the song. Chord sheets are copyrighted and their sites do not allow copying, so the app only links.
    var chordSearchURL: URL? { Self.webURL("https://duckduckgo.com/", query: "\(title) \(artist) piano chords") }

    private static func webURL(_ base: String, query: String) -> URL? {
        var components = URLComponents(string: base)
        components?.queryItems = [URLQueryItem(name: base.contains("youtube") ? "search_query" : "q", value: query)]
        return components?.url
    }
}

enum CatalogParser {
    /// Apple's iTunes Search API (`media=music&entity=song`).
    static func iTunes(_ data: Data) -> [CatalogSong] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let results = root["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { item in
            guard let title = item["trackName"] as? String, let artist = item["artistName"] as? String else { return nil }
            let id = (item["trackId"] as? Int).map { "itunes-\($0)" } ?? "itunes-\(title)-\(artist)"
            let year = (item["releaseDate"] as? String).flatMap { Int($0.prefix(4)) }
            return CatalogSong(id: id, title: title, artist: artist, album: item["collectionName"] as? String, year: year,
                               artworkURL: (item["artworkUrl100"] as? String).flatMap(URL.init(string:)),
                               previewURL: (item["previewUrl"] as? String).flatMap(URL.init(string:)),
                               trackViewURL: (item["trackViewUrl"] as? String).flatMap(URL.init(string:)))
        }
    }

    /// MusicBrainz recordings (`/ws/2/recording?fmt=json`): open data, good at naming the right artist and year.
    static func musicBrainz(_ data: Data) -> [CatalogSong] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let recordings = root["recordings"] as? [[String: Any]] else { return [] }
        return recordings.compactMap { item in
            guard let title = item["title"] as? String, (item["score"] as? Int ?? 100) >= 80,
                  let artist = ((item["artist-credit"] as? [[String: Any]])?.first?["name"] as? String) else { return nil }
            let year = (item["first-release-date"] as? String).flatMap { Int($0.prefix(4)) }
            return CatalogSong(id: "mb-\(item["id"] as? String ?? title)", title: title, artist: artist, year: year)
        }
    }

    /// One list, best source first (Apple's entries carry artwork and a preview), the same song never twice.
    static func merge(_ lists: [[CatalogSong]], limit: Int) -> [CatalogSong] {
        var seen = Set<String>()
        var merged: [CatalogSong] = []
        for song in lists.joined() {
            let key = SongMatcher.normalize(song.title) + "|" + SongMatcher.normalize(song.artist)
            if seen.insert(key).inserted { merged.append(song) }
        }
        return Array(merged.prefix(limit))
    }
}

// MARK: - Search with visible steps

enum SearchStep: String, CaseIterable, Sendable {
    case yourSongs, freeLibrary, catalogue, openFiles

    var label: String {
        switch self {
        case .yourSongs: return "Your songs"
        case .freeLibrary: return "Free song library"
        case .catalogue: return "Song catalogue (Apple, MusicBrainz)"
        case .openFiles: return "Free open files (Mutopia, Wikimedia)"
        }
    }
}

enum StepState: Equatable, Sendable {
    case waiting
    case working
    case done(Int)
    case failed
}

struct SongSearchResults: Equatable, Sendable {
    var yours: [Lesson] = []
    var library: [LibrarySong] = []
    var catalogue: [CatalogSong] = []
    var files: [OnlineCandidate] = []
    var steps: [SearchStep: StepState] = [:]

    var isEmpty: Bool { yours.isEmpty && library.isEmpty && catalogue.isEmpty && files.isEmpty }
}

/// Looks in your songs and the bundled library first (instant, offline), then asks the free catalogues and the open-file sites at
/// the same time. A site that is down only fails its own step.
struct SongSearcher: Sendable {
    static let catalogueSites = "Apple's iTunes Search and MusicBrainz"

    var fetcher: HTTPFetching = URLSessionFetcher()
    var online: OnlineMelodySearching = OnlineMelodySearch()
    var library: [LibrarySong] = SongLibrary.all
    var titleFetcher: VideoTitleFetching = YouTubeOEmbedFetcher()
    var catalogueLimit = 8

    enum Resolved: Equatable, Sendable {
        case words(String, from: String?)
        case unreadable
    }

    /// A pasted YouTube link becomes the video's title (only the title is read), a music-share link its title and artist; anything else is
    /// searched as typed. `.unreadable` when a YouTube link's title can't be fetched.
    func resolve(_ text: String) async -> Resolved {
        switch LessonInputClassifier.classify(text) {
        case .youTube(let id)?:
            guard let metadata = try? await titleFetcher.metadata(forVideoID: id) else { return .unreadable }
            return .words(TitleNormalizer.candidates(from: metadata.title).first ?? metadata.title, from: metadata.title)
        case .musicShare(let title, let artist, _)?:
            return .words([title, artist ?? ""].joined(separator: " ").trimmingCharacters(in: .whitespaces), from: title)
        default:
            return .words(text, from: nil)
        }
    }

    func search(_ query: String, songs: [Lesson], progress: @escaping @Sendable (SearchStep, StepState) -> Void = { _, _ in }) async -> SongSearchResults {
        let words = SongMatcher.tokens(query).joined(separator: " ")
        var results = SongSearchResults()
        guard !words.isEmpty else { return results }
        for step in SearchStep.allCases { results.steps[step] = .waiting; progress(step, .waiting) }

        func finish(_ step: SearchStep, _ state: StepState) { results.steps[step] = state; progress(step, state) }

        progress(.yourSongs, .working)
        let wanted = Set(SongMatcher.tokens(query)).subtracting(SongMatcher.stopwords)
        results.yours = songs.filter { lesson in
            let have = Set(SongMatcher.tokens(lesson.title + " " + (lesson.composer ?? "")))
            return !wanted.isEmpty && wanted.isSubset(of: have)
        }
        finish(.yourSongs, .done(results.yours.count))

        progress(.freeLibrary, .working)
        results.library = SongMatcher.rank(query: query, in: library).prefix(3).map(\.song)
        finish(.freeLibrary, .done(results.library.count))

        progress(.catalogue, .working)
        progress(.openFiles, .working)
        async let catalogue = lookUpCatalogue(words)
        async let files = lookUpFiles(query)
        let found = await catalogue
        finish(.catalogue, found.map { .done($0.count) } ?? .failed)
        results.catalogue = found ?? []
        let open = await files
        finish(.openFiles, open.map { .done($0.count) } ?? .failed)
        results.files = open ?? []
        return results
    }

    /// nil when neither catalogue could be reached.
    private func lookUpCatalogue(_ words: String) async -> [CatalogSong]? {
        let encoded = words.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? words
        guard let apple = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=song&limit=\(catalogueLimit)"),
              let brainz = URL(string: "https://musicbrainz.org/ws/2/recording?query=\(encoded)&fmt=json&limit=\(catalogueLimit)") else { return nil }
        async let appleData = try? fetcher.fetch(apple)
        async let brainzData = try? fetcher.fetch(brainz)
        let (a, b) = await (appleData, brainzData)
        if a == nil && b == nil { return nil }
        return CatalogParser.merge([a.map(CatalogParser.iTunes) ?? [], b.map(CatalogParser.musicBrainz) ?? []], limit: catalogueLimit)
    }

    private func lookUpFiles(_ query: String) async -> [OnlineCandidate]? { try? await online.search(query) }
}

// MARK: - What can we really do for the song the grown-up picked?

struct SongOptions: Equatable, Sendable {
    /// A free-library song that is this song, if there is one.
    var library: LibrarySong?
    /// Open-licence files whose title shares a word with the song.
    var files: [OnlineCandidate]
    /// True when no free notes exist: modern songs are copyrighted, so only the grown-up's own recording, playing it, or a practice tune remain.
    var needsOwnSource: Bool { library == nil && files.isEmpty }

    static func make(for song: CatalogSong, library: [LibrarySong], files: [OnlineCandidate]) -> SongOptions {
        let match = SongMatcher.bestMatch(query: song.title + " " + song.artist, in: library)?.song
        let titleWords = Set(SongMatcher.tokens(song.title)).subtracting(SongMatcher.stopwords)
        let related = files.filter { !titleWords.isDisjoint(with: Set(SongMatcher.tokens($0.title)).subtracting(SongMatcher.stopwords)) }
        return SongOptions(library: match, files: Array(related.prefix(3)))
    }
}
