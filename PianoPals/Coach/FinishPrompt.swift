import Foundation

/// How the app asks a question out loud and hears the answer. Production: `SpeechVoiceIO`; tests use a stub.
@MainActor
protocol VoiceIO: AnyObject {
    /// Speaks the text and returns when it has been said.
    func speak(_ text: String) async
    /// Listens for up to `seconds`. nil when nothing understood was heard. Must return promptly when the calling task is cancelled.
    func listen(for seconds: TimeInterval) async -> VoiceAnswer?
}

/// The "You did it" screen without touching the iPad: the panda asks "again, or a new song?" and listens. A key on the real keyboard
/// answers "again". Nothing heard in 5 seconds: it asks once more; still nothing: it moves on to the next song, so a child who cannot
/// reach the iPad is never stuck.
@MainActor
final class FinishPrompt: ObservableObject {
    enum Phase: Equatable {
        case idle
        case asking(round: Int)
        case listening(round: Int)
    }

    static let questions = [
        "Shall we play that again, or a new song?",
        "Say again, or say new song. Or press any key on the piano to play it again!"
    ]

    @Published private(set) var phase: Phase = .idle
    var listenSeconds: TimeInterval = 5

    var isActive: Bool { phase != .idle }
    /// The line shown on screen while the app is asking, for a child who does not speak yet.
    var text: String? {
        switch phase {
        case .idle: return nil
        case .asking(let round), .listening(let round): return Self.questions[min(round, Self.questions.count) - 1]
        }
    }

    private var task: Task<Void, Never>?
    private var onAnswer: ((VoiceAnswer) -> Void)?

    func start(io: VoiceIO, onAnswer: @escaping (VoiceAnswer) -> Void) {
        cancel()
        self.onAnswer = onAnswer
        task = Task { [weak self] in
            for round in 1...Self.questions.count {
                guard let self, !Task.isCancelled else { return }
                self.phase = .asking(round: round)
                await io.speak(Self.questions[round - 1])
                guard !Task.isCancelled else { return }
                self.phase = .listening(round: round)
                if let answer = await io.listen(for: self.listenSeconds) {
                    guard !Task.isCancelled else { return }
                    self.finish(answer)
                    return
                }
                guard !Task.isCancelled else { return }
            }
            self?.finish(.next)
        }
    }

    /// A key on the real keyboard: play it again.
    func keyPressed() {
        guard isActive else { return }
        finish(.again)
    }

    func cancel() {
        task?.cancel()
        task = nil
        onAnswer = nil
        phase = .idle
    }

    private func finish(_ answer: VoiceAnswer) {
        let handler = onAnswer
        cancel()
        handler?(answer)
    }
}
