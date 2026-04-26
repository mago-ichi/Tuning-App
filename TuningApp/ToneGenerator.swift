import Foundation

struct ToneGenerator {
    /// 指定の基音周波数で、楽器のような倍音を含むトーンを生成する。
    /// 低音域 (E2=82Hz など) でもスマホ内蔵スピーカーで明瞭に聞こえるよう、
    /// 第 6 倍音までを混合し、`normalize` で全周波数の RMS / Peak を揃えて出力する。
    static func tuningForkTone(
        frequency: Double,
        sampleRate: Double = 44_100,
        duration: Double = 0.75,
        targetRMS: Float = 0.16,
        maxPeak: Float = 0.68
    ) -> [Float] {
        guard frequency > 0, sampleRate > 0, duration > 0 else { return [] }

        let frameCount = max(2, Int(sampleRate * duration))
        let attackDuration = 0.025
        let releaseDuration = 0.18
        let nyquist = sampleRate / 2
        var samples = [Float](repeating: 0, count: frameCount)

        // 倍音バランス。第1倍音 (基音) を基準に上位倍音を加える。
        // 第2-3倍音を強めにすることで、低音弦でも内蔵スピーカーから音程を知覚しやすくする。
        let partials: [(multiplier: Double, amplitude: Double)] = [
            (1.0, 1.00),
            (2.0, 0.60),
            (3.0, 0.45),
            (4.0, 0.28),
            (5.0, 0.18),
            (6.0, 0.10)
        ]

        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate

            // 緩やかな減衰 + アタック/リリースの S 字フェードで耳障りなクリックを防止
            var envelope = exp(-1.0 * time)
            if time < attackDuration {
                let progress = time / attackDuration
                envelope *= 0.5 - 0.5 * cos(Double.pi * progress)
            }
            let remaining = duration - time
            if remaining < releaseDuration {
                let progress = max(0, remaining / releaseDuration)
                envelope *= 0.5 - 0.5 * cos(Double.pi * progress)
            }

            var value = 0.0
            for partial in partials {
                let partialFrequency = frequency * partial.multiplier
                if partialFrequency >= nyquist { continue }
                value += sin(2.0 * Double.pi * partialFrequency * time) * partial.amplitude
            }
            samples[frame] = Float(value * envelope)
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
