import SwiftUI

struct ContentView: View {
    @StateObject private var detector = PitchDetector()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            backgroundLayer
                .ignoresSafeArea()

            VStack(spacing: 18) {
                topBar
                modeSelector
                NoteHeroCard(detector: detector)
                ArcMeterView(detector: detector)
                if detector.tuningMode == .guitarStandard {
                    GuitarStringSelector(detector: detector)
                }
                Spacer(minLength: 0)
                bottomBar
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 18)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(detector: detector)
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            detector.requestPermission()
        }
    }

    private var backgroundLayer: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.07, blue: 0.12),
                Color(red: 0.10, green: 0.14, blue: 0.20)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var topBar: some View {
        HStack {
            Text("Tuner")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.white.opacity(0.08), in: Circle())
            }
        }
    }

    private var modeSelector: some View {
        Picker("モード", selection: $detector.tuningMode) {
            ForEach(PitchDetector.TuningMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(4)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            StartStopButton(detector: detector)

            Button {
                detector.playSelectedTargetTone()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.title3.weight(.semibold))
                    Text("お手本")
                        .font(.caption2.weight(.semibold))
                }
                .frame(width: 64, height: 64)
                .foregroundStyle(.white)
                .background(.white.opacity(0.08), in: Circle())
            }
            .disabled(detector.tuningMode != .guitarStandard)
            .opacity(detector.tuningMode == .guitarStandard ? 1.0 : 0.35)
        }
    }
}

// MARK: - 大型ノートカード

private struct NoteHeroCard: View {
    @ObservedObject var detector: PitchDetector

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(detector.detectedNote == "--" ? "—" : detector.detectedNote)
                    .font(.system(size: 88, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                if let octave = detector.detectedOctave {
                    Text("\(octave)")
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .baselineOffset(-8)
                }
            }
            .frame(maxWidth: .infinity)

            Text(detector.frequencyText)
                .font(.system(.title3, design: .rounded).weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()

            if detector.tuningMode == .guitarStandard, let target = detector.activeGuitarTarget {
                HStack(spacing: 6) {
                    Image(systemName: "target")
                    Text("目標: \(target.label) \(target.note) (\(String(format: "%.1f Hz", target.frequency)))")
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.55))
            } else {
                Text("基準ピッチ A4 = \(String(format: "%.1f Hz", detector.referenceFrequency))")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(.white.opacity(0.04))
        )
    }
}

// MARK: - アーク針メーター

private struct ArcMeterView: View {
    @ObservedObject var detector: PitchDetector

    private let arcSpan: Double = 90      // ±50¢ をマップする角度幅 (上半円)
    private let centsRange: Double = 50

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                let radius = min(proxy.size.width / 2 - 24, proxy.size.height - 36)
                let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height - 12)

                ZStack {
                    arcBackground(center: center, radius: radius)
                    arcGradient(center: center, radius: radius)
                    inTuneZone(center: center, radius: radius)
                    tickMarks(center: center, radius: radius)
                    tickLabels(center: center, radius: radius)
                    needle(center: center, radius: radius)
                    pivot(center: center)
                }
                .overlay(alignment: .top) {
                    centerLabels
                        .frame(width: proxy.size.width)
                        .padding(.top, 18)
                }
            }
            .frame(height: 170)
            .padding(.horizontal, 12)

            statusLabel
        }
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(.white.opacity(0.04))
        )
    }

    private func arcBackground(center: CGPoint, radius: CGFloat) -> some View {
        ArcPath(center: center, radius: radius, startDegrees: -arcSpan, endDegrees: arcSpan)
            .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 14, lineCap: .round))
    }

    private func arcGradient(center: CGPoint, radius: CGFloat) -> some View {
        ArcPath(center: center, radius: radius, startDegrees: -arcSpan, endDegrees: arcSpan)
            .stroke(
                AngularGradient(
                    gradient: Gradient(colors: [
                        Color.red.opacity(0.85),
                        Color.orange.opacity(0.85),
                        Color.green.opacity(0.95),
                        Color.green.opacity(0.95),
                        Color.orange.opacity(0.85),
                        Color.red.opacity(0.85)
                    ]),
                    center: UnitPoint(x: 0.5, y: 1.0),
                    startAngle: .degrees(-arcSpan - 90),
                    endAngle: .degrees(arcSpan - 90)
                ),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .opacity(detector.hasStableSignal ? 1.0 : 0.3)
    }

    private func inTuneZone(center: CGPoint, radius: CGFloat) -> some View {
        let zoneAngle = arcSpan * (5.0 / centsRange)
        return ArcPath(center: center, radius: radius, startDegrees: -zoneAngle, endDegrees: zoneAngle)
            .stroke(Color.green.opacity(detector.quality == .inTune ? 0.9 : 0.3),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round))
            .animation(.easeInOut(duration: 0.18), value: detector.quality == .inTune)
    }

    private func tickMarks(center: CGPoint, radius: CGFloat) -> some View {
        ZStack {
            ForEach(tickValues, id: \.self) { value in
                let isMajor = value == 0 || abs(value) == 50
                let angle = angleFor(cents: Double(value))
                let radians = angle * .pi / 180.0
                let outerR = radius + 7
                let innerR = radius - (isMajor ? 16 : 9)
                Path { path in
                    path.move(to: point(center: center, radius: outerR, radians: radians))
                    path.addLine(to: point(center: center, radius: innerR, radians: radians))
                }
                .stroke(Color.white.opacity(isMajor ? 0.7 : 0.3), lineWidth: isMajor ? 2.5 : 1.2)
            }
        }
    }

    private func tickLabels(center: CGPoint, radius: CGFloat) -> some View {
        ZStack {
            ForEach([-50, 0, 50], id: \.self) { value in
                let angle = angleFor(cents: Double(value))
                let radians = angle * .pi / 180.0
                let pos = point(center: center, radius: radius - 30, radians: radians)
                Text(value == 0 ? "0" : (value > 0 ? "+50" : "-50"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .position(pos)
            }
        }
    }

    private var tickValues: [Int] { [-50, -30, -15, -5, 0, 5, 15, 30, 50] }

    private func needle(center: CGPoint, radius: CGFloat) -> some View {
        let angle = angleFor(cents: detector.displayCents)
        let length = radius - 4
        // 針のレイアウトフレームの「下端」がメーター中心 (center) に来るよう配置し、
        // anchor: .bottom で回転させることで根元がブレずに針が動く。
        return Capsule()
            .fill(LinearGradient(colors: [needleColor, needleColor.opacity(0.4)], startPoint: .top, endPoint: .bottom))
            .frame(width: 4, height: length)
            .rotationEffect(.degrees(angle), anchor: .bottom)
            .position(x: center.x, y: center.y - length / 2)
            .opacity(detector.hasStableSignal ? 1.0 : 0.35)
            .animation(.spring(response: 0.2, dampingFraction: 0.85), value: detector.displayCents)
    }

    private func pivot(center: CGPoint) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(needleColor, lineWidth: 3))
            .position(center)
    }

    private var needleColor: Color {
        switch detector.quality {
        case .inTune: return .green
        case .sharp, .flat: return abs(detector.displayCents) < 15 ? .orange : .red
        case .lowSignal, .analyzing, .idle: return .white
        }
    }

    private var centerLabels: some View {
        VStack(spacing: 2) {
            Text(detector.displayCentsString)
                .font(.system(.title, design: .rounded).weight(.heavy))
                .foregroundStyle(needleColor)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(detector.statusMessage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    private var statusLabel: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(detector.isRunning ? Color.green : Color.red.opacity(0.85))
                    .frame(width: 8, height: 8)
                Text(detector.isRunning ? "検出中" : "停止中")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Text(detector.confidenceText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .monospacedDigit()
        }
        .padding(.horizontal, 18)
    }

    private func angleFor(cents: Double) -> Double {
        let clamped = max(-centsRange, min(centsRange, cents))
        return clamped / centsRange * arcSpan
    }

    private func point(center: CGPoint, radius: CGFloat, radians: Double) -> CGPoint {
        CGPoint(
            x: center.x + CGFloat(sin(radians)) * radius,
            y: center.y - CGFloat(cos(radians)) * radius
        )
    }
}

private struct ArcPath: Shape {
    let center: CGPoint
    let radius: CGFloat
    let startDegrees: Double
    let endDegrees: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let startAngle = Angle(degrees: -90 + startDegrees)
        let endAngle = Angle(degrees: -90 + endDegrees)
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        return path
    }
}

// MARK: - ギター弦カルーセル

private struct GuitarStringSelector: View {
    @ObservedObject var detector: PitchDetector

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("弦を選択")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))

                Spacer()

                Text("自動判定")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(detector.autoSelectGuitarString ? 0.95 : 0.55))
                Toggle("", isOn: $detector.autoSelectGuitarString)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(.green)
            }

            HStack(spacing: 8) {
                ForEach(Array(detector.guitarTargets.enumerated()), id: \.element.id) { index, target in
                    let isSelected = detector.selectedGuitarStringIndex == index
                    let isMatched = detector.matchedGuitarStringID == target.id && detector.hasStableSignal
                    Button {
                        if detector.autoSelectGuitarString {
                            detector.autoSelectGuitarString = false
                        }
                        detector.selectedGuitarStringIndex = index
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        VStack(spacing: 2) {
                            Text(target.note)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(isSelected ? Color.black : Color.white)
                            Text(target.label)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(isSelected ? Color.black.opacity(0.7) : Color.white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isSelected ? Color.white : Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isMatched ? Color.green : Color.clear, lineWidth: 2)
                        )
                        .scaleEffect(isMatched ? 1.04 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isMatched)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.white.opacity(0.04))
        )
    }
}

// MARK: - スタートボタン

private struct StartStopButton: View {
    @ObservedObject var detector: PitchDetector

    var body: some View {
        Button {
            detector.toggle()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: detector.isRunning ? "stop.fill" : "play.fill")
                    .font(.title3.weight(.bold))
                Text(detector.isRunning ? "停止" : "開始")
                    .font(.title3.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: detector.isRunning
                        ? [Color.red.opacity(0.85), Color.pink.opacity(0.85)]
                        : [Color.green.opacity(0.9), Color.teal.opacity(0.9)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .shadow(color: (detector.isRunning ? Color.red : Color.green).opacity(0.35), radius: 12, y: 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 設定シート

private struct SettingsSheet: View {
    @ObservedObject var detector: PitchDetector
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("音響") {
                    Stepper(value: $detector.referenceFrequency, in: 415...466, step: 0.5) {
                        HStack {
                            Text("基準ピッチ A4")
                            Spacer()
                            Text(String(format: "%.1f Hz", detector.referenceFrequency))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if detector.tuningMode == .guitarStandard {
                    Section("ギター") {
                        Toggle("自動で弦を判定", isOn: $detector.autoSelectGuitarString)

                        Picker("カポ", selection: $detector.capoFret) {
                            ForEach(0...12, id: \.self) { fret in
                                Text(fret == 0 ? "なし" : "\(fret)").tag(fret)
                            }
                        }
                    }
                }

                Section("マイク") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("感度")
                            Spacer()
                            Text(String(format: "%.1fx", detector.microphoneSensitivity))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $detector.microphoneSensitivity, in: 0.3...3.0, step: 0.1)
                    }

                    HStack {
                        Text("入力レベル")
                        Spacer()
                        ProgressView(value: Double(detector.inputLevel))
                            .progressViewStyle(.linear)
                            .frame(width: 120)
                    }
                }

                Section("詳細") {
                    Toggle("デバッグ情報を表示", isOn: $detector.showDebug)
                    if detector.showDebug, !detector.debugText.isEmpty {
                        Text(detector.debugText)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("チューニング精度を上げるコツ: 静かな場所で楽器をマイクに近づけ、しっかり音を伸ばして弾いてください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
