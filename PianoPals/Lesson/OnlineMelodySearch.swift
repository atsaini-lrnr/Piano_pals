import Foundation

// MARK: - Candidates and licences

/// A free MIDI file found on a public site. Nothing is downloaded until a grown-up taps Add.
struct OnlineCandidate: Identifiable, Equatable, Sendable {
    enum Site: String, Sendable {
        case mutopia = "Mutopia Project"
        case commons = "Wikimedia Commons"
    }

    let site: Site
    let title: String
    let composer: String?
    let instrument: String?
    let licence: String
    let midiURL: URL
    let pageURL: URL?
    let sizeBytes: Int?

    var id: String { midiURL.absoluteString }
}

/// Only openly-licensed files are ever offered. Non-commercial / no-derivatives / unknown licences are dropped: turning a file
/// into a lesson is a derivative use, and this app is meant to stay free for every family.
enum LicensePolicy {
    static func isAllowed(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("noncommercial") || lower.contains("non-commercial") || lower.contains("noderiv") || lower.contains("no derivative")
            || lower.contains("nonderiv") || lower.contains("all rights reserved") { return false }
        let tokens = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if tokens.contains("nc") || tokens.contains("nd") { return false }
        if lower.contains("public domain") || tokens.contains("cc0") || tokens.contains("pd") { return true }
        if lower.contains("attribution") { return true }
        for index in tokens.indices where tokens[index] == "cc" && index + 1 < tokens.count && tokens[index + 1] == "by" { return true }
        return false
    }
}

// MARK: - Parsing

enum MutopiaParser {
    /// Reads the result tables of `make-table.cgi`: one table per piece with title, composer, instrument, licence and `.mid` link.
    static func parse(_ html: String) -> [OnlineCandidate] {
        let base = URL(string: "https://www.mutopiaproject.org/cgibin/")!
        return html.components(separatedBy: "result-table\">").dropFirst().compactMap { chunk -> OnlineCandidate? in
            let table = chunk.components(separatedBy: "</table>").first ?? chunk
            guard let midi = firstMatch(#"href="([^"]+\.mid)""#, in: table), let midiURL = URL(string: midi, relativeTo: base)?.absoluteURL else { return nil }
            let cells = matches(#"<td[^>]*>(.*?)</td>"#, in: table).map(plain).filter { !$0.isEmpty }
            guard let title = cells.first else { return nil }
            var composer = cells.first { $0.hasPrefix("by ") }.map { String($0.dropFirst(3)) }
            if let current = composer, let paren = current.firstIndex(of: "(") { composer = String(current[..<paren]).trimmingCharacters(in: .whitespaces) }
            let instrument = cells.first { $0.hasPrefix("for ") }.map { String($0.dropFirst(4)) }
            let licence = firstMatch(#"href="[^"]*legal\.html[^"]*"[^>]*>(.*?)</a>"#, in: table).map(plain) ?? ""
            let page = firstMatch(#"href="(piece-info\.cgi\?id=\d+)""#, in: table).flatMap { URL(string: $0, relativeTo: base)?.absoluteURL }
            return OnlineCandidate(site: .mutopia, title: title, composer: composer, instrument: instrument, licence: licence,
                                   midiURL: midiURL, pageURL: page, sizeBytes: nil)
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? { matches(pattern, in: text).first }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Strips tags and the few HTML entities these pages use.
    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CommonsParser {
    /// Reads a MediaWiki `generator=search` + `prop=imageinfo` response.
    static func parse(_ data: Data) -> [OnlineCandidate] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = (root["query"] as? [String: Any])?["pages"] as? [String: Any] else { return [] }
        let ranked = pages.values.compactMap { $0 as? [String: Any] }.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        return ranked.compactMap { page -> OnlineCandidate? in
            guard let info = (page["imageinfo"] as? [[String: Any]])?.first,
                  (info["mime"] as? String)?.contains("midi") == true,
                  let urlText = info["url"] as? String, let url = URL(string: urlText) else { return nil }
            let meta = info["extmetadata"] as? [String: Any]
            let licence = ((meta?["LicenseShortName"] as? [String: Any])?["value"] as? String).map(MutopiaParser.plain) ?? ""
            let artist = ((meta?["Artist"] as? [String: Any])?["value"] as? String).map(MutopiaParser.plain)
            var title = (page["title"] as? String) ?? "Untitled"
            if title.hasPrefix("File:") { title.removeFirst(5) }
            if let dot = title.lastIndex(of: "."), title.distance(from: dot, to: title.endIndex) <= 5 { title = String(title[..<dot]) }
            return OnlineCandidate(site: .commons, title: title, composer: artist, instrument: nil, licence: licence, midiURL: url,
                                   pageURL: (info["descriptionurl"] as? String).flatMap(URL.init(string:)), sizeBytes: info["size"] as? Int)
        }
    }
}

// MARK: - Search service

protocol HTTPFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

struct URLSessionFetcher: HTTPFetching {
    func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("PianoPals/1.0 (free piano lessons for children; public-domain MIDI search)", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw OnlineSearchError.badStatus(http.statusCode) }
        return data
    }
}

enum OnlineSearchError: Error, Equatable, LocalizedError {
    case badStatus(Int)
    case tooLarge
    case notMIDI
    case licenceNotAllowed
    case nothingPlayable

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "The website answered with an error (\(code))."
        case .tooLarge: return "That file is too big to use."
        case .notMIDI: return "That download wasn't a MIDI file."
        case .licenceNotAllowed: return "That file's licence doesn't allow us to use it."
        case .nothingPlayable: return "There weren't enough notes in that file to make a lesson."
        }
    }
}

protocol OnlineMelodySearching: Sendable {
    func search(_ query: String) async throws -> [OnlineCandidate]
    func download(_ candidate: OnlineCandidate) async throws -> Data
}

/// Looks in two free, public sites. Only the search words are sent; no sound, pictures or camera data ever leave the iPad.
struct OnlineMelodySearch: OnlineMelodySearching {
    static let sites = "mutopiaproject.org and commons.wikimedia.org"
    static let maximumBytes = 600_000

    var fetcher: HTTPFetching = URLSessionFetcher()
    var limit = 8

    func search(_ query: String) async throws -> [OnlineCandidate] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return [] }
        let encoded = words.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=#"))) ?? words
        let mutopiaURL = URL(string: "https://www.mutopiaproject.org/cgibin/make-table.cgi?searchingfor=\(encoded)&Composer=&Instrument=&Style=&collection=&id=&solo=&recent=&timelength=1&timeunit=week&lilyversion=&preview=1")
        let commonsQuery = "\(words) filemime:audio/midi".addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? words
        let commonsURL = URL(string: "https://commons.wikimedia.org/w/api.php?action=query&format=json&generator=search&gsrnamespace=6&gsrlimit=10&gsrsearch=\(commonsQuery)&prop=imageinfo&iiprop=url%7Csize%7Cmime%7Cextmetadata&iiextmetadatafilter=LicenseShortName%7CArtist")

        async let mutopia: [OnlineCandidate] = {
            guard let url = mutopiaURL, let data = try? await fetcher.fetch(url) else { return [] }
            return MutopiaParser.parse(String(decoding: data, as: UTF8.self))
        }()
        async let commons: [OnlineCandidate] = {
            guard let url = commonsURL, let data = try? await fetcher.fetch(url) else { return [] }
            return CommonsParser.parse(data)
        }()
        let found = await mutopia + commons
        return Self.rank(found, query: words, limit: limit)
    }

    func download(_ candidate: OnlineCandidate) async throws -> Data {
        guard LicensePolicy.isAllowed(candidate.licence) else { throw OnlineSearchError.licenceNotAllowed }
        if let size = candidate.sizeBytes, size > Self.maximumBytes { throw OnlineSearchError.tooLarge }
        let data = try await fetcher.fetch(candidate.midiURL)
        guard data.count <= Self.maximumBytes else { throw OnlineSearchError.tooLarge }
        guard data.starts(with: Array("MThd".utf8)) else { throw OnlineSearchError.notMIDI }
        return data
    }

    /// Keeps open licences only, drops anything that shares no word with the search, best title match first, no duplicates.
    static func rank(_ candidates: [OnlineCandidate], query: String, limit: Int) -> [OnlineCandidate] {
        func words(_ text: String) -> Set<String> { Set(SongMatcher.tokens(text)).subtracting(SongMatcher.stopwords) }
        let wanted = words(query)
        var seen = Set<String>()
        let scored: [(OnlineCandidate, Double)] = candidates.compactMap { candidate in
            guard LicensePolicy.isAllowed(candidate.licence), seen.insert(candidate.id).inserted else { return nil }
            let titleWords = words(candidate.title)
            let otherWords = words([candidate.composer, candidate.instrument].compactMap { $0 }.joined(separator: " "))
            let hits = Double(wanted.intersection(titleWords).count) + 0.5 * Double(wanted.intersection(otherWords).count)
            guard hits > 0 else { return nil }
            let tightness = Double(wanted.count) / Double(max(titleWords.count, wanted.count))
            let piano = (candidate.instrument?.lowercased().contains("piano") == true) ? 0.25 : 0
            return (candidate, hits + tightness + piano)
        }
        return Array(scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0))
    }
}

// MARK: - MIDI → lesson

enum OnlineImport {
    /// The tune on top: at each moment the highest note (right hand) or lowest note (left hand) of a multi-track score.
    static func skyline(_ notes: [RawNote], hand: HandSide, window: TimeInterval = 0.03) -> [RawNote] {
        let sorted = notes.sorted { $0.start < $1.start }
        var result: [RawNote] = []
        var index = 0
        while index < sorted.count {
            var end = index
            while end + 1 < sorted.count, sorted[end + 1].start - sorted[index].start <= window { end += 1 }
            let group = sorted[index...end]
            if let pick = hand == .right ? group.max(by: { $0.pitch < $1.pitch }) : group.min(by: { $0.pitch < $1.pitch }) { result.append(pick) }
            index = end + 1
        }
        // A long held note under the tune isn't a new melody note: trim notes that overlap the next one.
        for i in result.indices.dropLast() {
            let gap = result[i + 1].start - result[i].start
            if result[i].duration > gap { result[i].duration = max(gap, 0.1) }
        }
        return result
    }

    static func lesson(from data: Data, candidate: OnlineCandidate, hand: HandSide) throws -> Lesson {
        let notes = try StandardMIDIFile.parse(data)
        let melody = skyline(notes, hand: hand)
        let credit = [candidate.composer, candidate.licence].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        guard let lesson = ListenTranscriber.lesson(from: melody, hand: hand, title: candidate.title,
                                                    description: "First bars of the melody from \(candidate.site.rawValue)\(credit.isEmpty ? "" : " (\(credit))"), fingered on this iPad",
                                                    emoji: "🌐") else { throw OnlineSearchError.nothingPlayable }
        return lesson
    }
}
