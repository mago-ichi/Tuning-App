import Foundation

struct ToneGenerator {
    static func tuningForkTone(
        frequency: Double,
        sampleRate: Double = 44_100,
        duration: Double = 0.75,
        targetRMS: Float = 0.16,
        maxPeak: Float = 0.68
    ) -> [Float] {
        guard frequency > 0, sampleRate > 0, duration > 0 else { return [] }

        let frameCount = max(2, Int(sampleRate * duration))
        let attackDuration = 0.035
        let releaseDuration = 0.16
        var samples = [Float](repeating: 0, count: frameCount)

        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate
            var envelope = exp(-1.25 * time)

            if time < attackDuration {
                let progress = time / attackDuration
                envelope *= 0.5 - 0.5 * cos(Double.pi * progress)
            }

            let remaining = duration - time
            if remaining < releaseDuration {
                let progress = max(0, remaining / releaseDuration)
                envelope *= 0.5 - 0.5 * cos(Double.pi * progress)
            }

            samples[frame] = Float(sin(2.0 * Double.pi * frequency * time)) * Float(envelope)
        }

        normalize(&samples, targetRMS: targetRMS, maxPeak: maxPeak)
        samples[0] = 0
        samples[frameCount - 1] = 0
        return samples
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(samples.count))
    }

    static func peak(_ samples: [Float]) -> Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }

    private static func normalize(_ samples: inout [Float], targetRMS: Float, maxPeak: Float) {
        let currentRMS = rms(samples)
        let currentPeak = peak(samples)
        guard currentRMS > 0, currentPeak > 0 else { return }

        let rmsGain = targetRMS / currentRMS
        let peakGain = maxPeak / currentPeak
        let gain = min(rmsGain, peakGain)

        for index in samples.indices {
            samples[index] *= gain
        }
    }
}
