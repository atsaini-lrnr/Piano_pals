import AVFoundation
import Foundation
import Speech

/// Speaks with the narrator's voice and listens with on-device speech recognition. No audio leaves the iPad: if the iPad cannot recognise
/// speech on the device, or permission is refused, `listen` just waits out the time (a key on the real keyboard can still answer).
@MainActor
final class SpeechVoiceIO: VoiceIO {
    private let narrator: Narrator
    private let sessionRestored: () -> Void

    init(narrator: Narrator, sessionRestored: @escaping () -> Void) {
        self.narrator = narrator
        self.sessionRestored = sessionRestored
    }

    func speak(_ text: String) async { await narrator.sayAndWait(text) }

    func listen(for seconds: TimeInterval) async -> VoiceAnswer? {
        let session = ListeningSession()
        let answer = await withTaskCancellationHandler {
            await session.run(seconds: seconds)
        } onCancel: {
            session.finish(nil)
        }
        sessionRestored()
        return answer
    }
}

/// One listening round: start the microphone and the recogniser, end at the first understood answer, the deadline or cancellation.
private final class ListeningSession: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<VoiceAnswer?, Never>?
    private var finished = false
    private var cleanup: (() -> Void)?

    func finish(_ answer: VoiceAnswer?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let cleanup = self.cleanup
        self.continuation = nil
        self.cleanup = nil
        lock.unlock()
        cleanup?()
        continuation?.resume(returning: answer)
    }

    func run(seconds: TimeInterval) async -> VoiceAnswer? {
        guard await Self.authorised(), let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<VoiceAnswer?, Never>) in
            lock.lock()
            if finished { lock.unlock(); continuation.resume(returning: nil); return }
            self.continuation = continuation
            lock.unlock()

            // Audio-session and engine start-up can block, so they never run on the main thread.
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let engine = AVAudioEngine()
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = true
                do {
                    let audio = AVAudioSession.sharedInstance()
                    try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
                    try audio.setActive(true)
                    let input = engine.inputNode
                    input.installTap(onBus: 0, bufferSize: 1_024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
                    engine.prepare()
                    try engine.start()
                } catch {
                    finish(nil)
                    return
                }
                let task = recognizer.recognitionTask(with: request) { [self] result, _ in
                    if let text = result?.bestTranscription.formattedString, let answer = VoiceAnswer.parse(text) { finish(answer) }
                }
                lock.lock()
                let alreadyDone = finished
                if !alreadyDone {
                    cleanup = {
                        task.cancel()
                        engine.inputNode.removeTap(onBus: 0)
                        engine.stop()
                        request.endAudio()
                    }
                }
                lock.unlock()
                if alreadyDone {
                    task.cancel()
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in finish(nil) }
            }
        }
    }

    private static func authorised() async -> Bool {
        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
