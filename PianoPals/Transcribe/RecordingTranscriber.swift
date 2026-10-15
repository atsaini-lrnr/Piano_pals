import Foundation

/// A recording turned into lessons: the tune for the right hand and, when there is one, the low notes for the left hand.
struct TranscriptionResult: Equatable, Sendable {
    enum Method: String, Sendable { case basicPitch = "Basic Pitch model", pitchTracker = "pitch tracker (one voice)" }
    var lessons: [Lesson]
    var method: Method
    var noteCount: Int
}

enum TranscriptionError: Error, Equatable, LocalizedError {
    case noNotes

    var errorDescription: String? {
        "I couldn't find clear notes in that recording. A short, clean piano or single-voice clip works best."
    }
}

enum RecordingLessons {
    /// Splits heard notes into a right-hand melody (highest note at each moment) and a left-hand line (lowest note) and fingers both.
    /// Music that sits low or has little below middle C becomes one right-hand lesson, moved up whole octaves.
    static func lessons(from notes: [RawNote], title: String, description: String) -> [Lesson] {
        let split = 60
        let low = notes.filter { $0.pitch < split }
        let high = notes.filter { $0.pitch >= split }
        let twoHands = low.count >= ListenTranscriber.minimumNotes && high.count >= ListenTranscriber.minimumNotes
        var lessons: [Lesson] = []
        let rightSource = twoHands ? high : notes
        if let right = ListenTranscriber.lesson(from: OnlineImport.skyline(rightSource, hand: .right), hand: .right, title: title,
                                                description: description, emoji: "🎼") { lessons.append(right) }
        if twoHands, let left = ListenTranscriber.lesson(from: OnlineImport.skyline(low, hand: .left), hand: .left, title: title + " (left hand)",
                                                         description: description, emoji: "🎼") { lessons.append(left) }
        return lessons
    }
}

/// Audio file → notes → lessons, entirely on this device. Uses the Basic Pitch model when installed (any number of notes at once);
/// otherwise the pitch tracker, which follows one voice at a time.
struct RecordingTranscriber {
    var model: BasicPitchModel?
    var decoder = BasicPitchDecoder()
    /// Notes fainter than this (0…1) are dropped. Real notes from the model come out around 0.6 to 0.8.
    static let minimumStrength: Float = 0.45

    init(model: BasicPitchModel? = BasicPitchModel()) { self.model = model }

    func transcribe(url: URL, title: String, progress: @Sendable (Double) -> Void = { _ in }) throws -> TranscriptionResult {
        let samples = try AudioImporter.samples(from: url)
        return try transcribe(samples: samples, title: title, progress: progress)
    }

    func transcribe(samples: [Float], title: String, progress: @Sendable (Double) -> Void = { _ in }) throws -> TranscriptionResult {
        let method: TranscriptionResult.Method
        let notes: [RawNote]
        if let model {
            method = .basicPitch
            notes = try modelNotes(samples: samples, model: model, progress: progress)
        } else {
            method = .pitchTracker
            notes = pitchTrackerNotes(samples: samples)
        }
        let description = "Made from your recording on this iPad with the \(method.rawValue); the recording wasn't kept"
        let lessons = RecordingLessons.lessons(from: notes, title: title, description: description)
        guard !lessons.isEmpty else { throw TranscriptionError.noNotes }
        return TranscriptionResult(lessons: lessons, method: method, noteCount: notes.count)
    }

    private func modelNotes(samples: [Float], model: BasicPitchModel, progress: @Sendable (Double) -> Void) throws -> [RawNote] {
        let starts = BasicPitch.windowStarts(sampleCount: samples.count)
        var notes: [[Float]] = [], onsets: [[Float]] = []
        for (index, start) in starts.enumerated() {
            try Task.checkCancellation()
            let output = try model.predict(window: BasicPitch.window(of: samples, start: start))
            notes.append(output.note)
            onsets.append(output.onset)
            progress(Double(index + 1) / Double(starts.count))
        }
        let note = BasicPitch.stitch(notes, sampleCount: samples.count)
        let onset = BasicPitch.stitch(onsets, sampleCount: samples.count)
        let decoded = decoder.decode(note: note.grid, onset: onset.grid, frames: min(note.frames, onset.frames))
        // Faint notes are room noise, speaker hum and overtones: a lesson built from them has keys nobody played.
        return BasicPitchDecoder.suppressingHarmonics(decoded).filter { $0.strength >= Self.minimumStrength }.map(\.raw)
    }

    /// Single-voice fallback: the same YIN tracker and segmenter that Listen mode uses.
    private func pitchTrackerNotes(samples: [Float]) -> [RawNote] {
        let rate = BasicPitch.sampleRate, frame = 2_048, hop = 1_024
        let detector = YINPitchDetector(sampleRate: rate, frameSize: frame)
        var segmenter = NoteSegmenter(frameDuration: Double(hop) / rate)
        var position = 0
        while position + frame <= samples.count {
            segmenter.ingest(time: Double(position) / rate, estimate: detector.estimate(Array(samples[position..<position + frame])))
            position += hop
        }
        return segmenter.finish(endTime: Double(samples.count) / rate)
    }
}
