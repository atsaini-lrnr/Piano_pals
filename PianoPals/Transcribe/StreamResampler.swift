import Foundation

/// Turns a stream of samples at one rate into a stream at a lower rate by averaging, so the model can be fed the microphone live.
/// Averaging over each output step is a simple low-pass filter: no aliasing from the higher rate.
struct StreamResampler: Sendable {
    /// Input samples that make one output sample (input rate ÷ output rate).
    let ratio: Double
    private var sum = 0.0
    private var filled = 0.0

    init(inputRate: Double, outputRate: Double) { ratio = max(inputRate / outputRate, 1e-6) }

    mutating func process(_ input: [Float]) -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(Int(Double(input.count) / ratio) + 1)
        for sample in input {
            var remaining = 1.0
            while remaining > 1e-12 {
                let take = min(remaining, ratio - filled)
                sum += Double(sample) * take
                filled += take
                remaining -= take
                if filled >= ratio - 1e-9 {
                    output.append(Float(sum / ratio))
                    sum = 0
                    filled = 0
                }
            }
        }
        return output
    }
}
