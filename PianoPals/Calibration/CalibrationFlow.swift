import Combine
import Foundation

/// The finger → key assignment each calibration step assumes ("C position").
enum CalibrationPositions {
    /// Right hand: thumb on middle C, then D, E, F, and pinky on G.
    static let right: [Finger: Int] = [.thumb: 60, .index: 62, .middle: 64, .ring: 65, .pinky: 67]
    /// Left hand: pinky on the C an octave below middle C, thumb on the G above it.
    static let left: [Finger: Int] = [.thumb: 55, .index: 53, .middle: 52, .ring: 50, .pinky: 48]

    static func notes(for side: HandSide) -> [Finger: Int] { side == .right ? right : left }
}

struct CalibrationStep: Equatable, Identifiable {
    let side: HandSide
    let template: HandTemplate
    let expectedNotes: [Finger: Int]
    var id: HandSide { side }

    var spokenInstruction: String {
        side == .right ? "Put your right hand on the hand print!" : "Now put your left hand on the hand print!"
    }
    var title: String { side == .right ? "Right hand" : "Left hand" }
}

/// Drives the step-by-step "put your hands on the prints" calibration.
@MainActor
final class CalibrationFlow: ObservableObject {
    enum Outcome: Equatable {
        case success(KeyboardRegion)
        case failed(String)
    }

    /// How long the hand must stay on the print.
    static let requiredHold: TimeInterval = 1.4

    let steps: [CalibrationStep]
    let firstNote: Int
    let lastNote: Int
    let aspectRatio: Double

    @Published private(set) var currentIndex = 0
    @Published private(set) var progress: Double = 0
    @Published private(set) var handSeen = false
    @Published private(set) var isAligned = false
    @Published private(set) var score: Double = 0
    @Published private(set) var outcome: Outcome?
    /// Fires each time a step completes (for celebration + narration).
    let stepCompleted = PassthroughSubject<CalibrationStep, Never>()

    private var heldTime: TimeInterval = 0
    private var lastTimestamp: TimeInterval?
    private var sums: [Finger: (x: Double, y: Double, count: Int)] = [:]
    private var collected: [KeyboardRegionFitter.Sample] = []
    private var skippedAll = true

    init(firstNote: Int, lastNote: Int, aspectRatio: Double = 16.0 / 9.0) {
        self.firstNote = firstNote
        self.lastNote = lastNote
        self.aspectRatio = aspectRatio
        self.steps = HandSide.allCases.reversed().compactMap { side -> CalibrationStep? in
            let notes = CalibrationPositions.notes(for: side)
            guard notes.values.allSatisfy({ (firstNote...lastNote).contains($0) }) else { return nil }
            return CalibrationStep(side: side, template: .make(for: side), expectedNotes: notes)
        }
        if steps.isEmpty { outcome = .failed("This keyboard is too small for the hand-print steps. A grown-up can skip this part.") }
    }

    var currentStep: CalibrationStep? { steps.indices.contains(currentIndex) ? steps[currentIndex] : nil }

    /// Feed every new camera frame from the tracking channel.
    func ingest(_ frame: HandFrame) {
        guard outcome == nil, let step = currentStep else { return }
        let dt = lastTimestamp.map { min(max(frame.timestamp - $0, 0), 0.1) } ?? 0
        lastTimestamp = frame.timestamp

        let aspect = frame.imageSize.height > 0 ? Double(frame.imageSize.width / frame.imageSize.height) : aspectRatio
        let match = HandTemplateMatcher.match(frame: frame, template: step.template, aspectRatio: aspect)
        handSeen = match.handDetected
        isAligned = match.isAligned
        score = match.score

        if match.isAligned {
            heldTime += dt
            for (finger, point) in match.tips {
                let previous = sums[finger] ?? (0, 0, 0)
                sums[finger] = (previous.x + Double(point.x), previous.y + Double(point.y), previous.count + 1)
            }
        } else {
            heldTime = max(0, heldTime - dt * 2)
            if heldTime == 0 { sums.removeAll() }
        }
        progress = min(heldTime / CalibrationFlow.requiredHold, 1)
        if progress >= 1 { completeCurrentStep(using: step) }
    }

    /// A grown-up skips the current step (keyboard too small, or no camera).
    func skipCurrentStep() {
        guard outcome == nil else { return }
        advance()
    }

    private func completeCurrentStep(using step: CalibrationStep) {
        skippedAll = false
        for (finger, note) in step.expectedNotes {
            guard let sum = sums[finger], sum.count > 0 else { continue }
            collected.append(KeyboardRegionFitter.Sample(
                x: sum.x / Double(sum.count), y: sum.y / Double(sum.count),
                expectedWhitePosition: PianoKeys.center(of: note)))
        }
        stepCompleted.send(step)
        advance()
    }

    private func advance() {
        heldTime = 0
        progress = 0
        sums.removeAll()
        lastTimestamp = nil
        isAligned = false
        if currentIndex + 1 < steps.count {
            currentIndex += 1
            return
        }
        finish()
    }

    private func finish() {
        if collected.isEmpty {
            outcome = .failed(skippedAll ? "Calibration was skipped." : "We couldn't see the fingers clearly. Let's try again!")
            return
        }
        if let region = KeyboardRegionFitter.fit(samples: collected, firstNote: firstNote, lastNote: lastNote) {
            outcome = .success(region)
        } else {
            outcome = .failed("The hands didn't line up with the piano keys. Let's try again!")
        }
    }

    func restart() {
        currentIndex = 0
        collected.removeAll()
        skippedAll = true
        outcome = steps.isEmpty ? outcome : nil
        heldTime = 0
        progress = 0
        sums.removeAll()
        lastTimestamp = nil
    }
}

/// Saves the fitted region per camera so calibration survives relaunches.
struct CalibrationStore {
    var defaults: UserDefaults = .standard

    private func key(_ channel: CameraChannelID) -> String { "calibration.region.\(channel.rawValue)" }

    func load(channel: CameraChannelID, firstNote: Int, lastNote: Int) -> KeyboardRegion? {
        guard let data = defaults.data(forKey: key(channel)),
              let region = try? JSONDecoder().decode(KeyboardRegion.self, from: data),
              region.firstNote == firstNote, region.lastNote == lastNote else { return nil }
        return region
    }

    func save(_ region: KeyboardRegion, channel: CameraChannelID) {
        if let data = try? JSONEncoder().encode(region) { defaults.set(data, forKey: key(channel)) }
    }

    func clear(channel: CameraChannelID) { defaults.removeObject(forKey: key(channel)) }
}
