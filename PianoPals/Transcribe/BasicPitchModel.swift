import CoreML
import Foundation

/// The bundled Basic Pitch Core ML model (Spotify, Apache-2.0). Runs fully on this device.
final class BasicPitchModel: @unchecked Sendable {
    enum ModelError: Error, LocalizedError {
        case missing
        case badOutput

        var errorDescription: String? {
            switch self {
            case .missing: return "The note-finding model isn't installed."
            case .badOutput: return "The note-finding model gave an unexpected answer."
            }
        }
    }

    private let model: MLModel

    /// nil when the model isn't in the app (the YIN fallback is used then).
    init?(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "nmp", withExtension: "mlmodelc") else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let model = try? MLModel(contentsOf: url, configuration: configuration) else { return nil }
        self.model = model
    }

    /// One window in, `(note, onset)` out; each `172 × 88` row-major. `Identity_1` is the note activation, `Identity_2` the onset
    /// (checked against a synthetic tone: onset peaks at the attack, note stays on).
    func predict(window: [Float]) throws -> (note: [Float], onset: [Float]) {
        guard window.count == BasicPitch.windowSamples else { throw ModelError.badOutput }
        let input = try MLMultiArray(shape: [1, NSNumber(value: BasicPitch.windowSamples), 1], dataType: .float32)
        window.withUnsafeBufferPointer { source in
            input.dataPointer.copyMemory(from: source.baseAddress!, byteCount: source.count * MemoryLayout<Float>.size)
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_2": MLFeatureValue(multiArray: input)]))
        guard let note = output.featureValue(for: "Identity_1")?.multiArrayValue, let onset = output.featureValue(for: "Identity_2")?.multiArrayValue else {
            throw ModelError.badOutput
        }
        let count = BasicPitch.framesPerWindow * BasicPitch.keyCount
        guard note.count == count, onset.count == count else { throw ModelError.badOutput }
        return (Self.floats(note), Self.floats(onset))
    }

    private static func floats(_ array: MLMultiArray) -> [Float] {
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        return Array(UnsafeBufferPointer(start: pointer, count: array.count))
    }
}
