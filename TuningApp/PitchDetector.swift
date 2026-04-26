import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class PitchDetector: ObservableObject {
    enum TuningMode: String, CaseIterable, Identifiable {
        case chromatic = "クロマチック"
        case guitarStandard = "ギター(EADGBE)"

        var id: String { rawValue }
    }

    enum TuningQuality {
        case idle
        case lowSignal
        case analyzing
        case sharp
        case flat
        case inTune
    }

    struct GuitarString: Identifiable, Equatable {
        let id: Int
        let label: String
        let noteName: String
        let frequency: Double
    }

    struct GuitarTarget: Identifiable, Equatable {
        let id: Int
        let label: String
        let note: String
        let frequency: Double
    }

    struct GuitarMatch {
        let string: GuitarString
        let targetFrequency: Double
        let cents: Double
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

    // MARK: - Published display state

    @Published private(set) var detectedNote: String = "--"
    @Published private(set) var detectedOctave: Int? = nil
    @Published private(set) var displayFrequency: Double = 0
    @Published private(set) var displayCents: Double = 0
    @Published private(set) var rawCents: Double = 0
    @Published private(set) var quality: TuningQuality = .idle
    @Published private(set) var statusMessage: String = "メーターをタップして開始"
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var inputLevel: CGFloat = 0
    @Published private(set) var confidence: Double = 0
    @Published private(set) var matchedGuitarStringID: Int? = nil
    @Published private(set) var lockProgress: Double = 0
    @Published private(set) var hasStableSignal: Bool = false
    @Published private(set) var debugText: String = ""

    @Published var tuningMode: TuningMode = .chromatic {
        didSet {
            guard oldValue != tuningMode else { return }
            resetTrackingState()
        }
    }
    @Published var microphoneSensitivity: Double = 1.0
    @Published var referenceFrequency: Double = 440.0
    @Published var capoFret: Int = 0
    @Published var autoSelectGuitarString: Bool = true {
        didSet { resetTrackingState() }
    }
    @Published var selectedGuitarStringIndex: Int = 0 {
        didSet {
            let clamped = min(max(0, selectedGuitarStringIndex), guitarStrings.count - 1)
            if clamped != selectedGuitarStringIndex {
                selectedGuitarStringIndex = clamped
            } else if oldValue != selectedGuitarStringIndex {
                resetTrackingState()
            }
        }
    }
    @Published var showDebug: Bool = false

    // MARK: - Internal

    private let audioEngine = AVAudioEngine()
    private let tonePlayer = AVAudioPlayerNode()
    private let analysisQueue = DispatchQueue(label: "PitchDetectorAnalysis")
    private let toneFormat: AVAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var hasPermission = false
    private var permissionRequested = false
    private var isTonePlayerAttached = false
    private var isToneRouteConfigured = false
    private var emaCents: Double? = nil
    private var emaFrequency: Double? = nil
    private var stableNoteIdentifier: String? = nil
    private var consecutiveInTuneFrames: Int = 0
    private var lastSignalDate: Date = .distantPast
    private var lockedIn: Bool = false
    private let lockInRequiredFrames: Int = 8
    private let lockInCentsTolerance: Double = 4.0
    private let signalHoldInterval: TimeInterval = 0.6
    private var lightHaptic: UIImpactFeedbackGenerator? = nil
    private var successHaptic: UINotificationFeedbackGenerator? = nil
    private var muteAnalysisUntil: Date = .distantPast

    let guitarStrings: [GuitarString] = [
        .init(id: 6, label: "6弦", noteName: "E2", frequency: 82.41),
        .init(id: 5, label: "5弦", noteName: "A2", frequency: 110.00),
        .init(id: 4, label: "4弦", noteName: "D3", frequency: 146.83),
        .init(id: 3, label: "3弦", noteName: "G3", frequency: 196.00),
        .init(id: 2, label: "2弦", noteName: "B3", frequency: 246.94),
        .init(id: 1, label: "1弦", noteName: "E4", frequency: 329.63)
    ]

    var guitarTargets: [GuitarTarget] {
        guitarStrings.map { string in
            let frequency = targetFrequency(for: string)
            let result = Self.noteFromFrequency(frequency, referenceFrequency: referenceFrequency)
            return GuitarTarget(
                id: string.id,
                label: string.label,
                note: result.note,
                frequency: frequency
            )
        }
    }

    var selectedGuitarTarget: GuitarTarget? {
        guard guitarTargets.indices.contains(selectedGuitarStringIndex) else { return nil }
        return guitarTargets[selectedGuitarStringIndex]
    }

    var activeGuitarTarget: GuitarTarget? {
        if autoSelectGuitarString, let id = matchedGuitarStringID,
           let target = guitarTargets.first(where: { $0.id == id }) {
            return target
        }
        return selectedGuitarTarget
    }

    var tuningColor: Color {
        switch quality {
        case .inTune: return .green
        case .sharp, .flat: return abs(displayCents) < 15 ? .orange : .red
        case .lowSignal, .analyzing: return .secondary
        case .idle: return .secondary
        }
    }

    var displayCentsString: String {
        guard hasStableSignal else { return "--" }
        let value = Int(displayCents.rounded())
        if value > 0 { return "+\(value)¢" }
        if value < 0 { return "\(value)¢" }
        return "0¢"
    }

    var frequencyText: String {
        guard hasStableSignal else { return "-- Hz" }
        return String(format: "%.1f Hz", displayFrequency)
    }

    var confidenceText: String {
        guard isRunning else { return "停止中" }
        return String(format: "信頼度 %.0f%%", confidence * 100)
    }

    // MARK: - Lifecycle

    func requestPermission() {
        guard !permissionRequested else { return }
        permissionRequested = true
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                self?.hasPermission = granted
                if !granted {
                    self?.statusMessage = "マイクを許可してください"
                }
            }
        }
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    func start() {
        guard !isRunning else { return }
        guard hasPermission else {
            statusMessage = "マイクを許可してください"
            requestPermission()
            return
        }

#if targetEnvironment(simulator)
        statusMessage = "シミュレータでは動作しません(実機で実行してください)"
        return
#endif

        do {
            try configureAudioSession()
        } catch {
            statusMessage = "音声設定失敗: \(error.localizedDescription)"
            return
        }

        // タップ設置の前に一度エンジンを止める (再生中の場合は後で再起動する)
        if audioEngine.isRunning {
            audioEngine.stop()
        }

        attachToneNodesIfNeeded()

        let inputNode = audioEngine.inputNode
        var format = inputNode.outputFormat(forBus: 0)
        if format.sampleRate <= 0 || format.channelCount == 0 {
            format = inputNode.inputFormat(forBus: 0)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            statusMessage = "マイク入力フォーマットが無効です"
            return
        }
        let bufferSize: AVAudioFrameCount = 4096

        inputNode.removeTap(onBus: 0)
        let queue = analysisQueue
        let mode = tuningMode
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, _ in
            queue.async {
                let snapshot = Self.analyze(buffer: buffer, mode: mode)
                Task { @MainActor in
                    self?.applyAnalysisSnapshot(snapshot)
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            statusMessage = "起動失敗: \(error.localizedDescription)"
            return
        }

        isRunning = true
        resetTrackingState()
        statusMessage = "音を鳴らしてください"
        quality = .analyzing
        lightHaptic = UIImpactFeedbackGenerator(style: .light)
        lightHaptic?.prepare()
        successHaptic = UINotificationFeedbackGenerator()
        successHaptic?.prepare()
    }

    func stop() {
        guard isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        if !tonePlayer.isPlaying {
            audioEngine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        isRunning = false
        resetTrackingState()
        inputLevel = 0
        confidence = 0
        quality = .idle
        statusMessage = "メーターをタップして開始"
        debugText = ""
        lightHaptic = nil
        successHaptic = nil
    }

    func playSelectedTargetTone() {
        let target: GuitarTarget?
        if tuningMode == .guitarStandard {
            target = selectedGuitarTarget
        } else {
            target = nil
        }
        guard let target else { return }
        playTone(frequency: target.frequency)
    }

    func playTargetTone(at index: Int) {
        guard guitarTargets.indices.contains(index) else { return }
        playTone(frequency: guitarTargets[index].frequency)
    }

    // MARK: - Audio configuration

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try session.setPreferredSampleRate(44_100)
        try? session.setPreferredInputNumberOfChannels(1)
        try? session.setPreferredIOBufferDuration(0.023)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// `tonePlayer` を engine の mainMixer に繋いでおく。エンジンの起動状態は変えない。
    private func attachToneNodesIfNeeded() {
        if !isTonePlayerAttached {
            audioEngine.attach(tonePlayer)
            isTonePlayerAttached = true
        }
        if !isToneRouteConfigured {
            audioEngine.connect(tonePlayer, to: audioEngine.mainMixerNode, format: toneFormat)
            tonePlayer.volume = 1.0
            audioEngine.mainMixerNode.outputVolume = 1.0
            isToneRouteConfigured = true
        }
    }

    private func playTone(frequency: Double) {
        do {
            try configureAudioSession()
            attachToneNodesIfNeeded()
            if !audioEngine.isRunning {
                audioEngine.prepare()
                try audioEngine.start()
            }

            let sampleRate = toneFormat.sampleRate
            let samples = ToneGenerator.tuningForkTone(frequency: frequency, sampleRate: sampleRate, duration: 1.4)
            guard !samples.isEmpty else { return }
            let frameCount = AVAudioFrameCount(samples.count)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: toneFormat, frameCapacity: frameCount) else { return }
            buffer.frameLength = frameCount

            guard let channel = buffer.floatChannelData?[0] else { return }
            for frame in samples.indices {
                channel[frame] = samples[frame]
            }

            if tonePlayer.isPlaying {
                tonePlayer.stop()
            }
            tonePlayer.scheduleBuffer(buffer, at: nil, options: [.interrupts])
            tonePlayer.play()

            // 自分の鳴らした音で誤検出しないよう再生中はマイク解析をミュート
            muteAnalysisUntil = Date().addingTimeInterval(Double(samples.count) / sampleRate + 0.15)
        } catch {
            statusMessage = "再生失敗: \(error.localizedDescription)"
        }
    }

    // MARK: - Analysis pipeline

    private func applyAnalysisSnapshot(_ snapshot: AnalysisSnapshot) {
        let sensitivity = max(0.2, min(microphoneSensitivity, 4.0))
        let displayedLevel = min(1.0, max(Double(snapshot.rms) * 220.0 * sensitivity, Double(snapshot.peak) * 16.0 * sensitivity))
        inputLevel = CGFloat(displayedLevel)
        confidence = Double(snapshot.confidence)

        if showDebug {
            debugText = String(format: "%.0fHz %dfr RMS %.4f Peak %.4f conf %.2f %@", snapshot.sampleRate, snapshot.frameCount, snapshot.rms, snapshot.peak, snapshot.confidence, snapshot.formatText)
        } else {
            debugText = ""
        }

        if Date() < muteAnalysisUntil {
            return
        }

        let rmsThreshold = Float(0.0008 / Double(sensitivity))
        let peakThreshold = Float(0.004 / Double(sensitivity))
        let signalAvailable = snapshot.rms > rmsThreshold || snapshot.peak > peakThreshold

        guard signalAvailable, let frequency = snapshot.frequency else {
            handleSignalLoss(reason: signalAvailable ? .analyzing : .lowSignal)
            return
        }

        applyTuningResult(for: frequency)
    }

    private enum SignalLossReason { case lowSignal, analyzing }

    private func handleSignalLoss(reason: SignalLossReason) {
        let now = Date()
        let withinHold = now.timeIntervalSince(lastSignalDate) < signalHoldInterval

        if withinHold && hasStableSignal {
            // 直前の表示を保持して揺れを防ぐ
            return
        }

        hasStableSignal = false
        lockedIn = false
        consecutiveInTuneFrames = 0
        lockProgress = 0
        emaCents = nil
        emaFrequency = nil
        stableNoteIdentifier = nil

        if !withinHold {
            displayCents = 0
            rawCents = 0
            displayFrequency = 0
            detectedNote = "--"
            detectedOctave = nil
            matchedGuitarStringID = nil
        }

        switch reason {
        case .lowSignal:
            quality = .lowSignal
            statusMessage = "音を鳴らしてください"
        case .analyzing:
            quality = .analyzing
            statusMessage = "解析中…"
        }
    }

    private func applyTuningResult(for frequency: Double) {
        let allowedRange: ClosedRange<Double> = tuningMode == .guitarStandard
            ? guitarFrequencyRange
            : 30...2200
        guard allowedRange.contains(frequency) else {
            handleSignalLoss(reason: .analyzing)
            return
        }

        let smoothed = smoothFrequency(frequency)
        lastSignalDate = Date()
        hasStableSignal = true
        displayFrequency = smoothed

        switch tuningMode {
        case .chromatic:
            let result = Self.noteFromFrequency(smoothed, referenceFrequency: referenceFrequency)
            updateNoteDisplay(noteName: result.note, octave: result.octave, cents: result.cents)
            matchedGuitarStringID = nil

        case .guitarStandard:
            guard let match = guitarMatch(for: smoothed) else {
                handleSignalLoss(reason: .analyzing)
                return
            }
            let result = Self.noteFromFrequency(match.targetFrequency, referenceFrequency: referenceFrequency)
            matchedGuitarStringID = match.string.id
            if autoSelectGuitarString,
               let index = guitarStrings.firstIndex(where: { $0.id == match.string.id }),
               selectedGuitarStringIndex != index {
                selectedGuitarStringIndex = index
            }
            updateNoteDisplay(noteName: result.note, octave: result.octave, cents: match.cents)
        }
    }

    private func updateNoteDisplay(noteName: String, octave: Int, cents: Double) {
        let identifier = "\(noteName)\(octave)"
        let smoothedCents = smoothCents(cents, identifier: identifier)
        rawCents = cents
        displayCents = smoothedCents
        detectedNote = noteName
        detectedOctave = octave

        if abs(smoothedCents) < lockInCentsTolerance {
            consecutiveInTuneFrames += 1
            quality = .inTune
            statusMessage = "チューニングOK"
        } else {
            consecutiveInTuneFrames = 0
            lockedIn = false
            if smoothedCents > 0 {
                quality = .sharp
                statusMessage = abs(smoothedCents) < 15 ? "もう少し低く" : "高すぎます"
            } else {
                quality = .flat
                statusMessage = abs(smoothedCents) < 15 ? "もう少し高く" : "低すぎます"
            }
        }

        lockProgress = min(1.0, Double(consecutiveInTuneFrames) / Double(lockInRequiredFrames))
        if !lockedIn, consecutiveInTuneFrames >= lockInRequiredFrames {
            lockedIn = true
            triggerLockHaptic()
        } else if quality == .inTune, consecutiveInTuneFrames == 1 {
            lightHaptic?.impactOccurred(intensity: 0.5)
            lightHaptic?.prepare()
        }

        stableNoteIdentifier = identifier
    }

    private func smoothCents(_ cents: Double, identifier: String) -> Double {
        if stableNoteIdentifier != identifier {
            // ノートが変わったらスムージングをリセット
            emaCents = cents
            return cents
        }
        let alpha = abs(cents) < 8 ? 0.35 : 0.55
        if let previous = emaCents {
            let next = previous + (cents - previous) * alpha
            emaCents = next
            return next
        }
        emaCents = cents
        return cents
    }

    private func smoothFrequency(_ frequency: Double) -> Double {
        guard let previous = emaFrequency else {
            emaFrequency = frequency
            return frequency
        }
        let ratio = abs(frequency - previous) / max(previous, 1)
        if ratio > 0.18 {
            emaFrequency = frequency
            return frequency
        }
        let alpha = 0.4
        let next = previous + (frequency - previous) * alpha
        emaFrequency = next
        return next
    }

    private func triggerLockHaptic() {
        successHaptic?.notificationOccurred(.success)
        successHaptic?.prepare()
    }

    private func resetTrackingState() {
        emaCents = nil
        emaFrequency = nil
        consecutiveInTuneFrames = 0
        lockProgress = 0
        lockedIn = false
        stableNoteIdentifier = nil
        hasStableSignal = false
        matchedGuitarStringID = nil
        displayCents = 0
        rawCents = 0
        displayFrequency = 0
        detectedNote = "--"
        detectedOctave = nil
    }

    // MARK: - Guitar matching

    private func guitarMatch(for frequency: Double) -> GuitarMatch? {
        let candidates: [GuitarString]
        if autoSelectGuitarString {
            candidates = guitarStrings
        } else {
            guard guitarStrings.indices.contains(selectedGuitarStringIndex) else { return nil }
            candidates = [guitarStrings[selectedGuitarStringIndex]]
        }

        var best: GuitarMatch?
        for string in candidates {
            let openTarget = targetFrequency(for: string)
            for harmonic in 1...3 {
                let target = openTarget * Double(harmonic)
                let cents = 1200.0 * log2(frequency / target)
                if abs(cents) > 90 { continue }
                let match = GuitarMatch(string: string, targetFrequency: openTarget, cents: cents)
                if let current = best {
                    if abs(match.cents) < abs(current.cents) {
                        best = match
                    }
                } else {
                    best = match
                }
            }
        }

        if best == nil {
            // どの倍音にもマッチしなければ基音距離で最も近い弦
            best = candidates.map { string -> GuitarMatch in
                let target = targetFrequency(for: string)
                return GuitarMatch(string: string, targetFrequency: target, cents: 1200.0 * log2(frequency / target))
            }.min(by: { abs($0.cents) < abs($1.cents) })
        }
        return best
    }

    private var guitarFrequencyRange: ClosedRange<Double> {
        let targets = guitarStrings.map { targetFrequency(for: $0) }
        let low = max(40.0, (targets.min() ?? 70.0) * 0.6)
        let high = min(1500.0, (targets.max() ?? 360.0) * 4.4)
        return low...high
    }

    private func targetFrequency(for string: GuitarString) -> Double {
        let referenceRatio = referenceFrequency / 440.0
        let capoRatio = pow(2.0, Double(capoFret) / 12.0)
        return string.frequency * referenceRatio * capoRatio
    }

    // MARK: - DSP (analysis)

    nonisolated private static func analyze(buffer: AVAudioPCMBuffer, mode: TuningMode) -> AnalysisSnapshot {
        let sampleRate = buffer.format.sampleRate
        let frameCount = Int(buffer.frameLength)
        let formatText = formatDescription(buffer.format)
        guard sampleRate > 0, let raw = extractSamples(buffer: buffer), raw.count > 1024 else {
            return AnalysisSnapshot(frequency: nil, rms: 0, peak: 0, confidence: 0, sampleRate: sampleRate, frameCount: frameCount, formatText: formatText)
        }

        let centered = removeDCOffset(from: raw)
        let filtered = highPassFilter(centered, sampleRate: sampleRate, cutoff: 60)
        let rms = rootMeanSquare(filtered)
        let peak = maxAbsoluteValue(filtered)
        guard rms > 0.0002 || peak > 0.0008 else {
            return AnalysisSnapshot(frequency: nil, rms: rms, peak: peak, confidence: 0, sampleRate: sampleRate, frameCount: frameCount, formatText: formatText)
        }

        let pitch = yinPitch(samples: filtered, sampleRate: sampleRate, mode: mode)
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

    nonisolated private static func yinPitch(samples: [Float], sampleRate: Double, mode: TuningMode) -> (frequency: Double?, confidence: Float) {
        let minFrequency: Double
        let maxFrequency: Double
        switch mode {
        case .guitarStandard:
            minFrequency = 60
            maxFrequency = 1400
        case .chromatic:
            minFrequency = 50
            maxFrequency = 2000
        }

        let minTau = max(2, Int(sampleRate / maxFrequency))
        let maxTau = min(samples.count / 2, Int(sampleRate / minFrequency))
        guard maxTau > minTau + 4 else { return (nil, 0) }

        var difference = [Float](repeating: 0, count: maxTau + 1)
        for tau in minTau...maxTau {
            var sum: Float = 0
            let count = samples.count - tau
            var i = 0
            while i < count {
                let delta = samples[i] - samples[i + tau]
                sum += delta * delta
                i += 1
            }
            difference[tau] = sum
        }

        var cmnd = [Float](repeating: 1, count: maxTau + 1)
        var runningSum: Float = 0
        for tau in 1...maxTau {
            runningSum += difference[tau]
            if runningSum > 0 {
                cmnd[tau] = difference[tau] * Float(tau) / runningSum
            }
        }

        let threshold: Float = 0.15
        var tauEstimate: Int?
        var tau = minTau
        while tau < maxTau {
            if cmnd[tau] < threshold {
                var bestTau = tau
                while bestTau + 1 <= maxTau && cmnd[bestTau + 1] < cmnd[bestTau] {
                    bestTau += 1
                }
                tauEstimate = bestTau
                break
            }
            tau += 1
        }

        if tauEstimate == nil {
            // 閾値を満たさなかった場合は cmnd の最小値 (= 最も自己相関の高いタウ) を採用
            var minIdx = minTau
            var minVal = cmnd[minTau]
            for t in (minTau + 1)...maxTau {
                if cmnd[t] < minVal {
                    minVal = cmnd[t]
                    minIdx = t
                }
            }
            if minVal < 0.4 {
                tauEstimate = minIdx
            }
        }

        guard let chosenTau = tauEstimate else { return (nil, 0) }
        let confidence = max(0, min(1, 1 - cmnd[chosenTau]))
        guard confidence > 0.6 else { return (nil, confidence) }

        let refinedTau = parabolicInterpolation(values: cmnd, index: chosenTau)
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

    /// 1次 IIR ハイパスフィルタ。エアコン・PCノイズ・ハム成分を除去して低域の誤検出を抑える。
    nonisolated private static func highPassFilter(_ data: [Float], sampleRate: Double, cutoff: Double) -> [Float] {
        guard !data.isEmpty, sampleRate > 0, cutoff > 0 else { return data }
        let rc = 1.0 / (2.0 * .pi * cutoff)
        let dt = 1.0 / sampleRate
        let alpha = Float(rc / (rc + dt))

        var output = [Float](repeating: 0, count: data.count)
        var prevInput: Float = data[0]
        var prevOutput: Float = 0
        output[0] = 0
        for i in 1..<data.count {
            let current = data[i]
            let value = alpha * (prevOutput + current - prevInput)
            output[i] = value
            prevOutput = value
            prevInput = current
        }
        return output
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
        case .pcmFormatFloat32: commonFormat = "f32"
        case .pcmFormatFloat64: commonFormat = "f64"
        case .pcmFormatInt16: commonFormat = "i16"
        case .pcmFormatInt32: commonFormat = "i32"
        case .otherFormat: commonFormat = "other"
        @unknown default: commonFormat = "unknown"
        }
        return "\(commonFormat)/\(format.channelCount)ch"
    }

    nonisolated private static func noteFromFrequency(_ frequency: Double, referenceFrequency: Double) -> (note: String, octave: Int, cents: Double) {
        let midi = 69.0 + 12.0 * log2(frequency / referenceFrequency)
        let roundedMidi = round(midi)
        let cents = (midi - roundedMidi) * 100.0

        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let noteIndex = Int((roundedMidi.truncatingRemainder(dividingBy: 12) + 12).truncatingRemainder(dividingBy: 12))
        let octave = Int(roundedMidi / 12.0) - 1
        return (names[noteIndex], octave, cents)
    }
}
