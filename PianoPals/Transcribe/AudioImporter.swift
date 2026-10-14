import AVFoundation
import Foundation

enum AudioImportError: Error, Equatable, LocalizedError {
    case unreadable
    case empty
    case tooLong(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "That file couldn't be opened as sound."
        case .empty: return "There was no sound in that file."
        case .tooLong(let seconds): return "That recording is long. Please use a clip of up to \(seconds) seconds."
        }
    }
}

/// Reads any audio file the system understands (wav, m4a, mp3, aiff, caf…) into 22.05 kHz mono samples, on this device.
enum AudioImporter {
    static let maximumSeconds = 90

    static func samples(from url: URL, maximumSeconds: Int = AudioImporter.maximumSeconds) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AudioImportError.unreadable }
        let inputFormat = file.processingFormat
        guard file.length > 0, inputFormat.sampleRate > 0 else { throw AudioImportError.empty }
        let seconds = Double(file.length) / inputFormat.sampleRate
        guard seconds <= Double(maximumSeconds) else { throw AudioImportError.tooLong(seconds: maximumSeconds) }

        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: BasicPitch.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw AudioImportError.unreadable }
        do { try file.read(into: input) } catch { throw AudioImportError.unreadable }

        let capacity = AVAudioFrameCount(seconds * BasicPitch.sampleRate) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw AudioImportError.unreadable }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied { inputStatus.pointee = .endOfStream; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil, let channel = output.floatChannelData?[0], output.frameLength > 0 else { throw AudioImportError.unreadable }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        guard samples.contains(where: { abs($0) > 1e-4 }) else { throw AudioImportError.empty }
        return samples
    }
}
