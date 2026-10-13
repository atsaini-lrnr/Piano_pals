import AVFoundation
import Foundation

/// Listens through the microphone while a grown-up plays or hums a tune and turns it into notes, entirely on this iPad.
/// Audio is analysed in memory frame by frame and never stored or sent anywhere.
@MainActor
final class ListenRecorder: ObservableObject {
    enum State: Equatable {
        case idle
        case listening
        case denied
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The note being heard right now (MIDI), for the live display.
    @Published private(set) var liveNote: Int?
    /// 0…1 loudness for the level meter.
    @Published private(set) var level: Double = 0
    @Published private(set) var heardCount = 0

    private let engine = AVAudioEngine()
    private let dsp = DispatchQueue(label: "pianopals.listen.dsp", qos: .userInitiated)
    private let pipeline = Locked<Pipeline?>(nil)

    /// Analysis state, only ever touched on `dsp`.
    private final class Pipeline {
        let detector: YINPitchDetector
        var segmenter: NoteSegmenter
        var accumulator: [Float] = []
        var processedSamples = 0
        let hop: Int
        var lastPublish: TimeInterval = 0

        init(sampleRate: Double) {
            detector = YINPitchDetector(sampleRate: sampleRate, frameSize: 2_048)
            hop = 1_024
            segmenter = NoteSegmenter(frameDuration: Double(1_024) / sampleRate)
        }
    }

    func start() async {
        guard state != .listening else { return }
        let granted = await ListenRecorder.requestPermission()
        guard granted else { state = .denied; return }

        // Changing the audio session can block, so it happens off the main thread.
        let sessionReady: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
                    try session.setActive(true)
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
        guard sessionReady else {
            state = .failed("The microphone isn't available right now.")
            return
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            state = .failed("No microphone was found.")
            return
        }
        let pipeline = Pipeline(sampleRate: format.sampleRate)
        self.pipeline.withLock { $0 = pipeline }
        liveNote = nil
        level = 0
        heardCount = 0

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            self?.dsp.async { self?.process(samples, pipeline: pipeline) }
        }
        do {
            engine.prepare()
            try engine.start()
            state = .listening
        } catch {
            input.removeTap(onBus: 0)
            state = .failed("Couldn't start listening.")
        }
    }

    /// Stops listening and returns the notes heard (raw timing, original octave).
    func stop() async -> [RawNote] {
        guard state == .listening else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let notes: [RawNote] = await withCheckedContinuation { continuation in
            dsp.async { [pipeline] in
                let result = pipeline.withLock { pipeline -> [RawNote] in
                    guard let pipeline else { return [] }
                    let end = Double(pipeline.processedSamples) / pipeline.detector.sampleRate
                    return pipeline.segmenter.finish(endTime: end)
                }
                continuation.resume(returning: result)
            }
        }
        pipeline.withLock { $0 = nil }
        DispatchQueue.global(qos: .utility).async { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        state = .idle
        liveNote = nil
        level = 0
        return notes
    }

    nonisolated private func process(_ samples: [Float], pipeline: Pipeline) {
        pipeline.accumulator.append(contentsOf: samples)
        while pipeline.accumulator.count >= pipeline.detector.frameSize {
            let frame = Array(pipeline.accumulator.prefix(pipeline.detector.frameSize))
            let time = Double(pipeline.processedSamples) / pipeline.detector.sampleRate
            let estimate = pipeline.detector.estimate(frame)
            pipeline.segmenter.ingest(time: time, estimate: estimate)
            pipeline.accumulator.removeFirst(pipeline.hop)
            pipeline.processedSamples += pipeline.hop

            if time - pipeline.lastPublish >= 0.05 {
                pipeline.lastPublish = time
                let live = pipeline.segmenter.liveNote
                let loudness = min(1, estimate.rms * 8)
                Task { @MainActor [weak self] in
                    self?.liveNote = live
                    self?.level = loudness
                }
            }
        }
    }

    /// Records how many notes have been recognised so far (cheap; for the "heard N notes" label).
    func noteHeardCount(_ count: Int) { heardCount = count }

    private static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
    }
}
