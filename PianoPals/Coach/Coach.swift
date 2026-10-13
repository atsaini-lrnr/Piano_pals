import Foundation

enum CoachAction: Equatable, Sendable {
    /// Speak this and show it in the panda's bubble.
    case say(String)
    /// Softly glow the key(s) we're waiting for.
    case highlightTarget
    /// Show a big badge for the finger to use.
    case showFingerHint(Finger)
    /// Make the lesson easier: switch to "wait for me" and/or slow down.
    case adjustPace(waitForMe: Bool, tempoScale: Double?)
}

/// Every sentence the coach can say. Child-safe by construction: tests scan this list for negative words.
enum CoachPhrases {
    static let nearMiss = ["So close! Try the key to the %@!", "Almost! Just one key to the %@!"]
    static let lookForGlow = ["Look for the glowing key!", "Follow the sparkle!", "The glowing key is waiting for you!"]
    static let fingerTip = ["Try your %@ finger! It's number %d.", "Use finger number %d, the %@ one!"]
    static let handTip = ["Use your %@ hand for this song!", "Let's use the %@ hand this time!"]
    static let hesitation = ["Take your time! I'll wait for you.", "No rush! Look for the glowing key."]
    static let slower = ["Let's go a little slower!", "Let's take it nice and easy!"]
    static let waitForMe = ["I'll wait for you! Play when you're ready.", "Let's wait for each note together!"]
    static let streak = ["Five in a row! Amazing!", "Ten in a row! You're a star!", "Fifteen in a row! Wow!"]
    static let finish = ["You did it! Great playing!", "Wow! Three stars!", "Hooray! You finished the song!"]
    static let practiceNext = ["Next time, let's practice your %@ finger!"]

    /// Every phrase with sample values filled in (used by the safety test).
    static var allExpanded: [String] {
        var all: [String] = []
        for template in nearMiss { all += ["left", "right"].map { String(format: template, $0) } }
        for template in fingerTip { for finger in Finger.allCases { all.append(formatFinger(template, finger)) } }
        for template in handTip { all += ["left", "right"].map { String(format: template, $0) } }
        for template in practiceNext { all += Finger.allCases.map { String(format: template, $0.kidName) } }
        all += lookForGlow + hesitation + slower + waitForMe + streak + finish
        return all
    }

    static func formatFinger(_ template: String, _ finger: Finger) -> String {
        // Templates use either "%@ … %d" or "%d … %@".
        if template.hasPrefix("Try") { return String(format: template, finger.kidName, finger.number) }
        return String(format: template, finger.number, finger.kidName)
    }

    /// Words that must never reach a child.
    static let banned = ["wrong", "bad", "no!", "no,", "mistake", "incorrect", "fail", "error", "stupid", "terrible",
                         "not right", "don't", "dont", "can't", "cant", "never", "oops", "sorry", "worse", "silly"]
}

/// Decides what to say or do about a mistake. Gentle, escalating, and rate-limited; never reports a score or negativity.
struct Coach: Sendable {
    /// At most one spoken tip in this many seconds (praise has its own, shorter gap).
    static let speechGap: TimeInterval = 6
    static let praiseGap: TimeInterval = 3
    static let paceCooldown: TimeInterval = 20

    private var lastSpoken: TimeInterval = -.infinity
    private var lastPaceChange: TimeInterval = -.infinity
    private var rotation: [String: Int] = [:]
    private var fingerConfusions: [String: Int] = [:]
    private var streak = 0

    mutating func reset() { self = Coach() }

    // MARK: Mistakes

    mutating func react(to mistake: Mistake, stats: SessionStats, mode: PaceMode, tempoScale: Double, now: TimeInterval) -> [CoachAction] {
        var actions: [CoachAction] = []
        streak = 0

        switch mistake.kind {
        case .wrongKey(_, _, let nearness):
            if stats.consecutiveWrongKeys >= 2 {
                actions.append(.highlightTarget)
                speak(pick("glow", CoachPhrases.lookForGlow), now: now, into: &actions)
            } else if case .adjacent(let direction) = nearness {
                let side = direction == .right ? "right" : "left"
                speak(String(format: pick("near", CoachPhrases.nearMiss), side), now: now, into: &actions)
            }
            actions += adaptivePace(stats: stats, mode: mode, tempoScale: tempoScale, now: now)

        case .wrongFinger(let expected, let played):
            let key = "\(expected.number)-\(played.number)"
            let count = (fingerConfusions[key] ?? 0) + 1
            fingerConfusions[key] = count
            actions.append(.showFingerHint(expected))
            if count >= 2, count % 2 == 0 {
                speak(CoachPhrases.formatFinger(pick("finger", CoachPhrases.fingerTip), expected), now: now, into: &actions)
            }

        case .wrongHand(let expected, _):
            speak(String(format: pick("hand", CoachPhrases.handTip), expected == .right ? "right" : "left"), now: now, into: &actions)

        case .hesitation:
            actions.append(.highlightTarget)
            speak(pick("hesitation", CoachPhrases.hesitation), now: now, into: &actions)

        case .skippedNote:
            let recentSkips = stats.recent.suffix(5).filter { $0 }.count
            if mode == .playAlong, recentSkips >= 3, now - lastPaceChange >= Coach.paceCooldown {
                lastPaceChange = now
                actions.append(.adjustPace(waitForMe: true, tempoScale: nil))
                speak(pick("wait", CoachPhrases.waitForMe), now: now, into: &actions, force: true)
            }
        }
        return actions
    }

    /// Easier pace after a rough patch: ≥ 4 wrong keys in a row, or ≥ 6 of the last 10 attempts.
    private mutating func adaptivePace(stats: SessionStats, mode: PaceMode, tempoScale: Double, now: TimeInterval) -> [CoachAction] {
        let struggling = stats.consecutiveWrongKeys >= 4 || (stats.recent.count >= 6 && stats.recentErrorCount >= 6)
        guard struggling, now - lastPaceChange >= Coach.paceCooldown else { return [] }
        var actions: [CoachAction] = []
        if mode == .playAlong {
            lastPaceChange = now
            actions.append(.adjustPace(waitForMe: true, tempoScale: nil))
            speak(pick("wait", CoachPhrases.waitForMe), now: now, into: &actions, force: true)
        } else if tempoScale > 0.5 {
            lastPaceChange = now
            actions.append(.adjustPace(waitForMe: true, tempoScale: max(0.4, tempoScale - 0.15)))
            speak(pick("slower", CoachPhrases.slower), now: now, into: &actions, force: true)
        }
        return actions
    }

    // MARK: Successes

    mutating func reactToHit(quality: HitQuality, now: TimeInterval) -> [CoachAction] {
        switch quality {
        case .perfect, .fingerUnverified:
            streak += 1
        case .fingerOff, .wrongHand:
            break
        }
        guard streak > 0, streak % 5 == 0, now - lastSpoken >= Coach.praiseGap else { return [] }
        lastSpoken = now
        return [.say(CoachPhrases.streak[min(streak / 5 - 1, CoachPhrases.streak.count - 1)])]
    }

    mutating func reactToFinish(stars: Int, stats: SessionStats) -> [CoachAction] {
        var actions: [CoachAction] = [.say(stars == 3 ? CoachPhrases.finish[1] : pick("finish", [CoachPhrases.finish[0], CoachPhrases.finish[2]]))]
        if let weak = stats.weakestFinger {
            actions.append(.say(String(format: CoachPhrases.practiceNext[0], weak.kidName)))
        }
        return actions
    }

    // MARK: Helpers

    private mutating func speak(_ text: String, now: TimeInterval, into actions: inout [CoachAction], force: Bool = false) {
        guard force || now - lastSpoken >= Coach.speechGap else { return }
        lastSpoken = now
        actions.append(.say(text))
    }

    /// Cycles through a phrase pool so the coach doesn't repeat itself, deterministically.
    private mutating func pick(_ category: String, _ pool: [String]) -> String {
        let index = rotation[category, default: 0]
        rotation[category] = index + 1
        return pool[index % pool.count]
    }
}

// MARK: - Parent progress

struct SessionSummary: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var date: Date
    var lessonTitle: String
    var durationSeconds: Double
    var notes: Int
    var firstTryAccuracy: Double
    var fingerAccuracy: Double?
    var stars: Int
    var weakestFinger: Int?
    var wrongKeys: Int
    var wrongFingers: Int
    var hesitations: Int
    var perFinger: [Int: FingerStats]

    init(date: Date = Date(), lessonTitle: String, durationSeconds: Double, notes: Int, stars: Int, stats: SessionStats) {
        self.date = date
        self.lessonTitle = lessonTitle
        self.durationSeconds = durationSeconds
        self.notes = notes
        self.firstTryAccuracy = stats.firstTryAccuracy
        self.fingerAccuracy = stats.fingerAccuracy
        self.stars = stars
        self.weakestFinger = stats.weakestFinger?.number
        self.wrongKeys = stats.wrongKeys
        self.wrongFingers = stats.wrongFingers
        self.hesitations = stats.hesitations
        self.perFinger = stats.perFinger
    }
}

/// Plain-language note for a parent. Templates are the always-available path; the on-device model can reword them.
protocol SummaryPhrasing: Sendable {
    func phrase(for summary: SessionSummary) async -> String
}

struct TemplateSummaryPhraser: SummaryPhrasing {
    func phrase(for summary: SessionSummary) async -> String { Self.text(for: summary) }

    static func text(for summary: SessionSummary) -> String {
        let percent = Int((summary.firstTryAccuracy * 100).rounded())
        var parts = ["Played “\(summary.lessonTitle)” and earned \(summary.stars) star\(summary.stars == 1 ? "" : "s")."]
        parts.append("\(percent)% of the notes were right on the first try.")
        if let fingers = summary.fingerAccuracy {
            parts.append("The camera saw the suggested finger on \(Int((fingers * 100).rounded()))% of the notes it could judge.")
        }
        if let weak = summary.weakestFinger.flatMap(Finger.init(rawValue:)) {
            parts.append("Worth a little practice: the \(weak.displayName.lowercased()) finger (number \(weak.number)).")
        } else {
            parts.append("No finger stood out as tricky.")
        }
        return parts.joined(separator: " ")
    }

    /// Structured facts only (no names, no free text) for the optional on-device model.
    static func facts(for summary: SessionSummary) -> String {
        var line = "Song: \(summary.lessonTitle). Stars: \(summary.stars) of 3. First-try accuracy: \(Int((summary.firstTryAccuracy * 100).rounded()))%."
        if let fingers = summary.fingerAccuracy { line += " Finger accuracy: \(Int((fingers * 100).rounded()))%." }
        if let weak = summary.weakestFinger { line += " Finger to practise: number \(weak)." }
        return line
    }
}

/// Uses Apple's on-device model to reword the parent note when available; otherwise the template.
struct OnDeviceSummaryPhraser: SummaryPhrasing {
    func phrase(for summary: SessionSummary) async -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), let text = await FoundationModelsBridge.summarize(facts: TemplateSummaryPhraser.facts(for: summary)) {
            return text
        }
        #endif
        return TemplateSummaryPhraser.text(for: summary)
    }
}

/// Keeps the last 30 session summaries on this iPad only.
struct ProgressStore {
    var defaults: UserDefaults = .standard
    static let limit = 30
    private let key = "progress.sessions"

    func load() -> [SessionSummary] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SessionSummary].self, from: data)) ?? []
    }

    func append(_ summary: SessionSummary) {
        var all = load()
        all.insert(summary, at: 0)
        if all.count > Self.limit { all = Array(all.prefix(Self.limit)) }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }

    func clear() { defaults.removeObject(forKey: key) }
}
