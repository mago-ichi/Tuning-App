import AVFoundation
import SwiftUI

@MainActor
final class PitchDetector: ObservableObject {
    enum TuningMode: String, CaseIterable, Identifiable {
        case chromatic = "クロマチック"
        case guitarStandard = "ギター(EADGBE)"

        var id: String { rawValue }
    }

    struct GuitarString {
        let id: Int
        let label: String
        let noteName: String
        let frequency: Double
    }

    struct GuitarMatch {
        let string: GuitarString
        let targetFrequency: Double
        let cents: Double
    }

    struct GuitarTarget: Identifiable {
        let id: Int
        let label: String
        let note: String
        let frequency: Double
        let isActive: Bool
    }

    struct AnalysisSnapshot {
        let frequency: Double?
        let rms: Float
        let peak: Float
        let confidence: Float
        let sampleRate: Double
        let frameCount: Int
        let formatText: String
    }

    @Published var detectedNote: String = "--"
    @Published var frequencyText: String = "0.0 Hz"
    @Published var tuningStatus: String = "未検出"
    @Published var centsOffset: CGFloat = 0
    @Published var isRunning: Bool = false
    @Published var tuningMode: TuningMode = .chromatic
    @Published var targetNoteText: String = "-"
    @Published var inputLevel: CGFloat = 0
    @Published var confidenceText: String = "信頼度: --"
    @Published var inputDebugText: String = "入力: --"
    @Published var microphoneSensitivity: Double = 2.0
    @Published var referenceFrequency: Double = 440.0
    @Published var capoFret: Int = 0
    @Published var activeGuitarStringID: Int?
    @Published var selectedGuitarStringIndex: Double = 0

    private let audioEngine = AVAudioEngine()
    private let toneEngine = AVAudioEngine()
    private let tonePlayer = AVAudioPlayerNode()
    private let analysisQueue = DispatchQueue(label: "PitchDetectorAnalysis")
    private var hasPermission = false
    private var isTonePlayerAttached = false
    private var isToneEngineConfigured = false
    private var recentFrequencies: [Double] = []
    private var lastStableFrequency: Double?
    private var smoothingWindowSize: Int {
        tuningMode == .guitarStandard ? 3 : 5
    }
    private let maxJumpRatio = 0.22
    private let guitarStrings: [GuitarString] = [
        .init(id: 6, label: "6弦", noteName: "E2", frequency: 82.41),
        .init(id: 5, label: "5弦", noteName: "A2", frequency: 110.00),
        .init(id: 4, label: "4弦", noteName: "D3", frequency: 146.83),
        .init(id: 3, label: "3弦", noteName: "G3", frequency: 196.00),
        .init(id: 2, label: "2弦", noteName: "B3", frequency: 246.94),
        .init(id: 1, label: "1弦", noteName: "E4", frequency: 329.63)
    ]

    var guitarTargets: [GuitarTarget] {
        guitarStrings.enumerated().map { index, string in
            let frequency = targetFrequency(for: string)
            let note = Self.noteFromFrequency(frequency, referenceFrequency: referenceFrequency).note
            return GuitarTarget(
                id: string.id,
                label: string.label,
                note: note,
                frequency: frequency,
                isActive: Int(selectedGuitarStringIndex.rounded()) == index
            )
        }
    }

    var selectedGuitarTarget: GuitarTarget? {
        let index = Int(selectedGuitarStringIndex.rounded())
        guard guitarTargets.indices.contains(index) else { return nil }
        return guitarTargets[index]
    }

    var tuningColor: Color {
        switch abs(centsOffset) {
        case 0..<5:
            return .green
        case 5..<15:
            return .orange
        default:
            return .red
        }
    }

    func requestPermission() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                self?.hasPermission = granted
            }
        }
    }

    func start() {
        guard !isRunning, hasPermission else {
            tuningStatus = hasPermission ? "起動失敗" : "マイク権限が必要です"
            return
        }

#if targetEnvironment(simulator)
        tuningStatus = "シミュレータではマイク入力非対応です（実機で実行してください）"
        return
#endif

        do {
            try configureAudioSession()
        } catch {
            tuningStatus = "音声設定失敗: \(error.localizedDescription)"
            return
        }

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            tuningStatus = "マイク入力フォーマットが無効です"
            return
        }
        let bufferSize: AVAudioFrameCount = 4096

        inputNode.removeTap(onBus: 0)
        let queue = analysisQueue
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, _ in
            queue.async {
                let snapshot = Self.analyze(buffer: buffer)
                Task { @MainActor in
                    self?.applyAnalysisSnapshot(snapshot)
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRunning = true
            recentFrequencies.removeAll()
            lastStableFrequency = nil
            tuningStatus = "検出中"
        } catch {
            tuningStatus = "起動失敗: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isRunning = false
        recentFrequencies.removeAll()
        lastStableFrequency = nil
        inputLevel = 0
        confidenceText = "信頼度: --"
        inputDebugText = "入力: --"
        tuningStatus = "停止中"
    }

    func playSelectedTargetTone() {
        guard tuningMode == .guitarStandard, let target = selectedGuitarTarget else { return }
        playTone(frequency: target.frequency)
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setPreferredSampleRate(44_100)
        try? session.setPreferredInputNumberOfChannels(1)
        try? session.setPreferredIOBufferDuration(0.046)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func playTone(frequency: Double) {
        do {
            try configureAudioSession()
            let format = try configureToneEngine()

            let sampleRate = format.sampleRate
            let samples = ToneGenerator.tuningForkTone(frequency: frequency, sampleRate: sampleRate)
            let frameCount = AVAudioFrameCount(samples.count)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            buffer.frameLength = frameCount

            guard let channel = buffer.floatChannelData?[0] else { return }
            for frame in samples.indices {
                channel[frame] = samples[frame]
            }

            tonePlayer.scheduleBuffer(buffer, at: nil, options: [])
            if !tonePlayer.isPlaying {
                tonePlayer.play()
            }
        } catch {
            tuningStatus = "再生失敗: \(error.localizedDescription)"
        }
    }

    private func configureToneEngine() throws -> AVAudioFormat {
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "TuningApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "再生フォーマットを作成できません"])
        }

        if !isTonePlayerAttached {
            toneEngine.attach(tonePlayer)
            isTonePlayerAttached = true
        }

        if !isToneEngineConfigured {
            toneEngine.connect(tonePlayer, to: toneEngine.mainMixerNode, format: format)
            tonePlayer.volume = 1.0
            toneEngine.mainMixerNode.outputVolume = 1.0
            isToneEngineConfigured = true
        }

        if !toneEngine.isRunning {
            toneEngine.prepare()
            try toneEngine.start()
        }

        return format
    }

    private func applyAnalysisSnapshot(_ snapshot: AnalysisSnapshot) {
        let sensitivity = max(0.1, microphoneSensitivity)
        inputLevel = CGFloat(min(1.0, max(Double(snapshot.rms) * 160.0 * sensitivity, Double(snapshot.peak) * 8.0 * sensitivity)))
        confidenceText = String(format: "信頼度: %.0f%%", snapshot.confidence * 100)
        inputDebugText = String(format: "入力: %.0fHz %dfr RMS %.4f Peak %.4f 感度 %.1fx %@", snapshot.sampleRate, snapshot.frameCount, snapshot.rms, snapshot.peak, sensitivity, snapshot.formatText)

        let rmsThreshold = 0.00025 / Float(sensitivity)
        let peakThreshold = 0.002 / Float(sensitivity)
        guard snapshot.rms > rmsThreshold || snapshot.peak > peakThreshold else {
            tuningStatus = "音が小さすぎます"
            return
        }

        guard let frequency = snapshot.frequency else {
            tuningStatus = "音程解析中"
            return
        }

        applyTuningResult(for: frequency)
    }

    private func applyTuningResult(for frequency: Double) {
        guard let stableFrequency = stableFrequency(from: frequency) else { return }
        frequencyText = String(format: "%.1f Hz", stableFrequency)

        switch tuningMode {
        case .chromatic:
            let result = Self.noteFromFrequency(stableFrequency, referenceFrequency: referenceFrequency)
            detectedNote = result.note
            targetNoteText = "基準: \(result.note)"
            activeGuitarStringID = nil
            updateStatus(cents: result.cents)
        case .guitarStandard:
            guard let match = selectedGuitarMatch(to: stableFrequency) else { return }
            let result = Self.noteFromFrequency(stableFrequency, referenceFrequency: referenceFrequency)
            detectedNote = result.note
            activeGuitarStringID = match.string.id
            targetNoteText = String(format: "目標: %@ %@ %.1f Hz", match.string.label, Self.noteFromFrequency(match.targetFrequency, referenceFrequency: referenceFrequency).note, match.targetFrequency)
            updateStatus(cents: match.cents)
        }
    }

    private func stableFrequency(from frequency: Double) -> Double? {
        let range: ClosedRange<Double> = tuningMode == .guitarStandard ? guitarFrequencyRange : 50...1200
        guard range.contains(frequency) else { return nil }

        if tuningMode == .chromatic, let lastStableFrequency, recentFrequencies.count >= 3 {
            let jumpRatio = abs(frequency - lastStableFrequency) / lastStableFrequency
            if jumpRatio > maxJumpRatio {
                return nil
            }
        }

        recentFrequencies.append(frequency)
        if recentFrequencies.count > smoothingWindowSize {
            recentFrequencies.removeFirst(recentFrequencies.count - smoothingWindowSize)
        }
        guard !recentFrequencies.isEmpty else { return nil }

        let sorted = recentFrequencies.sorted()
        let median = sorted[sorted.count / 2]
        lastStableFrequency = median
        return median
    }

    private func selectedGuitarMatch(to frequency: Double) -> GuitarMatch? {
        let index = Int(selectedGuitarStringIndex.rounded())
        guard guitarStrings.indices.contains(index) else { return nil }
        return guitarMatch(for: guitarStrings[index], frequency: frequency)
    }

    private func guitarMatch(for string: GuitarString, frequency: Double) -> GuitarMatch? {
        var bestMatch: GuitarMatch?
        var bestAbsoluteCents = Double.greatestFiniteMagnitude

        let openTarget = targetFrequency(for: string)
        for harmonic in 1...4 {
            let target = openTarget * Double(harmonic)
            let cents = 1200.0 * log2(frequency / target)
            let absoluteCents = abs(cents)
            if absoluteCents < bestAbsoluteCents {
                bestAbsoluteCents = absoluteCents
                bestMatch = GuitarMatch(string: string, targetFrequency: openTarget, cents: cents)
            }
        }
        return bestMatch
    }

    private var guitarFrequencyRange: ClosedRange<Double> {
        let targets = guitarStrings.map { targetFrequency(for: $0) }
        let low = max(40.0, (targets.min() ?? 70.0) * 0.65)
        let high = min(1400.0, (targets.max() ?? 360.0) * 4.2)
        return low...high
    }

    private func targetFrequency(for string: GuitarString) -> Double {
        let referenceRatio = referenceFrequency / 440.0
        let capoRatio = pow(2.0, Double(capoFret) / 12.0)
        return string.frequency * referenceRatio * capoRatio
    }

    private func updateStatus(cents: Double) {
        tuningStatus = cents >= 0 ? "少し高い" : "少し低い"
        if abs(cents) < 5 {
            tuningStatus = "チューニングOK"
        }
        centsOffset = CGFloat(max(-50, min(50, cents)))
    }

    nonisolated private static func analyze(buffer: AVAudioPCMBuffer) -> AnalysisSnapshot {
        let sampleRate = buffer.format.sampleRate
        let frameCount = Int(buffer.frameLength)
        let formatText = formatDescription(buffer.format)
        guard sampleRate > 0, let samples = extractSamples(buffer: buffer), samples.count > 1024 else {
            return AnalysisSnapshot(frequency: nil, rms: 0, peak: 0, confidence: 0, sampleRate: sampleRate, frameCount: frameCount, formatText: formatText)
        }

        let normalizedSamples = removeDCOffset(from: samples)
        let rms = rootMeanSquare(normalizedSamples)
        let peak = maxAbsoluteValue(normalizedSamples)
        guard rms > 0.00003 || peak > 0.0002 else {
            return AnalysisSnapshot(frequency: nil, rms: rms, peak: peak, confidence: 0, sampleRate: sampleRate, frameCount: frameCount, formatText: formatText)
        }

        let pitch = yinPitch(samples: normalizedSamples, sampleRate: sampleRate)
        return AnalysisSnapshot(
            frequency: pitch.frequency,
            rms: rms,
            peak: peak,
            confidence: pitch.confidence,
            sampleRate: sampleRate,
            frameCount: frameCount,
            formatText: formatText
        )
    }

    nonisolated private static func yinPitch(samples: [Float], sampleRate: Double) -> (frequency: Double?, confidence: Float) {
        let minFrequency = 65.0
        let maxFrequency = 500.0
        let minTau = max(2, Int(sampleRate / maxFrequency))
        let maxTau = min(samples.count / 2, Int(sampleRate / minFrequency))
        guard maxTau > minTau else { return (nil, 0) }

        var difference = [Float](repeating: 0, count: maxTau + 1)
        for tau in minTau...maxTau {
            var sum: Float = 0
            let count = samples.count - tau
            for i in 0..<count {
                let delta = samples[i] - samples[i + tau]
                sum += delta * delta
            }
            difference[tau] = sum
        }

        var cumulativeMeanNormalized = [Float](repeating: 1, count: maxTau + 1)
        var runningSum: Float = 0
        for tau in 1...maxTau {
            runningSum += difference[tau]
            if runningSum > 0 {
                cumulativeMeanNormalized[tau] = difference[tau] * Float(tau) / runningSum
            }
        }

        let threshold: Float = 0.18
        var tauEstimate: Int?
        for tau in minTau..<maxTau {
            if cumulativeMeanNormalized[tau] < threshold {
                var bestTau = tau
                while bestTau + 1 <= maxTau && cumulativeMeanNormalized[bestTau + 1] < cumulativeMeanNormalized[bestTau] {
                    bestTau += 1
                }
                tauEstimate = bestTau
                break
            }
        }

        if tauEstimate == nil {
            tauEstimate = (minTau...maxTau).min { cumulativeMeanNormalized[$0] < cumulativeMeanNormalized[$1] }
        }

        guard let tau = tauEstimate else { return (nil, 0) }
        let confidence = max(0, min(1, 1 - cumulativeMeanNormalized[tau]))
        guard confidence > 0.55 else { return (nil, confidence) }

        let refinedTau = parabolicInterpolation(values: cumulativeMeanNormalized, index: tau)
        guard refinedTau > 0 else { return (nil, confidence) }
        return (sampleRate / refinedTau, confidence)
    }

    nonisolated private static func parabolicInterpolation(values: [Float], index: Int) -> Double {
        guard index > 0, index + 1 < values.count else { return Double(index) }
        let previous = Double(values[index - 1])
        let current = Double(values[index])
        let next = Double(values[index + 1])
        let denominator = previous - 2 * current + next
        guard abs(denominator) > 1e-12 else { return Double(index) }
        return Double(index) + 0.5 * (previous - next) / denominator
    }

    nonisolated private static func extractSamples(buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }
        let channelCount = max(1, Int(buffer.format.channelCount))

        if let floatChannelData = buffer.floatChannelData {
            var samples = [Float](repeating: 0, count: frameCount)
            for channel in 0..<channelCount {
                let channelSamples = UnsafeBufferPointer(start: floatChannelData[channel], count: frameCount)
                for i in 0..<frameCount {
                    samples[i] += channelSamples[i] / Float(channelCount)
                }
            }
            return samples
        }

        if let int16ChannelData = buffer.int16ChannelData {
            var samples = [Float](repeating: 0, count: frameCount)
            for channel in 0..<channelCount {
                let channelSamples = UnsafeBufferPointer(start: int16ChannelData[channel], count: frameCount)
                for i in 0..<frameCount {
                    samples[i] += (Float(channelSamples[i]) / Float(Int16.max)) / Float(channelCount)
                }
            }
            return samples
        }

        if let int32ChannelData = buffer.int32ChannelData {
            var samples = [Float](repeating: 0, count: frameCount)
            for channel in 0..<channelCount {
                let channelSamples = UnsafeBufferPointer(start: int32ChannelData[channel], count: frameCount)
                for i in 0..<frameCount {
                    samples[i] += (Float(channelSamples[i]) / Float(Int32.max)) / Float(channelCount)
                }
            }
            return samples
        }

        return nil
    }

    nonisolated private static func removeDCOffset(from data: [Float]) -> [Float] {
        let mean = data.reduce(0, +) / Float(data.count)
        return data.map { $0 - mean }
    }

    nonisolated private static func rootMeanSquare(_ data: [Float]) -> Float {
        var sum: Float = 0
        for v in data {
            sum += v * v
        }
        return sqrt(sum / Float(data.count))
    }

    nonisolated private static func maxAbsoluteValue(_ data: [Float]) -> Float {
        data.reduce(0) { max($0, abs($1)) }
    }

    nonisolated private static func formatDescription(_ format: AVAudioFormat) -> String {
        let commonFormat: String
        switch format.commonFormat {
        case .pcmFormatFloat32:
            commonFormat = "f32"
        case .pcmFormatFloat64:
            commonFormat = "f64"
        case .pcmFormatInt16:
            commonFormat = "i16"
        case .pcmFormatInt32:
            commonFormat = "i32"
        case .otherFormat:
            commonFormat = "other"
        @unknown default:
            commonFormat = "unknown"
        }
        return "\(commonFormat)/\(format.channelCount)ch"
    }

    nonisolated private static func noteFromFrequency(_ frequency: Double, referenceFrequency: Double) -> (note: String, cents: Double) {
        let midi = 69.0 + 12.0 * log2(frequency / referenceFrequency)
        let roundedMidi = round(midi)
        let cents = (midi - roundedMidi) * 100.0

        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let noteIndex = Int((roundedMidi.truncatingRemainder(dividingBy: 12) + 12).truncatingRemainder(dividingBy: 12))
        let octave = Int(roundedMidi / 12.0) - 1
        return ("\(names[noteIndex])\(octave)", cents)
    }
}
