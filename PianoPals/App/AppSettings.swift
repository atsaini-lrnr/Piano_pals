import Foundation

/// Standard keyboard sizes (lowest and highest MIDI note).
enum KeyboardPreset: String, CaseIterable, Identifiable {
    case keys25, keys37, keys49, keys61, keys76, keys88

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .keys25: return "25 keys (C3–C5)"
        case .keys37: return "37 keys (C3–C6)"
        case .keys49: return "49 keys (C2–C6)"
        case .keys61: return "61 keys (C2–C7)"
        case .keys76: return "76 keys (E1–G7)"
        case .keys88: return "88 keys (A0–C8)"
        }
    }
    var lowNote: Int {
        switch self {
        case .keys25, .keys37: return 48
        case .keys49, .keys61: return 36
        case .keys76: return 28
        case .keys88: return 21
        }
    }
    var highNote: Int {
        switch self {
        case .keys25: return 72
        case .keys37: return 84
        case .keys49: return 84
        case .keys61: return 96
        case .keys76: return 103
        case .keys88: return 108
        }
    }
}

/// User-adjustable options, persisted in `UserDefaults`.
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var keyboardPreset: KeyboardPreset { didSet { defaults.set(keyboardPreset.rawValue, forKey: "keyboardPreset") } }
    @Published var paceMode: PaceMode { didSet { defaults.set(paceMode.rawValue, forKey: "paceMode") } }
    @Published var tempoScale: Double { didSet { defaults.set(tempoScale, forKey: "tempoScale") } }
    @Published var narrationEnabled: Bool { didSet { defaults.set(narrationEnabled, forKey: "narration") } }
    @Published var onScreenSound: Bool { didSet { defaults.set(onScreenSound, forKey: "onScreenSound") } }
    @Published var hardwareSound: Bool { didSet { defaults.set(hardwareSound, forKey: "hardwareSound") } }
    @Published var mirrorSmile: Bool { didSet { defaults.set(mirrorSmile, forKey: "mirrorSmile") } }
    @Published var demoHands: Bool { didSet { defaults.set(demoHands, forKey: "demoHands") } }
    @Published var demoWrongFinger: Bool { didSet { defaults.set(demoWrongFinger, forKey: "demoWrongFinger") } }
    @Published var lessonHand: HandSide { didSet { defaults.set(lessonHand.rawValue, forKey: "lessonHand") } }

    var keyboardRange: ClosedRange<Int> { keyboardPreset.lowNote...keyboardPreset.highNote }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keyboardPreset = KeyboardPreset(rawValue: defaults.string(forKey: "keyboardPreset") ?? "") ?? .keys61
        paceMode = PaceMode(rawValue: defaults.string(forKey: "paceMode") ?? "") ?? .waitForMe
        let tempo = defaults.double(forKey: "tempoScale")
        tempoScale = tempo == 0 ? 0.8 : tempo
        narrationEnabled = defaults.object(forKey: "narration") as? Bool ?? true
        onScreenSound = defaults.object(forKey: "onScreenSound") as? Bool ?? true
        hardwareSound = defaults.object(forKey: "hardwareSound") as? Bool ?? false
        mirrorSmile = defaults.object(forKey: "mirrorSmile") as? Bool ?? true
        demoHands = defaults.bool(forKey: "demoHands")
        demoWrongFinger = defaults.bool(forKey: "demoWrongFinger")
        lessonHand = HandSide(rawValue: defaults.string(forKey: "lessonHand") ?? "") ?? .right
    }
}
