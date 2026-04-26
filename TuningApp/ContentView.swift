import SwiftUI

struct ContentView: View {
    @StateObject private var detector = PitchDetector()
    @State private var targetDragProgress: Double = 0
    @State private var isChangingTarget = false

    var body: some View {
        VStack(spacing: 12) {
            modePicker
            tunerDisplay
            meter
            inputControls

            if detector.tuningMode == .guitarStandard {
                guitarControls
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            detector.requestPermission()
        }
    }

    private var modePicker: some View {
        Picker("モード", selection: $detector.tuningMode) {
            ForEach(PitchDetector.TuningMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var tunerDisplay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(.background)
                .shadow(color: .black.opacity(0.05), radius: 8, y: 4)

            if detector.tuningMode == .guitarStandard {
                VStack(spacing: 8) {
                    Text("目標")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    GeometryReader { geometry in
                        ZStack {
                            ForEach(visibleTargetIndices, id: \.self) { index in
                                targetCylinderItem(index: index, width: geometry.size.width)
                            }

                            VStack(spacing: 0) {
                                LinearGradient(
                                    colors: [Color(.systemBackground), Color(.systemBackground).opacity(0)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: 18)

                                Spacer()

                                LinearGradient(
                                    colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: 18)
                            }
                            .allowsHitTesting(false)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.horizontal)
                .clipped()
            } else {
                targetContent(note: primaryTargetNote, detail: primaryTargetDetail, showHint: false)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    guard detector.tuningMode == .guitarStandard, !isChangingTarget else { return }
                    let horizontal = value.translation.width
                    let vertical = value.translation.height
                    guard abs(horizontal) > abs(vertical) else { return }
                    targetDragProgress = max(-0.95, min(0.95, -Double(horizontal / 120)))
                }
                .onEnded { value in
                    guard detector.tuningMode == .guitarStandard else { return }
                    let horizontal = value.translation.width
                    let vertical = value.translation.height
                    guard abs(horizontal) > abs(vertical), abs(horizontal) > 36 else {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            targetDragProgress = 0
                        }
                        return
                    }
                    changeSelectedGuitarTarget(by: horizontal < 0 ? 1 : -1)
                }
        )
    }

    private var meter: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("現在")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(detector.detectedNote)
                        .font(.title2.weight(.bold))
                }

                Spacer()

                Text(detector.frequencyText)
                    .font(.title3)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(detector.tuningStatus)
                .font(.headline)
                .foregroundStyle(meterColor)

            GeometryReader { geometry in
                ZStack(alignment: .center) {
                    Capsule()
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 12)

                    Rectangle()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 2, height: 28)

                    Circle()
                        .fill(meterColor)
                        .frame(width: 22, height: 22)
                        .offset(x: detector.centsOffset * (geometry.size.width / 100.0))
                }
            }
            .frame(height: 28)

            HStack {
                Text("-50c")
                Spacer()
                Text("0")
                Spacer()
                Text("+50c")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(detector.isRunning ? "メーターをタップして停止" : "メーターをタップして開始")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(detector.isRunning ? Color.clear : Color.red.opacity(0.55), lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture {
            detector.isRunning ? detector.stop() : detector.start()
        }
    }

    private var inputControls: some View {
        VStack(spacing: 10) {
            ProgressView(value: detector.inputLevel)
                .progressViewStyle(.linear)

            VStack(spacing: 4) {
                HStack {
                    Text("マイク感度")
                    Spacer()
                    Text(String(format: "%.1fx", detector.microphoneSensitivity))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Slider(value: $detector.microphoneSensitivity, in: 0.1...8.0, step: 0.1) {
                    Text("マイク感度")
                }
            }

            HStack {
                Text(detector.confidenceText)
                Spacer()
                Text(detector.inputDebugText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var guitarControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ギター設定")
                .font(.headline)

            Stepper(value: $detector.referenceFrequency, in: 430...450, step: 0.5) {
                HStack {
                    Text("基準ピッチ A4")
                    Spacer()
                    Text(String(format: "%.1f Hz", detector.referenceFrequency))
                        .monospacedDigit()
                }
            }

            HStack {
                Text("カポ")
                Spacer()

                Picker("カポ", selection: $detector.capoFret) {
                    ForEach(0...12, id: \.self) { fret in
                        Text(fret == 0 ? "なし" : "\(fret)").tag(fret)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var primaryTargetNote: String {
        if detector.tuningMode == .guitarStandard, let target = detector.selectedGuitarTarget {
            return target.note
        }
        return detector.detectedNote
    }

    private var primaryTargetDetail: String {
        if detector.tuningMode == .guitarStandard, let target = detector.selectedGuitarTarget {
            return String(format: "%@ / %.2f Hz", target.label, target.frequency)
        }
        return detector.targetNoteText
    }

    private var meterColor: Color {
        detector.isRunning ? detector.tuningColor : .red
    }

    private var currentTargetIndex: Int {
        Int(detector.selectedGuitarStringIndex.rounded())
    }

    private var visibleTargetIndices: [Int] {
        (-2...2).compactMap { offset in
            let index = currentTargetIndex + offset
            return detector.guitarTargets.indices.contains(index) ? index : nil
        }
    }

    private func targetContent(note: String, detail: String, showHint: Bool) -> some View {
        VStack(spacing: 8) {
            Text("目標")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(note)
                .font(.system(size: 72, weight: .heavy, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()

            Text(detail)
                .font(.title3)
                .foregroundStyle(.secondary)

            EmptyView()
        }
        .padding(.vertical, 24)
        .padding(.horizontal)
    }

    private func targetCylinderItem(index: Int, width: CGFloat) -> some View {
        let target = detector.guitarTargets[index]
        let relativePosition = Double(index - currentTargetIndex) - targetDragProgress
        let angle = relativePosition * 42.0
        let radians = angle * .pi / 180
        let depth = max(0.12, cos(radians))
        let side = sin(radians)
        let radius = min(width * 0.46, 168)
        let isFront = abs(relativePosition) < 0.08

        return VStack(spacing: 8) {
            Text(target.note)
                .font(.system(size: isFront ? 72 : 44, weight: .heavy, design: .rounded))
                .foregroundStyle(isFront ? Color.primary : Color.secondary)
                .monospacedDigit()

            Text(isFront ? String(format: "%@ / %.2f Hz", target.label, target.frequency) : target.label)
                .font(isFront ? .title3 : .caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: isFront ? 220 : 120)
        .scaleEffect(0.68 + 0.32 * depth)
        .offset(x: CGFloat(side) * radius)
        .opacity(0.18 + 0.82 * depth)
        .blur(radius: (1 - depth) * 1.4)
        .zIndex(depth)
    }

    private func changeSelectedGuitarTarget(by offset: Int) {
        guard !isChangingTarget else { return }
        let current = Int(detector.selectedGuitarStringIndex.rounded())
        let next = min(5, max(0, current + offset))
        guard next != current else { return }

        isChangingTarget = true
        let endProgress = Double(offset)

        withAnimation(.easeOut(duration: 0.22)) {
            targetDragProgress = endProgress
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            detector.selectedGuitarStringIndex = Double(next)
            targetDragProgress = 0
            detector.playSelectedTargetTone()

            isChangingTarget = false
        }
    }
}

#Preview {
    ContentView()
}
