import Foundation

@main
struct ToneGeneratorTests {
    static func main() {
        let sampleRate = 44_100.0
        let frequencies = [82.41, 110.0, 329.63]
        let tones = frequencies.map {
            ToneGenerator.tuningForkTone(frequency: $0, sampleRate: sampleRate)
        }

        for tone in tones {
            assert(!tone.isEmpty, "tone should not be empty")
            assert(ToneGenerator.peak(tone) > 0.05, "tone should not be silent")
            assert(ToneGenerator.peak(tone) <= 0.68 + 0.0001, "tone should respect peak limit")
            assertClose(tone.first ?? 1, 0, tolerance: 0.0001, "tone should start at zero")
            assertClose(tone.last ?? 1, 0, tolerance: 0.0001, "tone should end at zero")
        }

        let rmsValues = tones.map(ToneGenerator.rms)
        let averageRMS = rmsValues.reduce(0, +) / Float(rmsValues.count)
        for rms in rmsValues {
            assertClose(rms, averageRMS, tolerance: 0.002, "tones should have matched RMS")
        }

        print("ToneGeneratorTests passed")
    }

    private static func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }

    private static func assertClose(_ lhs: Float, _ rhs: Float, tolerance: Float, _ message: String) {
        assert(abs(lhs - rhs) <= tolerance, "\(message): \(lhs) vs \(rhs)")
    }
}
