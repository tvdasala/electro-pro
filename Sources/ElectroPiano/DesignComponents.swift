import AppKit
import SwiftUI

// MARK: - Localization Helper (Bundle.module String Catalog)

func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}

// MARK: - Accent Color Options (Settings > Appearance)

enum AccentOption: Int, CaseIterable, Identifiable {
    case nordRed = 0
    case studioBlue = 1
    case warmAmber = 2
    case neutralSilver = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .nordRed: return L("Nord Red (Default)")
        case .studioBlue: return L("Studio Blue")
        case .warmAmber: return L("Analog Amber")
        case .neutralSilver: return L("Neutral Silver")
        }
    }

    var color: Color {
        switch self {
        case .nordRed:
            return Color("AccentColor", bundle: .module)
        case .studioBlue:
            return Color(red: 0x2E / 255.0, green: 0x7C / 255.0, blue: 0xF6 / 255.0)
        case .warmAmber:
            return Color(red: 0xE0 / 255.0, green: 0x8A / 255.0, blue: 0x1E / 255.0)
        case .neutralSilver:
            return Color(red: 0xD8 / 255.0, green: 0xD8 / 255.0, blue: 0xDE / 255.0)
        }
    }
}

// MARK: - Visual Tokens (macOS 26 Tahoe Visual Direction)

@MainActor
enum StudioTokens {
    // Solid content surfaces (No Glass)
    static let surfaceWindow = Color(red: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x16 / 255.0)   // #141416
    static let surfacePanel = Color(red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1F / 255.0)    // #1C1C1F
    static let surfaceControl = Color(red: 0x26 / 255.0, green: 0x26 / 255.0, blue: 0x2A / 255.0)  // #26262A
    static let borderHairline = Color(red: 0x2F / 255.0, green: 0x2F / 255.0, blue: 0x34 / 255.0)  // #2F2F34

    // WCAG AA contrast text (>= 4.5:1 on #141416 and #1C1C1F)
    static let textPrimary = Color(red: 0xED / 255.0, green: 0xED / 255.0, blue: 0xEF / 255.0)     // #EDEDEF
    static let textSecondary = Color(red: 0x9A / 255.0, green: 0x9A / 255.0, blue: 0xA2 / 255.0)   // #9A9AA2
    static let textDisabled = Color(red: 0x5A / 255.0, green: 0x5A / 255.0, blue: 0x62 / 255.0)    // #5A5A62

    // Active accent (used ONLY on: knob value arc, selected layer border+dot, and meter peak)
    static var accent: Color {
        PianoViewModel.shared?.accentOption.color ?? Color("AccentColor", bundle: .module)
    }

    // Audio meters (green -> yellow -> red)
    static let meterGreen = Color(red: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x58 / 255.0)
    static let meterYellow = Color(red: 0xFF / 255.0, green: 0xD6 / 255.0, blue: 0x0A / 255.0)
    static let meterRed = Color(red: 0xD6 / 255.0, green: 0x20 / 255.0, blue: 0x2A / 255.0)

    // Layer zone visualization colors on the 61-key keyboard
    static let layerZoneColors: [Color] = [
        Color(red: 0xD6 / 255.0, green: 0x20 / 255.0, blue: 0x2A / 255.0), // Layer A
        Color(red: 0x2E / 255.0, green: 0x7C / 255.0, blue: 0xF6 / 255.0), // Layer B
        Color(red: 0xE0 / 255.0, green: 0x8A / 255.0, blue: 0x1E / 255.0), // Layer C
        Color(red: 0x26 / 255.0, green: 0xA6 / 255.0, blue: 0x6B / 255.0)  // Layer D
    ]

    // 8pt base grid
    static let grid1: CGFloat = 8
    static let grid2: CGFloat = 16
    static let grid3: CGFloat = 24
    static let panelRadius: CGFloat = 10
    static let controlRadius: CGFloat = 6

    // Typography scale (SF Pro, minimum 11pt)
    static let fontLabel = Font.system(size: 11, weight: .medium)
    static let fontSectionCaps = Font.system(size: 11, weight: .semibold)
    static let fontBody = Font.system(size: 12, weight: .regular)
    static let fontBodyMedium = Font.system(size: 12, weight: .medium)
    static let fontValue = Font.system(size: 13, weight: .medium).monospacedDigit()
    static let fontValueSemibold = Font.system(size: 13, weight: .semibold).monospacedDigit()
    static let fontSectionTitle = Font.system(size: 15, weight: .semibold)
}

// MARK: - Solid Section Card (Dark Solid Surface #1C1C1F, No Glass, Row-matched Height)

struct SectionCard<HeaderTrailing: View, Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let headerTrailing: HeaderTrailing
    @ViewBuilder let content: Content

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder headerTrailing: () -> HeaderTrailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.headerTrailing = headerTrailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text(title)
                    .font(StudioTokens.fontSectionTitle)
                    .foregroundStyle(StudioTokens.textPrimary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                headerTrailing
            }

            Divider()
                .overlay(StudioTokens.borderHairline)

            content
                .frame(maxWidth: .infinity, alignment: .topLeading)

            Spacer(minLength: 0)
        }
        .padding(StudioTokens.grid2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            StudioTokens.surfacePanel,
            in: .rect(cornerRadius: StudioTokens.panelRadius)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StudioTokens.panelRadius)
                .stroke(
                    (differentiateWithoutColor || colorSchemeContrast == .increased)
                        ? StudioTokens.textSecondary.opacity(0.65)
                        : StudioTokens.borderHairline,
                    lineWidth: 1
                )
        )
    }
}

// MARK: - ProKnob (Flat, No Glass, 56pt / 48pt / 36pt, Double-Click Value Entry, Accessible)

struct ProKnob: View {
    var idKey: String = ""
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var step: Double = 0.0
    var unitSuffix: String = ""
    let valueFormatter: (Double) -> String
    var size: CGFloat = 48
    var enabled: Bool = true

    @State private var dragStartValue: Double? = nil
    @State private var showDragBubble: Bool = false
    @State private var bubbleHideTask: Task<Void, Never>? = nil
    @State private var isEditingText: Bool = false
    @State private var textInput: String = ""
    @FocusState private var isTextFieldFocused: Bool
    @FocusState private var isKnobFocused: Bool

    private var effectiveKey: String { idKey.isEmpty ? title : idKey }
    private var isLearning: Bool { PianoViewModel.shared?.activeMidiLearnKey == effectiveKey }
    private var mappedCC: Int? { PianoViewModel.shared?.knobMidiMappings[effectiveKey] }
    private var span: Double { range.upperBound - range.lowerBound }

    private var normalized: Double {
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0.0), 1.0)
    }

    /// Arc origin: center for bipolar controls (e.g., -15..+15 dB), otherwise base (0.0).
    private var arcOrigin: Double {
        (range.lowerBound < 0 && range.upperBound > 0 && span > 0) ? (-range.lowerBound / span) : 0.0
    }

    private var columnWidth: CGFloat {
        if size >= 54 { return 90 }
        if size <= 38 { return 72 }
        return 78
    }

    private var travelPixels: Double {
        if step > 0 && span > 0 {
            return min(max((span / step) * 6.5, 160.0), 720.0)
        }
        return 220.0
    }

    private func clampAndSnap(_ v: Double) -> Double {
        var next = min(max(v, range.lowerBound), range.upperBound)
        if step > 0 {
            next = (next / step).rounded() * step
        }
        return min(max(next, range.lowerBound), range.upperBound)
    }

    private func nudge(_ direction: Double, fine: Bool = false) {
        guard enabled else { return }
        PianoViewModel.shared?.recordDiscreteUndoStep()
        let baseStep = step > 0 ? step : (span / (fine ? 400.0 : 100.0))
        value = clampAndSnap(value + direction * baseStep)
    }

    private func commitTextEntry() {
        let cleaned = textInput
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { "0123456789.-+".contains($0) }
        if let parsed = Double(cleaned) {
            PianoViewModel.shared?.recordDiscreteUndoStep()
            value = clampAndSnap(parsed)
        }
        isEditingText = false
        isTextFieldFocused = false
    }

    var body: some View {
        VStack(spacing: 4) {
            // Top label (11pt Sentence case) + mapped CC badge
            HStack(spacing: 3) {
                Text(title)
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(enabled ? StudioTokens.textSecondary : StudioTokens.textDisabled)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if let cc = mappedCC {
                    Text(verbatim: "CC\(cc)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(enabled ? StudioTokens.accent : StudioTokens.textDisabled)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(height: 16)

            // Flat Canvas dial (no glass, no gloss, no bevel)
            dialCanvas
                .frame(width: size, height: size)
                .contentShape(Rectangle())
                .focusable(enabled)
                .focused($isKnobFocused)
                .focusEffectDisabled()
                .overlay {
                    if isKnobFocused {
                        Circle()
                            .stroke(StudioTokens.textPrimary.opacity(0.85), lineWidth: 1.5)
                            .padding(-3)
                    }
                }
                .overlay(alignment: .top) {
                    dragBubbleOverlay
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            guard enabled else { return }
                            if dragStartValue == nil {
                                dragStartValue = value
                                PianoViewModel.shared?.beginParameterInteraction()
                            }
                            bubbleHideTask?.cancel()
                            if !showDragBubble {
                                withAnimation(.easeOut(duration: 0.12)) {
                                    showDragBubble = true
                                }
                            }
                            let origin = dragStartValue ?? value
                            let isFine = NSEvent.modifierFlags.contains(.shift)
                            let px = travelPixels * (isFine ? 4.0 : 1.0)
                            let ty = Double(gesture.translation.height)
                            let tx = Double(gesture.translation.width)
                            let deltaPx = -ty + tx * 0.5
                            value = clampAndSnap(origin + (deltaPx / px) * span)
                        }
                        .onEnded { _ in
                            dragStartValue = nil
                            PianoViewModel.shared?.endParameterInteraction()
                            bubbleHideTask?.cancel()
                            bubbleHideTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                guard !Task.isCancelled else { return }
                                withAnimation(.easeOut(duration: 0.25)) {
                                    showDragBubble = false
                                }
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    guard enabled else { return }
                    PianoViewModel.shared?.recordDiscreteUndoStep()
                    value = defaultValue
                }
                .onKeyPress(.upArrow) {
                    nudge(1, fine: NSEvent.modifierFlags.contains(.shift))
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    nudge(1, fine: NSEvent.modifierFlags.contains(.shift))
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    nudge(-1, fine: NSEvent.modifierFlags.contains(.shift))
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    nudge(-1, fine: NSEvent.modifierFlags.contains(.shift))
                    return .handled
                }

            // Numeric value readout below (13pt monospacedDigit) — double-click to type
            valueReadout
                .frame(height: 20)
        }
        .frame(width: columnWidth)
        .opacity(enabled ? 1.0 : 0.55)
        .onAppear {
            PianoViewModel.shared?.registerKnob(idKey: effectiveKey, range: range, step: step) { nextVal in
                value = nextVal
            }
        }
        .contextMenu { midiContextMenu }
        .help(tooltipText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(valueFormatter(value))
        .accessibilityHint(L("Drag or use arrow keys to adjust. Double-click to reset to default."))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    @ViewBuilder
    private var dragBubbleOverlay: some View {
        if showDragBubble {
            let formatted = valueFormatter(value)
            Text(verbatim: formatted)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(StudioTokens.textPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(StudioTokens.surfaceControl, in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(StudioTokens.borderHairline, lineWidth: 1)
                )
                .fixedSize()
                .offset(y: -26)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private var tooltipText: String {
        var base = "\(title): \(valueFormatter(value))"
        if let cc = mappedCC {
            base += " (\(String(localized: "Mapped to MIDI CC \(cc)", bundle: .module)))"
        }
        base += " — \(L("Drag to adjust, hold Shift for fine control, double-click knob to reset, double-click value to type, right-click for MIDI Learn."))"
        return base
    }

    private var dialCanvas: some View {
        let lo = min(arcOrigin, normalized)
        let hi = max(arcOrigin, normalized)
        let activeColor = isLearning ? StudioTokens.meterRed : (enabled ? StudioTokens.accent : StudioTokens.textDisabled)
        let pointerColor = enabled ? StudioTokens.textPrimary : StudioTokens.textDisabled

        return Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let lineWidth: CGFloat = 3.0
            let radius = (min(canvasSize.width, canvasSize.height) / 2) - lineWidth
            let bodyRadius = radius - 4.0

            // Inner flat disc (#26262A with #2F2F34 hairline border)
            let bodyRect = CGRect(
                x: center.x - bodyRadius,
                y: center.y - bodyRadius,
                width: bodyRadius * 2,
                height: bodyRadius * 2
            )
            let bodyPath = Path(ellipseIn: bodyRect)
            context.fill(bodyPath, with: .color(StudioTokens.surfaceControl))
            context.stroke(bodyPath, with: .color(StudioTokens.borderHairline), lineWidth: 1.0)

            // Neutral 3pt track (270 degrees: 135° to 405°)
            var trackPath = Path()
            trackPath.addArc(
                center: center,
                radius: radius,
                startAngle: .degrees(135),
                endAngle: .degrees(405),
                clockwise: false
            )
            context.stroke(
                trackPath,
                with: .color(StudioTokens.borderHairline),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )

            // Accent fill arc
            let startDeg = 135.0 + lo * 270.0
            let endDeg = 135.0 + max(hi, lo + 0.004) * 270.0
            var valuePath = Path()
            valuePath.addArc(
                center: center,
                radius: radius,
                startAngle: .degrees(startDeg),
                endAngle: .degrees(endDeg),
                clockwise: false
            )
            context.stroke(
                valuePath,
                with: .color(activeColor),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )

            // Crisp pointer line
            let angleRad = (135.0 + normalized * 270.0) * .pi / 180.0
            let innerR = bodyRadius * 0.28
            let outerR = bodyRadius * 0.82
            var pointerPath = Path()
            pointerPath.move(to: CGPoint(
                x: center.x + CGFloat(cos(angleRad)) * innerR,
                y: center.y + CGFloat(sin(angleRad)) * innerR
            ))
            pointerPath.addLine(to: CGPoint(
                x: center.x + CGFloat(cos(angleRad)) * outerR,
                y: center.y + CGFloat(sin(angleRad)) * outerR
            ))
            context.stroke(
                pointerPath,
                with: .color(pointerColor),
                style: StrokeStyle(lineWidth: 2.0, lineCap: .round)
            )
        }
    }

    @ViewBuilder
    private var valueReadout: some View {
        if isEditingText && enabled {
            TextField(L("Value"), text: $textInput)
                .textFieldStyle(.plain)
                .font(StudioTokens.fontValueSemibold)
                .foregroundStyle(StudioTokens.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .frame(width: 68)
                .background(
                    StudioTokens.surfaceControl,
                    in: .rect(cornerRadius: 4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(StudioTokens.textSecondary, lineWidth: 1)
                )
                .focused($isTextFieldFocused)
                .onSubmit { commitTextEntry() }
                .onExitCommand {
                    isEditingText = false
                    isTextFieldFocused = false
                }
        } else {
            Text(verbatim: isLearning ? L("Learn…") : valueFormatter(value))
                .font(StudioTokens.fontValue)
                .foregroundStyle(
                    isLearning
                        ? StudioTokens.accent
                        : (enabled ? StudioTokens.textPrimary : StudioTokens.textDisabled)
                )
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    guard enabled else { return }
                    if step >= 1.0 {
                        textInput = String(format: "%.0f", value)
                    } else {
                        textInput = String(format: "%.1f", value)
                    }
                    isEditingText = true
                    isTextFieldFocused = true
                }
        }
    }

    @ViewBuilder
    private var midiContextMenu: some View {
        Text(verbatim: "\(title) — \(valueFormatter(value))")
        if let cc = mappedCC {
            Text(String(localized: "Mapped to MIDI CC \(cc)", bundle: .module))
        } else {
            Text(L("No MIDI CC assigned"))
        }
        Divider()
        Button(isLearning ? L("Cancel MIDI Learn") : L("Learn MIDI CC (MIDI Learn)")) {
            PianoViewModel.shared?.startKnobMidiLearn(idKey: effectiveKey)
        }
        Menu(L("Assign CC Manually")) {
            ForEach([1, 2, 4, 7, 10, 11, 64, 71, 72, 73, 74, 91, 93], id: \.self) { cc in
                Button(String(localized: "CC \(cc)", bundle: .module)) {
                    PianoViewModel.shared?.assignKnobCC(idKey: effectiveKey, cc: cc)
                }
            }
        }
        if mappedCC != nil {
            Button(L("Remove MIDI Mapping"), role: .destructive) {
                PianoViewModel.shared?.unassignKnobCC(idKey: effectiveKey)
            }
        }
        Divider()
        Button(L("Enter Value…")) {
            guard enabled else { return }
            textInput = step >= 1.0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
            isEditingText = true
            isTextFieldFocused = true
        }
        Button(L("Reset to Default")) {
            if enabled { value = defaultValue }
        }
    }
}

// MARK: - Compact Stereo L/R Peak Meter (Green -> Yellow -> Red, Unclipped, No Blur)

struct StereoPeakMeter: View {
    let peakL: Float
    let peakR: Float
    var clipped: Bool = false
    var onResetClip: (() -> Void)? = nil
    var segments: Int = 12
    var barWidth: CGFloat = 64

    @State private var dbL: Double = -60.0
    @State private var dbR: Double = -60.0
    @State private var holdDbL: Double = -60.0
    @State private var holdDbR: Double = -60.0
    @State private var holdUntilL: Date = .distantPast
    @State private var holdUntilR: Date = .distantPast
    @State private var lastUpdate: Date = Date()

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                meterRow(label: "L", db: dbL, holdDb: holdDbL)
                meterRow(label: "R", db: dbR, holdDb: holdDbR)
            }
            .fixedSize()

            Button {
                onResetClip?()
            } label: {
                Text(verbatim: "CLIP")
                    .font(.system(size: 8, weight: .bold).monospacedDigit())
                    .foregroundStyle(clipped ? Color.white : StudioTokens.textDisabled)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(clipped ? StudioTokens.meterRed : StudioTokens.surfaceControl)
                    )
            }
            .buttonStyle(.plain)
            .help(clipped ? L("Output clipped — click to clear") : L("Clip indicator"))
        }
        .onChange(of: peakL) { _, _ in updateBallistics() }
        .onChange(of: peakR) { _, _ in updateBallistics() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Stereo output meter"))
        .accessibilityValue(String(localized: "Left \(Int(dbL.rounded())) dB, Right \(Int(dbR.rounded())) dB", bundle: .module))
    }

    private func toDb(_ linear: Float) -> Double {
        let clamped = max(Double(linear), 1e-6)
        return max(-60.0, min(0.0, 20.0 * log10(clamped)))
    }

    private func updateBallistics() {
        let now = Date()
        let dt = min(0.25, max(0.005, now.timeIntervalSince(lastUpdate)))
        lastUpdate = now
        let decayDb = 20.0 * dt // ~20 dB/s release

        let targetL = toDb(peakL)
        if targetL >= dbL {
            dbL = targetL
        } else {
            dbL = max(-60.0, max(targetL, dbL - decayDb))
        }
        if targetL >= holdDbL || now >= holdUntilL {
            holdDbL = max(targetL, holdDbL - decayDb)
            if targetL >= holdDbL {
                holdDbL = targetL
                holdUntilL = now.addingTimeInterval(1.5)
            }
        }

        let targetR = toDb(peakR)
        if targetR >= dbR {
            dbR = targetR
        } else {
            dbR = max(-60.0, max(targetR, dbR - decayDb))
        }
        if targetR >= holdDbR || now >= holdUntilR {
            holdDbR = max(targetR, holdDbR - decayDb)
            if targetR >= holdDbR {
                holdDbR = targetR
                holdUntilR = now.addingTimeInterval(1.5)
            }
        }
    }

    private func meterRow(label: String, db: Double, holdDb: Double) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: label)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(StudioTokens.textSecondary)
                .frame(width: 9, alignment: .leading)

            Canvas { context, size in
                let norm = CGFloat(max(0.0, min(1.0, (db + 60.0) / 60.0)))
                let litCount = Int((norm * CGFloat(segments)).rounded(.up))
                let holdNorm = CGFloat(max(0.0, min(1.0, (holdDb + 60.0) / 60.0)))
                let holdIdx = holdDb > -59.5 ? min(segments - 1, max(0, Int((holdNorm * CGFloat(segments)).rounded(.down)))) : -1

                let spacing: CGFloat = 1.5
                let totalSpacing = spacing * CGFloat(max(0, segments - 1))
                let segW = max(2.0, (size.width - totalSpacing) / CGFloat(segments))

                for idx in 0..<segments {
                    let x = CGFloat(idx) * (segW + spacing)
                    let rect = CGRect(x: x, y: 0, width: segW, height: size.height)
                    let path = Path(roundedRect: rect, cornerRadius: 1.2)

                    let colorForIdx: Color = {
                        if idx >= segments - 2 {
                            return StudioTokens.meterRed
                        } else if idx >= segments - 4 {
                            return StudioTokens.meterYellow
                        } else {
                            return StudioTokens.meterGreen
                        }
                    }()

                    if idx < litCount || idx == holdIdx {
                        context.fill(path, with: .color(colorForIdx))
                    } else {
                        context.fill(path, with: .color(StudioTokens.surfaceControl))
                    }
                }
            }
            .frame(width: barWidth, height: 5)
        }
    }
}

// MARK: - Dual Range Slider (For Velocity Range and Intervals)

struct DualRangeSlider: View {
    let title: String
    @Binding var lowValue: Int
    @Binding var highValue: Int
    let bounds: ClosedRange<Int>
    let valueFormatter: (Int) -> String

    @State private var activeHandle: Handle? = nil

    private enum Handle {
        case low, high
    }

    private var span: Double {
        Double(max(1, bounds.upperBound - bounds.lowerBound))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(StudioTokens.textSecondary)
                    .lineLimit(1)
                Spacer()
                Text(verbatim: "\(valueFormatter(lowValue)) – \(valueFormatter(highValue))")
                    .font(StudioTokens.fontValue)
                    .foregroundStyle(StudioTokens.textPrimary)
                    .lineLimit(1)
            }

            GeometryReader { geo in
                let width = max(1.0, geo.size.width)
                let handleRadius: CGFloat = 6.5
                let usableWidth = max(1.0, width - handleRadius * 2)
                let lowNorm = CGFloat(Double(lowValue - bounds.lowerBound) / span)
                let highNorm = CGFloat(Double(highValue - bounds.lowerBound) / span)
                let lowX = handleRadius + lowNorm * usableWidth
                let highX = handleRadius + highNorm * usableWidth

                ZStack(alignment: .leading) {
                    // Base track
                    Capsule()
                        .fill(StudioTokens.surfaceControl)
                        .frame(height: 6)
                        .overlay(Capsule().stroke(StudioTokens.borderHairline, lineWidth: 1))

                    // Active range
                    Capsule()
                        .fill(StudioTokens.textSecondary.opacity(0.65))
                        .frame(width: max(4, highX - lowX), height: 6)
                        .offset(x: lowX)

                    // Low handle
                    Circle()
                        .fill(StudioTokens.textPrimary)
                        .frame(width: handleRadius * 2, height: handleRadius * 2)
                        .overlay(Circle().stroke(StudioTokens.surfaceWindow, lineWidth: 1.5))
                        .position(x: lowX, y: geo.size.height / 2)

                    // High handle
                    Circle()
                        .fill(StudioTokens.textPrimary)
                        .frame(width: handleRadius * 2, height: handleRadius * 2)
                        .overlay(Circle().stroke(StudioTokens.surfaceWindow, lineWidth: 1.5))
                        .position(x: highX, y: geo.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let x = min(max(g.location.x - handleRadius, 0), usableWidth)
                            let norm = Double(x / usableWidth)
                            let target = bounds.lowerBound + Int((norm * span).rounded())

                            if activeHandle == nil {
                                let distLow = abs(g.location.x - lowX)
                                let distHigh = abs(g.location.x - highX)
                                activeHandle = distLow <= distHigh ? .low : .high
                            }

                            if activeHandle == .low {
                                lowValue = min(max(bounds.lowerBound, target), highValue)
                            } else {
                                highValue = max(min(bounds.upperBound, target), lowValue)
                            }
                        }
                        .onEnded { _ in
                            activeHandle = nil
                        }
                )
            }
            .frame(height: 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(String(localized: "From \(valueFormatter(lowValue)) to \(valueFormatter(highValue))", bundle: .module))
    }
}

// MARK: - Key Zone Range Control Over Mini-Keyboard

struct KeyZoneRangeControl: View {
    @Binding var keyLow: Int
    @Binding var keyHigh: Int
    var layerIndex: Int = 0

    @State private var activeDragMode: DragMode? = nil
    @State private var dragInitialLow: Int = 0
    @State private var dragInitialHigh: Int = 127

    private enum DragMode {
        case low, high, moveZone
    }

    private func isBlackKey(_ midiNote: Int) -> Bool {
        let pc = ((midiNote % 12) + 12) % 12
        return pc == 1 || pc == 3 || pc == 6 || pc == 8 || pc == 10
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Note Range"))
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(StudioTokens.textSecondary)
                Spacer()
                Text(verbatim: "\(shortNoteName(keyLow)) (\(keyLow)) – \(shortNoteName(keyHigh)) (\(keyHigh))")
                    .font(StudioTokens.fontValue)
                    .foregroundStyle(StudioTokens.textPrimary)
            }

            GeometryReader { geo in
                let w = max(1.0, geo.size.width)
                let h = geo.size.height
                let lowX = w * CGFloat(keyLow) / 127.0
                let highX = w * CGFloat(keyHigh) / 127.0
                let zoneColor = StudioTokens.layerZoneColors[min(max(layerIndex, 0), 3)]

                ZStack(alignment: .leading) {
                    Canvas { context, size in
                        let keyW = size.width / 128.0
                        let bgRect = CGRect(origin: .zero, size: size)
                        context.fill(Path(roundedRect: bgRect, cornerRadius: 5), with: .color(StudioTokens.surfaceControl))

                        for note in 0..<128 {
                            let x = CGFloat(note) * keyW
                            if isBlackKey(note) {
                                let blackRect = CGRect(x: x, y: 0, width: max(1.2, keyW * 0.9), height: size.height * 0.58)
                                context.fill(Path(blackRect), with: .color(StudioTokens.surfaceWindow.opacity(0.9)))
                            } else if note % 12 == 0 {
                                var line = Path()
                                line.move(to: CGPoint(x: x, y: 0))
                                line.addLine(to: CGPoint(x: x, y: size.height))
                                context.stroke(line, with: .color(StudioTokens.borderHairline), lineWidth: 0.75)
                            }
                        }

                        let zoneRect = CGRect(
                            x: lowX,
                            y: 0,
                            width: max(3.0, highX - lowX),
                            height: size.height
                        )
                        context.fill(Path(zoneRect), with: .color(zoneColor.opacity(0.28)))
                    }

                    Rectangle()
                        .fill(zoneColor)
                        .frame(width: 3, height: h)
                        .offset(x: min(max(0, lowX - 1.5), w - 3))

                    Rectangle()
                        .fill(zoneColor)
                        .frame(width: 3, height: h)
                        .offset(x: min(max(0, highX - 1.5), w - 3))
                }
                .clipShape(.rect(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(StudioTokens.borderHairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let noteAtCursor = min(max(Int((g.location.x / w * 127.0).rounded()), 0), 127)
                            if activeDragMode == nil {
                                dragInitialLow = keyLow
                                dragInitialHigh = keyHigh
                                let distLow = abs(g.location.x - lowX)
                                let distHigh = abs(g.location.x - highX)
                                if distLow < 12 || (distLow <= distHigh && g.location.x < lowX + 8) {
                                    activeDragMode = .low
                                } else if distHigh < 12 || g.location.x > highX - 8 {
                                    activeDragMode = .high
                                } else if g.location.x > lowX && g.location.x < highX {
                                    activeDragMode = .moveZone
                                } else {
                                    activeDragMode = distLow <= distHigh ? .low : .high
                                }
                            }

                            switch activeDragMode {
                            case .low:
                                keyLow = min(max(0, noteAtCursor), keyHigh)
                            case .high:
                                keyHigh = max(min(127, noteAtCursor), keyLow)
                            case .moveZone:
                                let deltaNotes = Int((g.translation.width / w * 127.0).rounded())
                                let spanNotes = dragInitialHigh - dragInitialLow
                                let newLow = min(max(0, dragInitialLow + deltaNotes), 127 - spanNotes)
                                keyLow = newLow
                                keyHigh = newLow + spanNotes
                            case .none:
                                break
                            }
                        }
                        .onEnded { _ in
                            activeDragMode = nil
                        }
                )
            }
            .frame(height: 34)

            HStack {
                Text(verbatim: "C-1")
                Spacer()
                Text(verbatim: "C2")
                Spacer()
                Text(verbatim: "C4")
                Spacer()
                Text(verbatim: "C6")
                Spacer()
                Text(verbatim: "G9")
            }
            .font(.system(size: 11, weight: .regular).monospacedDigit())
            .foregroundStyle(StudioTokens.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Layer keyboard zone"))
        .accessibilityValue(String(localized: "From \(shortNoteName(keyLow)) to \(shortNoteName(keyHigh))", bundle: .module))
    }
}

// MARK: - 3-Band Equalizer Response Graph

struct EQResponseGraph: View {
    let bassDb: Double
    let midDb: Double
    let midFreqHz: Double
    let trebleDb: Double

    private func gainAtFrequency(_ f: Double) -> Double {
        let logF = log10(max(20.0, f))
        let lowNorm = 1.0 / (1.0 + exp((logF - log10(130.0)) * 6.5))
        let lowContrib = bassDb * lowNorm

        let logMid = log10(min(max(200.0, midFreqHz), 5000.0))
        let bellDist = (logF - logMid) / 0.32
        let midContrib = midDb * exp(-(bellDist * bellDist))

        let highNorm = 1.0 / (1.0 + exp(-(logF - log10(3600.0)) * 6.5))
        let highContrib = trebleDb * highNorm

        return min(max(lowContrib + midContrib + highContrib, -18.0), 18.0)
    }

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let midY = h / 2.0

            let bgRect = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: bgRect, cornerRadius: 6), with: .color(StudioTokens.surfaceControl))

            var gridPath = Path()
            for fracY in [0.2, 0.5, 0.8] {
                let y = h * CGFloat(fracY)
                gridPath.move(to: CGPoint(x: 0, y: y))
                gridPath.addLine(to: CGPoint(x: w, y: y))
            }
            for freq in [100.0, 1000.0, 10000.0] {
                let normX = (log10(freq) - log10(20.0)) / (log10(20000.0) - log10(20.0))
                let x = w * CGFloat(normX)
                gridPath.move(to: CGPoint(x: x, y: 0))
                gridPath.addLine(to: CGPoint(x: x, y: h))
            }
            context.stroke(gridPath, with: .color(StudioTokens.borderHairline), lineWidth: 1.0)

            let steps = 80
            var linePath = Path()
            var fillPath = Path()
            let logMin = log10(20.0)
            let logMax = log10(20000.0)

            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let freq = pow(10.0, logMin + t * (logMax - logMin))
                let db = gainAtFrequency(freq)
                let x = CGFloat(t) * w
                let y = midY - CGFloat(db / 18.0) * (h * 0.42)
                let pt = CGPoint(x: x, y: y)

                if i == 0 {
                    linePath.move(to: pt)
                    fillPath.move(to: CGPoint(x: 0, y: midY))
                    fillPath.addLine(to: pt)
                } else {
                    linePath.addLine(to: pt)
                    fillPath.addLine(to: pt)
                }
            }
            fillPath.addLine(to: CGPoint(x: w, y: midY))
            fillPath.closeSubpath()

            context.fill(fillPath, with: .color(StudioTokens.textPrimary.opacity(0.10)))
            context.stroke(
                linePath,
                with: .color(StudioTokens.textPrimary),
                style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
            )
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(StudioTokens.borderHairline, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Equalizer response curve"))
        .accessibilityValue(
            String(
                localized: "Bass \(String(format: "%+.1f", bassDb)) dB, Mid \(String(format: "%+.1f", midDb)) dB at \(String(format: "%.0f", midFreqHz)) Hz, Treble \(String(format: "%+.1f", trebleDb)) dB",
                bundle: .module
            )
        )
    }
}
