import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Rule-based clean-up of video / share titles: removes "(Official Video)", "Lyrics", "Piano Tutorial" and similar noise,
/// and proposes alternative readings ("Artist - Title" vs "Title - Artist").
enum TitleNormalizer {
    /// Longest first so "official music video" is removed before "video".
    static let noisePhrases: [String] = [
        "official music video", "official lyric video", "official video", "official audio", "lyric video", "music video",
        "with lyrics", "lyrics", "karaoke version", "karaoke", "piano tutorial", "easy piano tutorial", "easy piano", "piano cover",
        "piano version", "tutorial", "nursery rhymes", "nursery rhyme", "kids songs", "kids song", "songs for kids", "for kids",
        "for children", "children s", "instrumental", "full song", "full version", "remastered", "synthesia", "sheet music",
        "midi", "official", "hd", "4k", "hq", "audio", "video", "cover", "live", "slow", "beginner", "feat", "ft"
    ].sorted { $0.count > $1.count }

    static func stripBrackets(_ text: String) -> String {
        var result = text
        for pattern in ["\\([^)]*\\)", "\\[[^\\]]*\\]", "\\{[^}]*\\}"] {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return result
    }

    static func stripNoise(_ text: String) -> String {
        var words = SongMatcher.tokens(text).joined(separator: " ")
        for phrase in noisePhrases {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            words = words.replacingOccurrences(of: "\\b\(escaped)\\b", with: " ", options: .regularExpression)
        }
        return words.split(separator: " ").joined(separator: " ")
    }

    /// Alternative readings of a raw title, best guess first. Never empty for non-empty input.
    static func candidates(from raw: String) -> [String] {
        let withoutBrackets = stripBrackets(raw)
        var results: [String] = []
        func add(_ text: String) {
            let cleaned = stripNoise(text)
            if !cleaned.isEmpty, !results.contains(cleaned) { results.append(cleaned) }
        }
        add(withoutBrackets)
        let separators = [" | ", " - ", " – ", " — ", " : ", ": ", " by ", " | "]
        var segments = [withoutBrackets]
        for separator in separators {
            segments = segments.flatMap { $0.components(separatedBy: separator) }
        }
        segments.forEach(add)
        return results
    }
}

/// Optional extra step that can understand messy titles better than rules. Always has a rule-based fallback.
protocol TitleCleaning: Sendable {
    /// A cleaned "Title" (and composer when obvious), or nil when unavailable.
    func cleanedTitle(from raw: String) async -> String?
}

/// Uses Apple's on-device language model when the iPad supports it. Nothing leaves the device.
/// Returns nil (so the rule-based cleaner is used) on any iPad without Apple Intelligence or in the Simulator.
struct OnDeviceTitleCleaner: TitleCleaning {
    func cleanedTitle(from raw: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return await FoundationModelsBridge.cleanTitle(raw)
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
enum FoundationModelsBridge {
    @Generable
    struct CleanedTitle {
        @Guide(description: "The name of the song only, without video-site words such as official, lyrics, tutorial, cover or karaoke.")
        var title: String
    }

    static func cleanTitle(_ raw: String) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }
        do {
            let session = LanguageModelSession(instructions: "You extract the song name from a messy video or share title. Reply with the song name only.")
            let response = try await session.respond(to: "Title: \(raw)", generating: CleanedTitle.self)
            let title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty || title.count > 120 ? nil : title
        } catch {
            return nil
        }
    }

    /// Two warm, plain-language sentences for a parent, from structured numbers only (no free-form data in the prompt).
    static func summarize(facts: String) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }
        do {
            let session = LanguageModelSession(instructions: "You write a short, kind, encouraging progress note for a parent about their young child's piano practice. Two sentences. Never criticise the child.")
            let response = try await session.respond(to: facts)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}
#endif

// MARK: - YouTube title lookup

struct VideoMetadata: Equatable, Sendable {
    var title: String
    var author: String?
}

protocol VideoTitleFetching: Sendable {
    func metadata(forVideoID id: String) async throws -> VideoMetadata
}

/// Reads a video's *title* from YouTube's public oEmbed endpoint. Only the video's public URL is sent; no audio or video
/// is downloaded and no key is needed.
struct YouTubeOEmbedFetcher: VideoTitleFetching {
    var session: URLSession = .shared
    var timeout: TimeInterval = 6

    static func requestURL(forVideoID id: String) -> URL? {
        var components = URLComponents(string: "https://www.youtube.com/oembed")
        components?.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(id)"),
            URLQueryItem(name: "format", value: "json")
        ]
        return components?.url
    }

    static func decode(_ data: Data) throws -> VideoMetadata {
        struct Payload: Decodable { let title: String; let author_name: String? }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LessonServiceError.invalidResponse("empty title") }
        return VideoMetadata(title: title, author: payload.author_name)
    }

    func metadata(forVideoID id: String) async throws -> VideoMetadata {
        guard let url = Self.requestURL(forVideoID: id) else { throw LessonServiceError.invalidResponse("bad URL") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LessonServiceError.invalidResponse("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw http.statusCode == 404 || http.statusCode == 401 ? LessonServiceError.notFound : LessonServiceError.badStatus(http.statusCode)
        }
        return try Self.decode(data)
    }
}
