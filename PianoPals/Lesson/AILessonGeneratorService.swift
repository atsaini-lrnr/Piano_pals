import Foundation

// MARK: - Input classification

enum LessonInputKind: Equatable, Sendable {
    case youTube(videoID: String)
    case musicShare(title: String, artist: String?, url: URL?)
    case titleSearch(title: String, composer: String?)
    case rawNotes([RawNote])

    var wireName: String {
        switch self {
        case .youTube: return "youtube"
        case .musicShare: return "music_share"
        case .titleSearch: return "title_search"
        case .rawNotes: return "raw_notes"
        }
    }
}

/// Turns whatever a grown-up typed or pasted into a structured request.
enum LessonInputClassifier {
    static func classify(_ rawText: String) -> LessonInputKind? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let id = youTubeVideoID(in: text) { return .youTube(videoID: id) }

        if NoteNameParser.looksLikeNotation(text), let notes = NoteNameParser.parse(text) {
            return .rawNotes(notes)
        }

        let url = firstURL(in: text)
        let withoutURL = url.map { text.replacingOccurrences(of: $0.absoluteString, with: " ") } ?? text
        let cleaned = withoutURL
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let host = url?.host?.lowercased(), isMusicShareHost(host) {
            let (title, artist) = splitTitleAndArtist(cleaned)
            return .musicShare(title: title, artist: artist, url: url)
        }

        let (title, composer) = splitTitleAndArtist(cleaned)
        return .titleSearch(title: title, composer: composer)
    }

    static func youTubeVideoID(in text: String) -> String? {
        guard let url = firstURL(in: text), let host = url.host?.lowercased() else { return nil }
        let isYouTube = host == "youtu.be" || host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com")
        guard isYouTube else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if host == "youtu.be" { return parts.first.flatMap(validVideoID) }
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let value = query.first(where: { $0.name == "v" })?.value {
            return validVideoID(value)
        }
        if let marker = parts.firstIndex(where: { ["embed", "shorts", "live", "v"].contains($0) }), marker + 1 < parts.count {
            return validVideoID(parts[marker + 1])
        }
        return nil
    }

    private static func validVideoID(_ candidate: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard candidate.count == 11, candidate.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return candidate
    }

    private static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.url
    }

    private static func isMusicShareHost(_ host: String) -> Bool {
        ["music.apple.com", "itunes.apple.com", "open.spotify.com", "spotify.link", "music.youtube.com", "deezer.com", "tidal.com"]
            .contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// "Title by Artist", "Title - Artist", "Title, Artist" or just "Title".
    static func splitTitleAndArtist(_ text: String) -> (title: String, artist: String?) {
        var working = text.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\"'"))
        for prefix in ["Check out ", "Listen to ", "Listening to "] where working.hasPrefix(prefix) {
            working = String(working.dropFirst(prefix.count))
        }
        for separator in [" by ", " - ", " – ", " — ", ", "] {
            if let range = working.range(of: separator, options: .caseInsensitive) {
                let title = String(working[..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                let artist = String(working[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if !title.isEmpty { return (title, artist.isEmpty ? nil : artist) }
            }
        }
        return (working, nil)
    }
}

// MARK: - Wire types

struct LessonCloudRequest: Codable, Equatable, Sendable {
    var kind: String
    var query: String
    var videoID: String?
    var title: String?
    var artist: String?
    var hand: String
    var maxNotes: Int
}

struct LessonCloudResponse: Codable, Equatable, Sendable {
    var title: String
    var composer: String?
    var tempoBPM: Double?
    var notes: [Note]
}

enum LessonServiceError: Error, Equatable, LocalizedError {
    case emptyInput
    case notFound
    case timedOut
    case badStatus(Int)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput: return "Type a song name, paste a link, or enter some notes first."
        case .notFound: return "The lesson service doesn't know that one yet."
        case .timedOut: return "The lesson service took too long to answer."
        case .badStatus(let code): return "The lesson service answered with status \(code)."
        case .invalidResponse(let reason): return "The lesson service sent something unexpected (\(reason))."
        }
    }
}

// MARK: - Transport

/// The seam between the app and the cloud pipeline. Production code uses `URLSessionLessonTransport`;
/// tests and the simulator use `MockLessonTransport`.
protocol LessonTransport: Sendable {
    func perform(_ request: LessonCloudRequest) async throws -> Data
}

/// Pretends to be the cloud endpoint: waits a little, then answers with JSON for songs it knows.
struct MockLessonTransport: LessonTransport {
    var latency: Duration = .milliseconds(1200)
    var library: [LibrarySong] = SongLibrary.all

    func perform(_ request: LessonCloudRequest) async throws -> Data {
        try await Task.sleep(for: latency)
        guard request.kind == "title_search" || request.kind == "music_share",
              let song = SongLibrary.match(title: request.title ?? request.query, composer: request.artist, in: library) else {
            throw LessonServiceError.notFound
        }
        let lesson = song.lesson(hand: HandSide(rawValue: request.hand) ?? .right, source: .cloud)
        let response = LessonCloudResponse(title: lesson.title, composer: lesson.composer, tempoBPM: lesson.tempoBPM, notes: lesson.notes)
        return try JSONEncoder().encode(response)
    }
}

/// Real HTTPS transport: POSTs the request as JSON and returns the response body.
struct URLSessionLessonTransport: LessonTransport {
    var endpoint: URL
    var session: URLSession = .shared
    var apiKey: String?

    func perform(_ request: LessonCloudRequest) async throws -> Data {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 20)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        urlRequest.httpBody = try JSONEncoder().encode(request)
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw LessonServiceError.invalidResponse("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw http.statusCode == 404 ? LessonServiceError.notFound : LessonServiceError.badStatus(http.statusCode)
        }
        return data
    }
}

// MARK: - Local fallback

/// On-device engine used when the cloud is unreachable or does not know a song.
struct LocalLessonEngine: Sendable {
    /// Turns raw notes (from notation text, a MIDI file, or a synthesizer) into a fingered lesson.
    func lesson(title: String, composer: String? = nil, rawNotes: [RawNote], hand: HandSide, tempoBPM: Double = 90,
                source: Lesson.Source = .localFallback, description: String, emoji: String = "🎵") -> Lesson {
        Lesson(title: title, composer: composer, hand: hand, tempoBPM: tempoBPM,
               notes: FingeringEngine.assign(rawNotes, hand: hand), source: source, sourceDescription: description, emoji: emoji)
    }

    /// A lesson from notation the user typed. (Songs are looked up in the index; unknown songs are never invented here.)
    func lesson(fromNotation notes: [RawNote], hand: HandSide) -> Lesson {
        lesson(title: "My Notes", rawNotes: notes, hand: hand, source: .imported,
               description: "Fingered on this iPad from the notes you typed", emoji: "✍️")
    }

    /// A short, deterministic five-finger melody seeded from `seed`: the same text always gives the same tune.
    func practiceTune(seed: String, label: String, hand: HandSide, length: Int = 16) -> Lesson {
        var generator = SeededGenerator(seed: SeededGenerator.hash(seed))
        let anchor = hand == .right ? 60 : 48 // C4 / C3, the "C position"
        let positions = [0, 2, 4, 5, 7] // C D E F G as semitone offsets
        var index = Int.random(in: 0...2, using: &generator)
        let rhythm: [Double] = [1, 1, 1, 1, 2, 0.5, 0.5, 1]
        let bpm = 84.0
        var raw: [RawNote] = []
        var beat = 0.0
        for step in 0..<length {
            let beats = step == length - 1 ? 3.0 : rhythm.randomElement(using: &generator) ?? 1
            raw.append(RawNote(pitch: anchor + positions[index], start: beat * 60 / bpm, duration: beats * 60 / bpm))
            beat += beats
            let move = [-2, -1, -1, 0, 1, 1, 2].randomElement(using: &generator) ?? 1
            index = min(max(index + move, 0), positions.count - 1)
            if step == length - 2 { index = 0 }
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortLabel = trimmed.count > 28 ? String(trimmed.prefix(28)) + "…" : trimmed
        return lesson(title: "Practice tune: \(shortLabel)", composer: "Made on this iPad", rawNotes: raw, hand: hand, tempoBPM: bpm,
                      description: "A practice tune made on this iPad (the song itself wasn't found)", emoji: "🎶")
    }

    /// Ascending then descending five-finger scale from `startPitch`.
    func fiveFingerScale(startPitch: Int = 60, hand: HandSide = .right, bpm: Double = 80) -> Lesson {
        let steps = [0, 2, 4, 5, 7, 5, 4, 2, 0]
        let raw = steps.enumerated().map { index, offset in
            RawNote(pitch: startPitch + offset, start: Double(index) * 60 / bpm, duration: 60 / bpm)
        }
        return lesson(title: "Five Finger Scale", rawNotes: raw, hand: hand, tempoBPM: bpm, source: .localFallback,
                      description: "Generated on this iPad", emoji: "🐛")
    }
}

/// SplitMix64: tiny, fast, deterministic.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// FNV-1a over the UTF-8 bytes of the lower-cased string (stable across launches, unlike `hashValue`).
    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.lowercased().utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        return value
    }
}

// MARK: - Service

enum LessonOrigin: Equatable, Sendable {
    /// Found in the bundled public-domain index (offline).
    case library(score: Double)
    /// Returned by the optional lesson endpoint.
    case cloud
    /// Built from notation the user typed.
    case notation
}

/// Returned when we can't honestly provide the song. Nothing is made up; the user chooses what to do next.
struct NotFoundInfo: Equatable, Sendable {
    var query: String
    /// The title we read from a link or share text, when we got that far.
    var resolvedTitle: String?
    var reason: String
    var suggestions: [LibrarySong]
}

enum LessonGenerationOutcome: Equatable, Sendable {
    case lesson(Lesson, origin: LessonOrigin)
    case notFound(NotFoundInfo)
}

protocol LessonGenerating: Sendable {
    func generateLesson(from text: String, hand: HandSide) async throws -> LessonGenerationOutcome
}

/// Pipeline: classify → read the title (links) → clean it → search the offline index → (optionally) ask the endpoint →
/// otherwise say honestly that we couldn't find it, with suggestions.
struct AILessonGeneratorService: LessonGenerating {
    /// Optional lesson endpoint (cloud simulation / future server). Not needed for the built-in songs.
    var transport: LessonTransport?
    var library: [LibrarySong] = SongLibrary.all
    var titleFetcher: VideoTitleFetching = YouTubeOEmbedFetcher()
    var titleCleaner: TitleCleaning?
    var localEngine = LocalLessonEngine()
    var timeout: Duration = .seconds(15)
    var maxNotes = 400

    func generateLesson(from text: String, hand: HandSide = .right) async throws -> LessonGenerationOutcome {
        guard let kind = LessonInputClassifier.classify(text) else { throw LessonServiceError.emptyInput }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Notation never needs a lookup.
        if case .rawNotes(let notes) = kind {
            return .lesson(localEngine.lesson(fromNotation: notes, hand: hand), origin: .notation)
        }

        // 2. Work out what the song is called.
        var title: String
        var artist: String?
        switch kind {
        case .youTube(let id):
            do {
                let metadata = try await titleFetcher.metadata(forVideoID: id)
                title = metadata.title
                artist = metadata.author
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "Couldn't read the video's title (is the iPad online?)."
                return .notFound(NotFoundInfo(query: trimmed, resolvedTitle: nil, reason: reason, suggestions: []))
            }
        case .musicShare(let t, let a, _):
            title = t
            artist = a
        case .titleSearch(let t, let c):
            title = t
            artist = c
        case .rawNotes:
            return .notFound(NotFoundInfo(query: trimmed, resolvedTitle: nil, reason: "No notes found.", suggestions: []))
        }
        if let cleaner = titleCleaner, let cleaned = await cleaner.cleanedTitle(from: title) { title = cleaned + " " + (artist ?? "") }
        let query = [title, artist ?? ""].joined(separator: " ").trimmingCharacters(in: .whitespaces)

        // 3. Offline index.
        if let match = SongMatcher.bestMatch(query: query, in: library) {
            return .lesson(match.song.lesson(hand: hand, source: .library), origin: .library(score: match.score))
        }

        // 4. Optional endpoint.
        var reason = "“\(title)” isn't in the free song library yet."
        if let transport {
            do {
                let request = makeRequest(kind: kind, text: trimmed, title: title, artist: artist, hand: hand)
                let data = try await withTimeout(timeout) { try await transport.perform(request) }
                return .lesson(try decodeAndValidate(data, request: request, hand: hand), origin: .cloud)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LessonServiceError where error == .notFound {
                // fall through to the honest not-found
            } catch {
                reason += " (The lesson service said: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))"
            }
        }

        // 5. Honest not-found with the closest real songs.
        let suggestions = SongMatcher.rank(query: query, in: library).prefix(3).map(\.song)
        return .notFound(NotFoundInfo(query: trimmed, resolvedTitle: title, reason: reason, suggestions: Array(suggestions)))
    }

    /// An explicit, opt-in practice tune (clearly not the real song).
    func practiceTune(for text: String, hand: HandSide) -> Lesson {
        localEngine.practiceTune(seed: text, label: text, hand: hand)
    }

    func makeRequest(kind: LessonInputKind, text: String, title: String, artist: String?, hand: HandSide) -> LessonCloudRequest {
        var request = LessonCloudRequest(kind: kind.wireName, query: text, videoID: nil, title: title, artist: artist,
                                         hand: hand.rawValue, maxNotes: maxNotes)
        if case .youTube(let id) = kind { request.videoID = id }
        return request
    }

    func decodeAndValidate(_ data: Data, request: LessonCloudRequest, hand: HandSide) throws -> Lesson {
        let response: LessonCloudResponse
        do {
            response = try JSONDecoder().decode(LessonCloudResponse.self, from: data)
        } catch {
            throw LessonServiceError.invalidResponse("could not read notes")
        }
        guard !response.notes.isEmpty else { throw LessonServiceError.invalidResponse("no notes") }
        guard response.notes.count <= maxNotes else { throw LessonServiceError.invalidResponse("too many notes") }
        guard response.notes.allSatisfy({ (21...108).contains($0.noteNumber) }) else {
            throw LessonServiceError.invalidResponse("notes outside the piano range")
        }
        let title = response.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return Lesson(title: title.isEmpty ? (request.title ?? "New Song") : title,
                      composer: response.composer, hand: hand, tempoBPM: response.tempoBPM ?? 90,
                      notes: response.notes, source: .cloud, sourceDescription: "From the lesson service", emoji: "✨")
    }
}

/// Runs `operation`, throwing `LessonServiceError.timedOut` if it takes longer than `limit`.
func withTimeout<T: Sendable>(_ limit: Duration, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw LessonServiceError.timedOut
        }
        guard let first = try await group.next() else { throw LessonServiceError.timedOut }
        group.cancelAll()
        return first
    }
}
