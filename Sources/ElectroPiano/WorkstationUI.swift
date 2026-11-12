import AppKit
import NPNOBridge
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Note Utilities & Parameter Friendly Names

let kLayerLetters = ["A", "B", "C", "D"]

func shortNoteName(_ note: Int) -> String {
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let n = min(max(note, 0), 127)
    return "\(names[n % 12])\((n / 12) - 1)"
}

/// Same velocity curves as the C++ engine (Engine.cpp): global sensitivity first, then layer curve.
func velocityCurveOutput(_ v: Double, layerCurve: Int, globalCurve: Int) -> Double {
    var x = min(max(v, 0.0), 1.0)
    if globalCurve < 0 { x = pow(x, 0.72) } else if globalCurve > 0 { x = pow(x, 1.38) }
    switch layerCurve {
    case 1: return pow(x, 0.68)
    case 3: return pow(x, 1.45)
    case 4: return x * x
    case 5: return x.squareRoot()
    default: return x
    }
}

func friendlyKnobName(_ key: String) -> String {
    let fixed: [String: String] = [
        "global_vol": L("Master Volume"),
        "global_pan": L("Master Pan"),
        "global_tune": L("Fine Tune"),
        "global_a4": L("A4 Reference"),
        "global_relnoise": L("Release Noise"),
        "eq_bass": L("EQ Bass"),
        "eq_mid": L("EQ Mid"),
        "eq_midf": L("EQ Mid Freq"),
        "eq_treb": L("EQ Treble"),
        "eq_drive": L("Drive Amount"),
        "dly_amt": L("Delay Mix"),
        "dly_fb": L("Delay Feedback"),
        "dly_time": L("Delay Time"),
        "dly_div": L("Delay Division"),
        "dly_bpm": L("Delay BPM"),
        "rev_amt": L("Reverb Mix"),
        "rev_size": L("Reverb Size"),
        "rev_dec": L("Reverb Decay"),
        "rev_damp": L("Reverb Damping"),
        "rev_predly": L("Reverb Pre-Delay"),
        "mod1_rate": L("Mod 1 Rate"),
        "mod1_depth": L("Mod 1 Depth"),
        "mod2_rate": L("Mod 2 Rate"),
        "mod2_depth": L("Mod 2 Depth")
    ]
    if let f = fixed[key] { return f }
    if key.hasPrefix("L"),
       key.count > 3,
       let idx = Int(String(key[key.index(key.startIndex, offsetBy: 1)])),
       (0..<4).contains(idx) {
        let suffix = String(key.dropFirst(3))
        let names: [String: String] = [
            "vol": L("Volume"),
            "flt": L("Filter"),
            "fxam": L("String Resonance"),
            "fxrt": L("Release Tail"),
            "comp": L("Compressor"),
            "att": L("Attack"),
            "rel": L("Release"),
            "klo": L("Low Key"),
            "khi": L("High Key"),
            "vlo": L("Minimum Velocity"),
            "vhi": L("Maximum Velocity"),
            "plo": L("Pitch Bend ↓"),
            "phi": L("Pitch Bend ↑"),
            "port": L("Portamento Time")
        ]
        let paramTitle = names[suffix] ?? suffix
        return String(localized: "Layer \(kLayerLetters[idx]) · \(paramTitle)", bundle: .module)
    }
    return key
}

// MARK: - UI Zoom Scale (View Menu: Cmd+, Cmd-, Cmd 0)

enum PanelLayout {
    static let scales: [Double] = [0.85, 0.92, 1.00, 1.08, 1.15, 1.25]
}

extension PianoViewModel {
    static func initialUIScale() -> Double {
        let saved = UserDefaults.standard.double(forKey: "ElectroPiano_UIScale")
        if saved >= 0.8 && saved <= 1.5 { return saved }
        return 1.0
    }

    func zoomIn() {
        if let next = PanelLayout.scales.first(where: { $0 > uiScale + 0.001 }) {
            uiScale = next
        }
    }

    func zoomOut() {
        if let prev = PanelLayout.scales.last(where: { $0 < uiScale - 0.001 }) {
            uiScale = prev
        }
    }

    func zoomToFitScreen() {
        uiScale = 1.0
    }
}

// MARK: - Velocity Curve & 3x2 Thumbnail Grid

struct VelocityCurveShape: Shape {
    let layerCurve: Int
    let globalCurve: Int

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let steps = 36
        for i in 0...steps {
            let x = Double(i) / Double(steps)
            let y = velocityCurveOutput(x, layerCurve: layerCurve, globalCurve: globalCurve)
            let pt = CGPoint(
                x: rect.minX + CGFloat(x) * rect.width,
                y: rect.maxY - CGFloat(y) * rect.height
            )
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

struct VelocityCurveThumbnailGrid: View {
    @Binding var selectedCurve: Int
    let globalCurve: Int

    private struct CurveItem: Identifiable {
        let id: Int
        let title: String
    }

    // 3x2 order: Soft, Log, Normal / Linear, Hard, Exp
    private var rows: [[CurveItem]] {
        [
            [
                CurveItem(id: 1, title: L("Soft")),
                CurveItem(id: 5, title: L("Log")),
                CurveItem(id: 0, title: L("Normal"))
            ],
            [
                CurveItem(id: 2, title: L("Linear")),
                CurveItem(id: 3, title: L("Hard")),
                CurveItem(id: 4, title: L("Exp"))
            ]
        ]
    }

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(0..<rows.count, id: \.self) { rowIdx in
                GridRow {
                    ForEach(rows[rowIdx]) { item in
                        curveCell(item)
                    }
                }
            }
        }
    }

    private func curveCell(_ item: CurveItem) -> some View {
        let isSelected = selectedCurve == item.id
        return Button {
            selectedCurve = item.id
        } label: {
            VStack(spacing: 4) {
                Canvas { context, size in
                    let w = size.width
                    let h = size.height

                    // Subtle 2x2 grid + reference diagonal line
                    var grid = Path()
                    grid.move(to: CGPoint(x: w * 0.5, y: 0))
                    grid.addLine(to: CGPoint(x: w * 0.5, y: h))
                    grid.move(to: CGPoint(x: 0, y: h * 0.5))
                    grid.addLine(to: CGPoint(x: w, y: h * 0.5))
                    context.stroke(grid, with: .color(StudioTokens.borderHairline.opacity(0.8)), lineWidth: 0.75)

                    var diag = Path()
                    diag.move(to: CGPoint(x: 2, y: h - 2))
                    diag.addLine(to: CGPoint(x: w - 2, y: 2))
                    context.stroke(
                        diag,
                        with: .color(StudioTokens.textSecondary.opacity(0.22)),
                        style: StrokeStyle(lineWidth: 0.75, dash: [2, 2])
                    )

                    let inset = CGRect(x: 3, y: 3, width: max(1, w - 6), height: max(1, h - 6))
                    let curvePath = VelocityCurveShape(layerCurve: item.id, globalCurve: globalCurve).path(in: inset)
                    context.stroke(
                        curvePath,
                        with: .color(isSelected ? StudioTokens.textPrimary : StudioTokens.textSecondary),
                        style: StrokeStyle(lineWidth: isSelected ? 2.0 : 1.5, lineCap: .round, lineJoin: .round)
                    )
                }
                .frame(height: 28)

                Text(item.title)
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(isSelected ? StudioTokens.textPrimary : StudioTokens.textSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                isSelected ? StudioTokens.borderHairline.opacity(0.85) : StudioTokens.surfaceControl,
                in: .rect(cornerRadius: StudioTokens.controlRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTokens.controlRadius)
                    .stroke(
                        isSelected ? StudioTokens.textPrimary.opacity(0.75) : StudioTokens.borderHairline,
                        lineWidth: isSelected ? 1.25 : 1.0
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Velocity curve \(item.title)", bundle: .module))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Sound Browser Popover (.npno / .nsmp4) — Search, Categories, Favorites, Recent

struct TimbrePickerMenu: View {
    @ObservedObject var vm: PianoViewModel
    let layer: Int
    @State private var isBrowserPresented: Bool = false

    private var slot: LayerSlotState { vm.layers[layer] }

    var body: some View {
        Button {
            isBrowserPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: slot.loaded ? "pianokeys" : "folder.badge.plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioTokens.textSecondary)

                if slot.loaded {
                    Text(slot.name)
                        .font(StudioTokens.fontBodyMedium)
                        .foregroundStyle(StudioTokens.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(L("No Sound"))
                        .font(StudioTokens.fontBodyMedium)
                        .foregroundStyle(StudioTokens.textSecondary)
                        .lineLimit(1)
                    Text(verbatim: "·")
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                    Text(L("Load Sound…"))
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textPrimary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StudioTokens.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                StudioTokens.surfaceControl.opacity(0.82),
                in: .rect(cornerRadius: StudioTokens.controlRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: StudioTokens.controlRadius)
                    .stroke(StudioTokens.borderHairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isBrowserPresented, arrowEdge: .bottom) {
            SoundBrowserPopoverView(vm: vm, layer: layer, isPresented: $isBrowserPresented)
        }
        .help(slot.loaded ? "\(slot.name) — \(slot.model)" : String(localized: "Choose a .npno or .nsmp4 file for Layer \(kLayerLetters[layer])", bundle: .module))
    }
}

struct SoundBrowserPopoverView: View {
    @ObservedObject var vm: PianoViewModel
    let layer: Int
    @Binding var isPresented: Bool

    private var filters: [SoundBrowserFilter] {
        var list: [SoundBrowserFilter] = [.all, .favorites, .recent]
        for cat in SoundCategory.allCases {
            list.append(.category(cat))
        }
        return list
    }

    var body: some View {
        let items = vm.filteredBrowserBanks()
        let slot = vm.layers[layer]

        VStack(alignment: .leading, spacing: 10) {
            // Header + Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTokens.textSecondary)

                TextField(L("Search sounds…"), text: $vm.soundBrowserSearchText)
                    .textFieldStyle(.plain)
                    .font(StudioTokens.fontBody)
                    .foregroundStyle(StudioTokens.textPrimary)

                if !vm.soundBrowserSearchText.isEmpty {
                    Button {
                        vm.soundBrowserSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(StudioTokens.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(StudioTokens.surfaceControl, in: .rect(cornerRadius: StudioTokens.controlRadius))
            .overlay(
                RoundedRectangle(cornerRadius: StudioTokens.controlRadius)
                    .stroke(StudioTokens.borderHairline, lineWidth: 1)
            )

            // Filter Pills: All, Favorites, Recent, Grand, Upright, Electric, Clav/Harpsi, Synth/Sample
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(filters) { filter in
                        let isSelected = vm.soundBrowserFilter == filter
                        Button {
                            vm.soundBrowserFilter = filter
                        } label: {
                            HStack(spacing: 4) {
                                if filter == .favorites {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 9))
                                } else if filter == .recent {
                                    Image(systemName: "clock")
                                        .font(.system(size: 9))
                                }
                                Text(filter.title)
                                    .font(StudioTokens.fontLabel)
                            }
                            .foregroundStyle(isSelected ? StudioTokens.textPrimary : StudioTokens.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                isSelected ? StudioTokens.surfaceControl : StudioTokens.surfacePanel,
                                in: .capsule
                            )
                            .overlay(
                                Capsule()
                                    .stroke(isSelected ? StudioTokens.textSecondary.opacity(0.6) : StudioTokens.borderHairline, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider().overlay(StudioTokens.borderHairline)

            // Sound list
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "pianokeys")
                        .font(.system(size: 20))
                        .foregroundStyle(StudioTokens.textSecondary)
                    Text(vm.embeddedBanks.isEmpty ? L("No sounds in library") : L("No matching sounds"))
                        .font(StudioTokens.fontBodyMedium)
                        .foregroundStyle(StudioTokens.textPrimary)
                    if vm.embeddedBanks.isEmpty {
                        Button(L("Choose Folder…")) {
                            isPresented = false
                            vm.chooseLibraryFolder()
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(items) { bank in
                            let isCurrent = slot.loaded && slot.path == bank.path
                            let isFav = vm.isFavoriteSound(path: bank.path)

                            HStack(spacing: 8) {
                                Button {
                                    vm.toggleFavoriteSound(path: bank.path)
                                } label: {
                                    Image(systemName: isFav ? "star.fill" : "star")
                                        .font(.system(size: 11))
                                        .foregroundStyle(isFav ? StudioTokens.meterYellow : StudioTokens.textSecondary)
                                        .frame(width: 18, height: 18)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(isFav ? L("Remove from Favorites") : L("Add to Favorites"))

                                Button {
                                    isPresented = false
                                    vm.loadLayerInstrument(layer: layer, from: bank.path)
                                } label: {
                                    HStack(spacing: 8) {
                                        if isCurrent {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(StudioTokens.textPrimary)
                                                .frame(width: 12)
                                        } else {
                                            Color.clear.frame(width: 12, height: 12)
                                        }

                                        Text(verbatim: bank.name)
                                            .font(StudioTokens.fontBodyMedium)
                                            .foregroundStyle(StudioTokens.textPrimary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)

                                        Spacer(minLength: 6)

                                        Text(verbatim: bank.formatExtension)
                                            .font(.system(size: 10, weight: .semibold).monospaced())
                                            .foregroundStyle(StudioTokens.textSecondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 2)
                                            .background(StudioTokens.surfaceWindow, in: .rect(cornerRadius: 4))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(StudioTokens.borderHairline, lineWidth: 1)
                                            )

                                        Text(verbatim: bank.sizeLabel)
                                            .font(.system(size: 11, weight: .regular).monospacedDigit())
                                            .foregroundStyle(StudioTokens.textSecondary)
                                            .frame(width: 56, alignment: .trailing)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                isCurrent ? StudioTokens.surfaceControl : Color.clear,
                                in: .rect(cornerRadius: StudioTokens.controlRadius)
                            )
                        }
                    }
                }
                .frame(height: 250)
            }

            Divider().overlay(StudioTokens.borderHairline)

            // Footer: Load loose file (Cmd+O) + Choose Folder
            HStack(spacing: 8) {
                Text(String(localized: "\(items.count) sounds", bundle: .module))
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(StudioTokens.textSecondary)

                Spacer()

                Button {
                    isPresented = false
                    vm.chooseLibraryFolder()
                } label: {
                    Label(L("Choose Folder…"), systemImage: "folder.badge.gearshape")
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button {
                    isPresented = false
                    vm.openFilePicker(forLayer: layer)
                } label: {
                    Label(L("Load Sound…"), systemImage: "doc.badge.plus")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 440)
        .background(StudioTokens.surfacePanel)
    }
}

// MARK: - First Run & Empty State Views

struct FirstRunWelcomeView: View {
    @ObservedObject var vm: PianoViewModel
    @State private var loadFirstGrandIntoLayerA: Bool = true
    @State private var isDropTargeted: Bool = false

    private var activeAudioDeviceName: String {
        if let dev = vm.audioOutputDevices.first(where: { $0.id == vm.selectedAudioDeviceID }) {
            return dev.name.replacingOccurrences(of: " (Default)", with: "")
        }
        return L("Built-in Output")
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)

            VStack(spacing: 18) {
                Image(systemName: "pianokeys.inverse")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(StudioTokens.textPrimary)

                VStack(spacing: 6) {
                    Text(L("Welcome to Electro Pro"))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(StudioTokens.textPrimary)

                    Text(L("Choose the folder that contains your Nord sound libraries (.npno, .nsmp4)."))
                        .font(StudioTokens.fontBody)
                        .foregroundStyle(StudioTokens.textSecondary)
                        .multilineTextAlignment(.center)
                }

                // Drag-and-drop & scan status area
                VStack(spacing: 12) {
                    if vm.isScanningLibrary {
                        HStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.small)
                            Text(String(localized: "Scanning… \(vm.scannedFileCount) files", bundle: .module))
                                .font(StudioTokens.fontValue)
                                .foregroundStyle(StudioTokens.textPrimary)
                            Spacer()
                            Button(L("Cancel")) {
                                vm.cancelLibraryScan()
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                        .padding(14)
                        .background(StudioTokens.surfaceControl, in: .rect(cornerRadius: StudioTokens.controlRadius))
                    } else if vm.hasCompletedScanInFirstRun && !vm.libraryFolderPath.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: vm.embeddedBanks.isEmpty ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(vm.embeddedBanks.isEmpty ? StudioTokens.meterYellow : StudioTokens.meterGreen)
                                Text(String(localized: "Found \(vm.embeddedBanks.count) sounds in \(vm.detectedCategoryCount) categories.", bundle: .module))
                                    .font(StudioTokens.fontBodyMedium)
                                    .foregroundStyle(StudioTokens.textPrimary)
                                Spacer()
                                Button(L("Choose Folder…")) {
                                    vm.chooseLibraryFolder()
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                            }

                            if let grand = vm.firstGrandSound {
                                Toggle(
                                    String(localized: "Load \(grand.name) into Layer A", bundle: .module),
                                    isOn: $loadFirstGrandIntoLayerA
                                )
                                .toggleStyle(.checkbox)
                                .font(StudioTokens.fontBody)
                                .foregroundStyle(StudioTokens.textPrimary)
                            }
                        }
                        .padding(14)
                        .background(StudioTokens.surfaceControl, in: .rect(cornerRadius: StudioTokens.controlRadius))
                    } else {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 16))
                                .foregroundStyle(StudioTokens.textSecondary)
                            Text(L("Drag and drop your Nord sound library folder here, or click Choose Folder…"))
                                .font(StudioTokens.fontLabel)
                                .foregroundStyle(StudioTokens.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .padding(.horizontal, 14)
                        .background(
                            StudioTokens.surfaceControl.opacity(isDropTargeted ? 1.0 : 0.65),
                            in: .rect(cornerRadius: StudioTokens.controlRadius)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: StudioTokens.controlRadius)
                                .strokeBorder(
                                    isDropTargeted ? StudioTokens.textPrimary : StudioTokens.borderHairline,
                                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                                )
                        )
                    }
                }

                Divider().overlay(StudioTokens.borderHairline)

                // 3-line status checklist: Library, Audio, MIDI
                VStack(alignment: .leading, spacing: 10) {
                    // 1. Library
                    HStack(spacing: 10) {
                        Image(systemName: vm.embeddedBanks.isEmpty ? "folder" : "checkmark.circle.fill")
                            .foregroundStyle(vm.embeddedBanks.isEmpty ? StudioTokens.textSecondary : StudioTokens.meterGreen)
                            .frame(width: 16)
                        Text(L("Library"))
                            .font(StudioTokens.fontBodyMedium)
                            .foregroundStyle(StudioTokens.textPrimary)
                            .frame(width: 68, alignment: .leading)
                        Text(
                            vm.libraryFolderPath.isEmpty
                                ? String(localized: "Default folder · \(vm.embeddedBanks.count) sounds", bundle: .module)
                                : String(localized: "\((vm.libraryFolderPath as NSString).lastPathComponent) · \(vm.embeddedBanks.count) sounds", bundle: .module)
                        )
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        Spacer()
                    }

                    // 2. Audio
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(StudioTokens.meterGreen)
                            .frame(width: 16)
                        Text(L("Audio"))
                            .font(StudioTokens.fontBodyMedium)
                            .foregroundStyle(StudioTokens.textPrimary)
                            .frame(width: 68, alignment: .leading)
                        Text(verbatim: "\(activeAudioDeviceName) · \(Int((vm.sampleRate / 1000.0).rounded())) kHz")
                            .font(StudioTokens.fontLabel)
                            .foregroundStyle(StudioTokens.textSecondary)
                            .lineLimit(1)
                        Spacer()
                    }

                    // 3. MIDI
                    HStack(spacing: 10) {
                        Image(systemName: vm.midiSourceCount > 0 ? "checkmark.circle.fill" : "pianokeys")
                            .foregroundStyle(vm.midiSourceCount > 0 ? StudioTokens.meterGreen : StudioTokens.textSecondary)
                            .frame(width: 16)
                        Text(L("MIDI"))
                            .font(StudioTokens.fontBodyMedium)
                            .foregroundStyle(StudioTokens.textPrimary)
                            .frame(width: 68, alignment: .leading)
                        Text(
                            vm.midiSourceCount > 0
                                ? vm.midiSources
                                : L("No MIDI controller connected — you can play with the Mac keyboard or on-screen keys")
                        )
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        Spacer()
                        Button(L("Rescan")) {
                            vm.refreshAudioAndMidiDevices()
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)

                Divider().overlay(StudioTokens.borderHairline)

                // Action buttons
                HStack(spacing: 12) {
                    Button(L("Skip for Now")) {
                        vm.skipFirstRun()
                    }
                    .buttonStyle(.glass)

                    Spacer()

                    if vm.hasCompletedScanInFirstRun && !vm.libraryFolderPath.isEmpty {
                        Button(L("Start Playing")) {
                            vm.finishFirstRun(loadFirstGrand: loadFirstGrandIntoLayerA)
                        }
                        .buttonStyle(.glassProminent)
                    } else {
                        Button(L("Choose Folder…")) {
                            vm.chooseLibraryFolder()
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(vm.isScanningLibrary)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 640)
            .background(StudioTokens.surfacePanel, in: .rect(cornerRadius: StudioTokens.panelRadius))
            .overlay(
                RoundedRectangle(cornerRadius: StudioTokens.panelRadius)
                    .stroke(StudioTokens.borderHairline, lineWidth: 1)
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                guard let first = providers.first else { return false }
                _ = first.loadObject(ofClass: URL.self) { url, _ in
                    if let folderURL = url {
                        Task { @MainActor in
                            vm.setLibraryFolder(url: folderURL)
                        }
                    }
                }
                return true
            }

            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LibraryEmptyStateBanner: View {
    @ObservedObject var vm: PianoViewModel

    var body: some View {
        if vm.libraryFolderMissing {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(StudioTokens.meterRed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Library folder not found"))
                        .font(StudioTokens.fontBodyMedium)
                        .foregroundStyle(StudioTokens.textPrimary)
                    Text(verbatim: vm.libraryFolderPath)
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(L("Locate…")) {
                    vm.chooseLibraryFolder()
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button(L("Choose Folder…")) {
                    vm.chooseLibraryFolder()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(StudioTokens.surfacePanel, in: .rect(cornerRadius: StudioTokens.panelRadius))
            .overlay(
                RoundedRectangle(cornerRadius: StudioTokens.panelRadius)
                    .stroke(StudioTokens.meterRed.opacity(0.65), lineWidth: 1)
            )
        } else if vm.embeddedBanks.isEmpty && !vm.isScanningLibrary && !vm.layers.contains(where: { $0.loaded }) {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.questionmark")
                    .foregroundStyle(StudioTokens.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("No Nord sound libraries found in the selected folder"))
                        .font(StudioTokens.fontBodyMedium)
                        .foregroundStyle(StudioTokens.textPrimary)
                    Text(L("Download official .npno or .nsmp4 sound banks from the Nord Piano & Sample Library and choose their folder."))
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(L("Choose Folder…")) {
                    vm.chooseLibraryFolder()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(StudioTokens.surfacePanel, in: .rect(cornerRadius: StudioTokens.panelRadius))
            .overlay(
                RoundedRectangle(cornerRadius: StudioTokens.panelRadius)
                    .stroke(StudioTokens.borderHairline, lineWidth: 1)
            )
        }
    }
}

// MARK: - Main Window (ContentView)

struct ContentView: View {
    @ObservedObject var vm: PianoViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var layerGlassNamespace

    private var currentPresetTitle: String {
        let idx = min(max(vm.selectedMemorySlot - 1, 0), vm.memorySlots.count - 1)
        let preset = vm.memorySlots[idx]
        if preset.hasData && !preset.name.isEmpty {
            return preset.name
        }
        let activeNames = vm.layers
            .filter { $0.loaded && $0.params.enabled }
            .map { $0.name }
        return activeNames.isEmpty ? L("Init") : activeNames.joined(separator: " + ")
    }

    var body: some View {
        GeometryReader { geo in
            let scale = CGFloat(vm.uiScale)
            let isScaled = abs(scale - 1.0) > 0.001
            let contentW = isScaled ? (geo.size.width / scale) : geo.size.width
            let contentH = isScaled ? (geo.size.height / scale) : geo.size.height

            VStack(spacing: StudioTokens.grid2) {
                if vm.showFirstRunScreen {
                    FirstRunWelcomeView(vm: vm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    if vm.libraryFolderMissing || (vm.embeddedBanks.isEmpty && !vm.isScanningLibrary && !vm.layers.contains(where: { $0.loaded })) {
                        LibraryEmptyStateBanner(vm: vm)
                    }

                    // 1. Compact 4-layer strip (~100pt) inside a single GlassEffectContainer
                    layerStripSection

                    // 2. Selected layer/master editor (content-sized panels aligned to top; vertical scroll only)
                    layerEditorSection(availableWidth: max(800, contentW - StudioTokens.grid2 * 2))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }

                // 3. 61-key virtual keyboard at the bottom (~120pt), open by default (Cmd+K)
                if vm.showVirtualKeyboard {
                    VirtualKeyboard61View(vm: vm, telemetry: vm.telemetry)
                        .frame(height: 118)
                }
            }
            .padding(.horizontal, StudioTokens.grid2)
            .padding(.top, StudioTokens.grid2)
            .padding(.bottom, StudioTokens.grid1)
            .frame(width: contentW, height: contentH, alignment: .top)
            .scaleEffect(isScaled ? scale : 1.0, anchor: .topLeading)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(minWidth: 1100, minHeight: 720)
        .background(StudioTokens.surfaceWindow)
        .preferredColorScheme(.dark)
        .navigationTitle(L("Electro Pro"))
        .navigationSubtitle(
            vm.isProgramEdited
                ? String(localized: "Program \(vm.selectedMemorySlot) — \(currentPresetTitle) — Edited", bundle: .module)
                : String(localized: "Program \(vm.selectedMemorySlot) — \(currentPresetTitle)", bundle: .module)
        )
        .toolbar {
            workstationToolbar
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            statusBarSection
        }
        .onAppear {
            DispatchQueue.main.async {
                if let win = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
                    _ = win.setFrameAutosaveName("ElectroProMainWindow")
                }
            }
        }
    }

    // MARK: - 1. Native Toolbar (5 Groups Separated by ToolbarSpacer = 5 Glass Capsules)

    @ToolbarContentBuilder
    private var workstationToolbar: some ToolbarContent {
        // Group 1: Programs 1–8 (Segmented Picker, .fixedSize()) + Save (.glass, neutral)
        ToolbarItemGroup(placement: .automatic) {
            Picker(L("Program"), selection: Binding(
                get: { vm.selectedMemorySlot },
                set: { slot in vm.recallMemory(slot: slot) }
            )) {
                ForEach(1...8, id: \.self) { slot in
                    if vm.isProgramEdited && slot == vm.selectedMemorySlot {
                        Text(verbatim: "\(slot) •").tag(slot)
                    } else {
                        Text(verbatim: "\(slot)").tag(slot)
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(L("Select Program (1 to 8)"))

            Button {
                vm.storeCurrentToMemory(slot: vm.selectedMemorySlot)
            } label: {
                Label(
                    vm.storeConfirmationActive ? L("Saved") : L("Save"),
                    systemImage: vm.storeConfirmationActive ? "checkmark" : "square.and.arrow.down"
                )
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glass)
            .popover(isPresented: $vm.showRenameProgramPopover, arrowEdge: .bottom) {
                renameProgramPopover
            }
            .help(String(localized: "Save current state to Program \(vm.selectedMemorySlot) (⌘S). To rename: File > Rename Program… (⇧⌘R)", bundle: .module))
        }

        ToolbarSpacer(.fixed)

        // Group 2: Transpose [−] value [+] with sign (e.g. +2 st) + Tuning button (A4/Fine popover)
        ToolbarItemGroup(placement: .automatic) {
            HStack(spacing: 4) {
                Button {
                    let cur = Int(vm.transposeSemitones.rounded())
                    vm.transposeSemitones = Double(max(-12, cur - 1))
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Decrease Transpose by 1 semitone"))

                let st = Int(vm.transposeSemitones.rounded())
                Text(verbatim: st == 0 ? "0 st" : String(format: "%+d st", st))
                    .font(StudioTokens.fontValue)
                    .foregroundStyle(StudioTokens.textPrimary)
                    .fixedSize()
                    .frame(minWidth: 40, alignment: .center)
                    .onTapGesture(count: 2) {
                        vm.transposeSemitones = 0.0
                    }
                    .help(L("Global Transpose in semitones (double-click for 0 st)"))

                Button {
                    let cur = Int(vm.transposeSemitones.rounded())
                    vm.transposeSemitones = Double(min(12, cur + 1))
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Increase Transpose by 1 semitone"))
            }

            Button {
                vm.showTuningPopover.toggle()
            } label: {
                Image(systemName: "tuningfork")
            }
            .buttonStyle(.glass)
            .popover(isPresented: $vm.showTuningPopover, arrowEdge: .bottom) {
                masterTuningPopover
            }
            .help(L("Tuning (A4 Reference, Fine Tune, and Master Balance)"))
        }

        ToolbarSpacer(.fixed)

        // Group 3: Master Volume: slider ~140pt + dB readout + unclipped L/R meter
        ToolbarItemGroup(placement: .automatic) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioTokens.textSecondary)

                Slider(
                    value: $vm.masterGainDb,
                    in: -36.0...12.0,
                    neutralValue: 0.0
                ) {
                    Text(L("Master Volume"))
                }
                .labelsHidden()
                .frame(width: 136)
                .help(String(localized: "Master Volume: \(String(format: "%+.1f dB", vm.masterGainDb)) (double-click value for 0 dB)", bundle: .module))

                Text(verbatim: String(format: "%+.1f dB", vm.masterGainDb))
                    .font(StudioTokens.fontValue)
                    .foregroundStyle(StudioTokens.textPrimary)
                    .fixedSize()
                    .frame(width: 54, alignment: .trailing)
                    .onTapGesture(count: 2) {
                        vm.masterGainDb = 0.0
                    }

                ToolbarPeakMeterView(telemetry: vm.telemetry)
            }
        }

        ToolbarSpacer(.flexible)

        // Group 4 (separated): Panic
        ToolbarItem(placement: .automatic) {
            Button(role: .destructive) {
                vm.panic()
            } label: {
                Label(L("Panic"), systemImage: "xmark.octagon")
            }
            .buttonStyle(.glass)
            .help(L("Immediately silence all active voices (⌘.)"))
        }

        ToolbarSpacer(.fixed)

        // Group 5 (separated, rightmost): Settings
        ToolbarItem(placement: .automatic) {
            SettingsLink {
                Label(L("Settings"), systemImage: "gearshape")
            }
            .buttonStyle(.glass)
            .help(L("Open Audio, MIDI, Keyboard, Library, and Appearance Settings (⌘,)"))
        }
    }

    // MARK: - "Rename Program…" Popover (File > Rename Program…)

    private var renameProgramPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Rename Program \(vm.selectedMemorySlot)", bundle: .module))
                .font(StudioTokens.fontSectionTitle)
                .foregroundStyle(StudioTokens.textPrimary)

            TextField(L("Program Name"), text: $vm.renameProgramDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    vm.commitRenameCurrentProgram()
                }

            HStack {
                Spacer()
                Button(L("Cancel")) {
                    vm.showRenameProgramPopover = false
                }
                .buttonStyle(.glass)

                Button(L("Save")) {
                    vm.commitRenameCurrentProgram()
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(StudioTokens.grid2)
        .frame(width: 260)
    }

    // MARK: - "Tuning" Popover (A4 / Fine / Master Pan)

    private var masterTuningPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("Tuning & Master"))
                    .font(StudioTokens.fontSectionTitle)
                Spacer()
                Button(L("Reset to Default")) {
                    vm.masterGainDb = 0.0
                    vm.masterPan = 0.0
                    vm.baseTuningHz = 440.0
                    vm.fineTuneCents = 0.0
                    vm.transposeSemitones = 0.0
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            Divider()

            // A4 Reference (neutralValue at 440.0 Hz)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L("A4 Reference"))
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                    Spacer()
                    Text(verbatim: String(format: "%.1f Hz", vm.baseTuningHz))
                        .font(StudioTokens.fontValue)
                }
                Slider(value: $vm.baseTuningHz, in: 432.0...446.0, step: 0.5, neutralValue: 440.0) {
                    Text(L("A4 Reference"))
                }
                .labelsHidden()
            }

            // Fine Tune (cents, neutralValue at 0.0 ct)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L("Fine Tune"))
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                    Spacer()
                    Text(verbatim: String(format: "%+.0f ct", vm.fineTuneCents))
                        .font(StudioTokens.fontValue)
                }
                Slider(value: $vm.fineTuneCents, in: -100.0...100.0, step: 5.0, neutralValue: 0.0) {
                    Text(L("Fine Tune"))
                }
                .labelsHidden()
            }

            // Master Balance / Pan (centered at 0 with neutralValue)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L("Balance (Pan)"))
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                    Spacer()
                    let panInt = Int(vm.masterPan.rounded())
                    Text(panInt == 0 ? L("Center") : (panInt < 0 ? "\(-panInt)% L" : "\(panInt)% R"))
                        .font(StudioTokens.fontValue)
                }
                Slider(value: $vm.masterPan, in: -100.0...100.0, step: 5.0, neutralValue: 0.0) {
                    Text(L("Balance (Pan)"))
                }
                .labelsHidden()
            }
        }
        .padding(StudioTokens.grid2)
        .frame(width: 280)
    }

    // MARK: - 2. Layer Strip (~100pt) inside a single GlassEffectContainer

    private var layerStripSection: some View {
        let isLayerMode = vm.selectedTab.isPerLayer
        return GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { layer in
                    layerCardView(layer)
                }
            }
        }
        .frame(height: 100)
        .opacity(isLayerMode ? 1.0 : 0.78)
    }

    private func layerCardView(_ layer: Int) -> some View {
        let letter = kLayerLetters[layer]
        let slot = vm.layers[layer]
        let p = slot.params
        let isLayerMode = vm.selectedTab.isPerLayer
        let isSelected = (vm.selectedLayer == layer) && isLayerMode

        return VStack(alignment: .leading, spacing: 6) {
            if p.enabled {
                // Enabled layer: Switch + Dot + Letter + Note range (11pt, >= 4.5:1) + Arrows ‹ › (>= 28pt)
                HStack(spacing: 6) {
                    Toggle(
                        String(localized: "Enable Layer \(letter)", bundle: .module),
                        isOn: Binding(
                            get: { p.enabled },
                            set: { newVal in vm.updateLayerParams(layer) { $0.enabled = newVal } }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(String(localized: "Turn Layer \(letter) on or off", bundle: .module))

                    Circle()
                        .fill(isSelected ? StudioTokens.accent : StudioTokens.textSecondary)
                        .frame(width: 7, height: 7)

                    Text(String(localized: "Layer \(letter)", bundle: .module))
                        .font(StudioTokens.fontValueSemibold)
                        .foregroundStyle(StudioTokens.textPrimary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Text(verbatim: "\(shortNoteName(Int(p.keyLow)))–\(shortNoteName(Int(p.keyHigh)))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(StudioTokens.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 2)

                    HStack(spacing: 0) {
                        Button {
                            vm.stepLayerInstrument(layer: layer, delta: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(StudioTokens.textPrimary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L("Previous sound in folder"))

                        Button {
                            vm.stepLayerInstrument(layer: layer, delta: 1)
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(StudioTokens.textPrimary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L("Next sound in folder"))
                    }
                }
                .frame(height: 24)

                // Row 2: Sound selector (1 line), loading progress bar with Cancel, or inline actionable error
                if slot.isLoading {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(slot.loadProgress), total: 1.0)
                            .controlSize(.small)
                        Button(L("Cancel")) {
                            vm.cancelLayerLoad(layer: layer)
                        }
                        .buttonStyle(.plain)
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                    }
                    .frame(height: 24)
                } else if let err = slot.loadError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(StudioTokens.meterRed)
                        Text(err.message)
                            .font(StudioTokens.fontLabel)
                            .foregroundStyle(StudioTokens.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 2)
                        if case .missingFile = err {
                            Button(L("Locate…")) {
                                vm.locateMissingSound(forLayer: layer)
                            }
                            .buttonStyle(.plain)
                            .font(StudioTokens.fontLabel)
                            .foregroundStyle(StudioTokens.textPrimary)
                        } else if case .insufficientRAM = err {
                            Button(L("Purge on Demand")) {
                                vm.purgeOnDemandEnabled = true
                                vm.dismissLayerLoadError(layer: layer)
                            }
                            .buttonStyle(.plain)
                            .font(StudioTokens.fontLabel)
                            .foregroundStyle(StudioTokens.textPrimary)
                        }
                        Button {
                            vm.dismissLayerLoadError(layer: layer)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(StudioTokens.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(height: 24)
                    .background(StudioTokens.surfaceControl, in: .rect(cornerRadius: StudioTokens.controlRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioTokens.controlRadius)
                            .stroke(StudioTokens.meterRed.opacity(0.65), lineWidth: 1)
                    )
                    .help(err.message)
                } else {
                    TimbrePickerMenu(vm: vm, layer: layer)
                }

                // Row 3: Layer volume
                let volPercent = Double(p.volume) * 100.0
                let volBinding = Binding<Double>(
                    get: { Double(p.volume) * 100.0 },
                    set: { v in vm.updateLayerParams(layer) { $0.volume = Float(v / 100.0) } }
                )
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.1.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTokens.textSecondary)

                    Slider(
                        value: volBinding,
                        in: 0.0...150.0,
                        neutralValue: 100.0
                    ) {
                        Text(L("Volume"))
                    }
                    .labelsHidden()
                    .controlSize(.small)

                    Text(verbatim: String(format: "%.0f%%", volPercent))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(StudioTokens.textPrimary)
                        .fixedSize()
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .frame(height: 18)
            } else {
                // Disabled layer: only switch + letter + sound name (1 line).
                HStack(spacing: 8) {
                    Toggle(
                        String(localized: "Enable Layer \(letter)", bundle: .module),
                        isOn: Binding(
                            get: { p.enabled },
                            set: { newVal in vm.updateLayerParams(layer) { $0.enabled = newVal } }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(String(localized: "Turn Layer \(letter) on or off", bundle: .module))

                    if isSelected {
                        Circle()
                            .fill(StudioTokens.accent)
                            .frame(width: 7, height: 7)
                    }

                    Text(String(localized: "Layer \(letter)", bundle: .module))
                        .font(StudioTokens.fontValueSemibold)
                        .foregroundStyle(StudioTokens.textSecondary)
                        .lineLimit(1)

                    Spacer()
                }

                Text(slot.loaded ? slot.name : L("No Sound"))
                    .font(StudioTokens.fontBodyMedium)
                    .foregroundStyle(StudioTokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 2)

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            vm.selectedLayer = layer
            if !vm.selectedTab.isPerLayer {
                vm.selectedTab = vm.lastLayerTab
            }
        }
        // Static .glassEffect(.regular) on container so dragging the internal volume slider never warps the card
        .glassEffect(
            .regular,
            in: .rect(corners: .concentric(minimum: 12))
        )
        .glassEffectID("layer_card_\(layer)", in: layerGlassNamespace)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSelected
                        ? StudioTokens.accent
                        : (reduceTransparency ? StudioTokens.borderHairline : Color.clear),
                    lineWidth: isSelected ? 1.5 : 1.0
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Layer \(letter), \(slot.loaded ? slot.name : L("No Sound")), \(p.enabled ? L("On") : L("Off"))", bundle: .module))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 3. Main Editor for Selected Layer / Master (Solid Surfaces, Content-Matched Height)

    private func tabGroupPillBar(label: String, tabs: [WorkstationTab]) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(StudioTokens.fontSectionCaps)
                .tracking(0.8)
                .foregroundStyle(StudioTokens.textSecondary)
                .fixedSize()

            HStack(spacing: 2) {
                ForEach(tabs) { tab in
                    let isSelected = vm.selectedTab == tab
                    Button {
                        vm.selectedTab = tab
                    } label: {
                        Text(tab.title)
                            .font(StudioTokens.fontBodyMedium)
                            .foregroundStyle(isSelected ? StudioTokens.textPrimary : StudioTokens.textSecondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                isSelected ? StudioTokens.surfaceControl : Color.clear,
                                in: .rect(cornerRadius: 5)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(isSelected ? StudioTokens.textSecondary.opacity(0.45) : Color.clear, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "\(tab.title) (⌘\(tab.rawValue + 1))", bundle: .module))
                }
            }
            .padding(2)
            .background(StudioTokens.surfacePanel, in: .rect(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(StudioTokens.borderHairline, lineWidth: 1)
            )
        }
    }

    private func layerEditorSection(availableWidth: CGFloat) -> some View {
        let layer = vm.selectedLayer
        let letter = kLayerLetters[layer]
        let slot = vm.layers[layer]
        let p = slot.params
        let isLayerMode = vm.selectedTab.isPerLayer

        return VStack(alignment: .leading, spacing: 12) {
            // Editor Header:
            // - In Layer tabs: "Layer A — <sound name>"
            // - In Master tabs: "Master"
            // Plus two side-by-side tab groups: LAYER (Sound · Keyboard & Touch) and MASTER (MIDI · EQ · Drive · Mod · Delay · Reverb)
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isLayerMode ? StudioTokens.accent : StudioTokens.textSecondary)
                        .frame(width: 8, height: 8)

                    if isLayerMode {
                        Text(String(localized: "Layer \(letter) — \(slot.loaded ? slot.name : L("No Sound"))", bundle: .module))
                            .font(StudioTokens.fontSectionTitle)
                            .foregroundStyle(StudioTokens.textPrimary)
                            .lineLimit(1)

                        if slot.loaded {
                            Text(verbatim: "\(shortNoteName(Int(p.keyLow)))–\(shortNoteName(Int(p.keyHigh))) • \(String(format: "%.0f MiB", Double(slot.decodedBytes) / 1048576.0))")
                                .font(StudioTokens.fontLabel.monospacedDigit())
                                .foregroundStyle(StudioTokens.textSecondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(StudioTokens.surfacePanel, in: .capsule)
                                .overlay(Capsule().stroke(StudioTokens.borderHairline, lineWidth: 1))
                        } else {
                            Button(L("Load Sound…")) {
                                vm.openFilePicker(forLayer: layer)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                    } else {
                        Text(L("Master"))
                            .font(StudioTokens.fontSectionTitle)
                            .foregroundStyle(StudioTokens.textPrimary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 12) {
                    tabGroupPillBar(label: L("LAYER"), tabs: WorkstationTab.layerTabs)
                    Divider()
                        .overlay(StudioTokens.borderHairline)
                        .frame(height: 18)
                    tabGroupPillBar(label: L("MASTER"), tabs: WorkstationTab.masterTabs)
                }
                .fixedSize()
            }
            .padding(.horizontal, 2)

            // Only the editor scrolls, and only vertically; panels aligned to top with content height
            if isLayerMode, let err = slot.loadError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StudioTokens.meterRed)
                    Text(err.message)
                        .font(StudioTokens.fontBody)
                        .foregroundStyle(StudioTokens.textPrimary)
                        .lineLimit(2)
                    Spacer()
                    if case .missingFile = err {
                        Button(L("Locate…")) {
                            vm.locateMissingSound(forLayer: layer)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                    } else if case .insufficientRAM = err {
                        Button(L("Purge on Demand")) {
                            vm.purgeOnDemandEnabled = true
                            vm.dismissLayerLoadError(layer: layer)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                    }
                    Button(L("Dismiss")) {
                        vm.dismissLayerLoadError(layer: layer)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(StudioTokens.surfacePanel, in: .rect(cornerRadius: StudioTokens.panelRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: StudioTokens.panelRadius)
                        .stroke(StudioTokens.meterRed.opacity(0.65), lineWidth: 1)
                )
            }

            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    switch vm.selectedTab {
                    case .timbre:
                        timbreTabContent(layer: layer, availableWidth: availableWidth)
                    case .keyboard:
                        keyboardTabContent(layer: layer, availableWidth: availableWidth)
                    case .midiCC:
                        midiCCTabContent(layer: layer, availableWidth: availableWidth)
                    case .eq:
                        eqTabContent(availableWidth: availableWidth)
                    case .drive:
                        driveTabContent(availableWidth: availableWidth)
                    case .mod:
                        modTabContent(availableWidth: availableWidth)
                    case .delay:
                        delayTabContent(availableWidth: availableWidth)
                    case .reverb:
                        reverbTabContent(availableWidth: availableWidth)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // Helper for Layer Parameter Bindings
    private func layerBinding<T>(
        _ layer: Int,
        _ get: @escaping (NPNOLayerParams) -> T,
        _ set: @escaping (inout NPNOLayerParams, T) -> Void
    ) -> Binding<T> {
        Binding(
            get: { get(vm.layers[layer].params) },
            set: { v in vm.updateLayerParams(layer) { set(&$0, v) } }
        )
    }

    // MARK: - Deterministic Responsive Layout Helper (3 Columns without oscillating on text width, or 2 + 1 below)

    @ViewBuilder
    private func responsiveThreePanelLayout<P1: View, P2: View, P3: View>(
        availableWidth: CGFloat,
        p1Priority: Double = 1.15,
        p2Priority: Double = 0.90,
        p3Priority: Double = 0.95,
        @ViewBuilder panel1: () -> P1,
        @ViewBuilder panel2: () -> P2,
        @ViewBuilder panel3: () -> P3
    ) -> some View {
        if availableWidth >= 980 {
            let spacing: CGFloat = 12
            let usable = max(300, availableWidth - spacing * 2)
            let totalWeight = CGFloat(max(0.1, p1Priority + p2Priority + p3Priority))
            let w1 = floor(usable * CGFloat(p1Priority) / totalWeight)
            let w2 = floor(usable * CGFloat(p2Priority) / totalWeight)
            let w3 = max(100, usable - w1 - w2)

            HStack(alignment: .top, spacing: spacing) {
                panel1()
                    .frame(width: w1)
                panel2()
                    .frame(width: w2)
                panel3()
                    .frame(width: w3)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            let spacing: CGFloat = 12
            let halfW = floor(max(200, availableWidth - spacing) / 2.0)

            VStack(spacing: spacing) {
                HStack(alignment: .top, spacing: spacing) {
                    panel1()
                        .frame(width: halfW)
                    panel2()
                        .frame(width: max(100, availableWidth - spacing - halfW))
                }
                .fixedSize(horizontal: false, vertical: true)

                panel3()
                    .frame(width: availableWidth)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Tab 1: Sound (Tone & Filter · Compressor · Envelope)

    private func timbreTabContent(layer: Int, availableWidth: CGFloat) -> some View {
        let lp = vm.layers[layer].params

        // Combined compressor mode: 0 = Off, 1 = Normal, 2 = Fast
        let compModeBinding = Binding<Int>(
            get: {
                if !lp.compOn { return 0 }
                return lp.compFast ? 2 : 1
            },
            set: { mode in
                vm.updateLayerParams(layer) {
                    switch mode {
                    case 0:
                        $0.compOn = false
                    case 1:
                        $0.compOn = true
                        $0.compFast = false
                    default:
                        $0.compOn = true
                        $0.compFast = true
                    }
                }
            }
        )

        let timbreModes: [(tag: Int, title: String)] = [
            (2, L("Soft")),
            (0, L("Mid")),
            (1, L("Bright")),
            (3, L("Dyno 1")),
            (4, L("Dyno 2"))
        ]

        return responsiveThreePanelLayout(
            availableWidth: availableWidth,
            p1Priority: 1.25,
            p2Priority: 0.75,
            p3Priority: 1.00,
            panel1: {
                // Panel 1: Tone & Filter (Centered 56pt knobs)
                SectionCard(title: L("Tone & Filter")) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Text(L("Tone Character"))
                                .font(StudioTokens.fontLabel)
                                .foregroundStyle(StudioTokens.textSecondary)

                            Spacer()

                            HStack(spacing: 4) {
                                ForEach(timbreModes, id: \.tag) { mode in
                                    let active = Int(lp.timbreMode) == mode.tag
                                    Button {
                                        vm.updateLayerParams(layer) { $0.timbreMode = Int32(mode.tag) }
                                    } label: {
                                        Text(mode.title)
                                            .font(StudioTokens.fontLabel)
                                            .foregroundStyle(active ? StudioTokens.textPrimary : StudioTokens.textSecondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(
                                                active ? StudioTokens.borderHairline : StudioTokens.surfaceControl,
                                                in: .rect(cornerRadius: 5)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 5)
                                                    .stroke(active ? StudioTokens.textSecondary.opacity(0.6) : StudioTokens.borderHairline, lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        HStack(spacing: 14) {
                            Toggle(
                                L("Sustain Pedal"),
                                isOn: layerBinding(layer, { $0.sustainPedalOn }, { $0.sustainPedalOn = $1 })
                            )
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(StudioTokens.fontBody)
                            .help(L("Allow the sustain pedal to hold notes on this layer"))

                            Toggle(
                                L("String Resonance"),
                                isOn: layerBinding(layer, { $0.undampedOn }, { $0.undampedOn = $1 })
                            )
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(StudioTokens.fontBody)
                            .help(L("Sympathetic resonance of undamped upper strings"))

                            Spacer(minLength: 4)

                            Stepper(
                                value: layerBinding(layer, { Int($0.octaveShift) }, { $0.octaveShift = Int32($1) }),
                                in: -3...3
                            ) {
                                let oct = Int(lp.octaveShift)
                                Text(String(localized: "Octave: \(oct == 0 ? "0" : String(format: "%+d", oct))", bundle: .module))
                                    .font(StudioTokens.fontValue)
                                    .fixedSize()
                            }
                            .help(L("Layer octave shift (-3 to +3)"))
                        }

                        Divider().overlay(StudioTokens.borderHairline)

                        // Tone & Filter knobs: centered, 56pt
                        HStack(spacing: 18) {
                            Spacer(minLength: 0)

                            ProKnob(
                                idKey: "L\(layer)_flt",
                                title: L("Filter"),
                                value: layerBinding(layer, { Double($0.filter) * 100.0 }, { $0.filter = Float($1 / 100.0) }),
                                range: 0.0...100.0,
                                defaultValue: 100.0,
                                valueFormatter: { v in
                                    let fc = 140.0 * pow(142.857, v / 100.0)
                                    return fc >= 1000.0
                                        ? String(format: "%.1f kHz", fc / 1000.0)
                                        : String(format: "%.0f Hz", fc)
                                },
                                size: 56
                            )

                            ProKnob(
                                idKey: "L\(layer)_fxam",
                                title: L("String Resonance"),
                                value: layerBinding(layer, { Double($0.fxaAmount) * 100.0 }, { $0.fxaAmount = Float($1 / 100.0) }),
                                range: 0.0...100.0,
                                defaultValue: 20.0,
                                valueFormatter: { String(format: "%.0f%%", $0) },
                                size: 56
                            )

                            ProKnob(
                                idKey: "L\(layer)_fxrt",
                                title: L("Release Tail"),
                                value: layerBinding(layer, { Double($0.fxaRelease) * 100.0 }, { $0.fxaRelease = Float($1 / 100.0) }),
                                range: 0.0...100.0,
                                defaultValue: 50.0,
                                valueFormatter: { String(format: "%.0f%%", $0) },
                                size: 56,
                                enabled: lp.fxaAmount > 0.005
                            )

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            },
            panel2: {
                // Panel 2: Compressor (Segmented Off/Normal/Fast + Amount knob)
                SectionCard(title: L("Compressor")) {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("Response Mode"))
                                .font(StudioTokens.fontLabel)
                                .foregroundStyle(StudioTokens.textSecondary)

                            Picker(L("Compressor Mode"), selection: compModeBinding) {
                                Text(L("Off")).tag(0)
                                Text(L("Normal")).tag(1)
                                Text(L("Fast")).tag(2)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        Divider().overlay(StudioTokens.borderHairline)

                        HStack {
                            Spacer()
                            ProKnob(
                                idKey: "L\(layer)_comp",
                                title: L("Amount"),
                                value: layerBinding(layer, { Double($0.compAmount) * 100.0 }, { $0.compAmount = Float($1 / 100.0) }),
                                range: 0.0...100.0,
                                defaultValue: 45.0,
                                valueFormatter: { String(format: "%.0f%%", $0) },
                                size: 48,
                                enabled: lp.compOn
                            )
                            Spacer()
                        }
                    }
                }
            },
            panel3: {
                // Panel 3: Envelope (Attack/Release disabled when Use Original Envelope is enabled)
                SectionCard(title: L("Envelope")) {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(
                            L("Use Original Envelope"),
                            isOn: layerBinding(layer, { $0.originalEnvelope }, { $0.originalEnvelope = $1 })
                        )
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(StudioTokens.fontBodyMedium)

                        Divider().overlay(StudioTokens.borderHairline)

                        HStack(spacing: 12) {
                            Spacer(minLength: 0)

                            ProKnob(
                                idKey: "L\(layer)_att",
                                title: L("Attack"),
                                value: layerBinding(layer, { Double($0.attackMs) }, { $0.attackMs = Float($1) }),
                                range: 0.5...1500.0,
                                defaultValue: 1.0,
                                valueFormatter: { $0 < 10 ? String(format: "%.1f ms", $0) : String(format: "%.0f ms", $0) },
                                size: 48,
                                enabled: !lp.originalEnvelope
                            )

                            ProKnob(
                                idKey: "L\(layer)_rel",
                                title: L("Release"),
                                value: layerBinding(layer, { Double($0.releaseMs) }, { $0.releaseMs = Float($1) }),
                                range: 30.0...4000.0,
                                defaultValue: 600.0,
                                valueFormatter: { String(format: "%.0f ms", $0) },
                                size: 48,
                                enabled: !lp.originalEnvelope
                            )

                            ProKnob(
                                idKey: "global_relnoise",
                                title: L("Release Noise"),
                                value: $vm.releaseNoisePercent,
                                range: 0.0...200.0,
                                defaultValue: 100.0,
                                valueFormatter: { $0 <= 0.5 ? "0%" : String(format: "%.0f%%", $0) },
                                size: 48
                            )

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        )
    }

    // MARK: - Tab 2: Keyboard & Touch (Touch · Keyboard Zone / Velocity Range · Articulation)

    private func keyboardTabContent(layer: Int, availableWidth: CGFloat) -> some View {
        let lp = vm.layers[layer].params
        let globalIdx = Int(vm.globalVelocityCurve.rounded())

        return responsiveThreePanelLayout(
            availableWidth: availableWidth,
            p1Priority: 1.00,
            p2Priority: 1.15,
            p3Priority: 0.85,
            panel1: {
                // Panel 1: Touch (3x2 velocity curve thumbnail grid + 3-item Global Touch segmented picker)
                SectionCard(title: L("Touch")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("Velocity Curve"))
                            .font(StudioTokens.fontLabel)
                            .foregroundStyle(StudioTokens.textSecondary)

                        VelocityCurveThumbnailGrid(
                            selectedCurve: layerBinding(layer, { Int($0.velocityCurve) }, { $0.velocityCurve = Int32($1) }),
                            globalCurve: globalIdx
                        )

                        Divider().overlay(StudioTokens.borderHairline)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("Global Touch"))
                                .font(StudioTokens.fontLabel)
                                .foregroundStyle(StudioTokens.textSecondary)

                            Picker(L("Global Touch"), selection: Binding(
                                get: { Int(vm.globalVelocityCurve.rounded()) },
                                set: { vm.globalVelocityCurve = Double($0) }
                            )) {
                                Text(L("Light")).tag(-1)
                                Text(L("Normal")).tag(0)
                                Text(L("Heavy")).tag(1)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }
                }
            },
            panel2: {
                // Panel 2: Split into two blocks ("Keyboard Zone" and "Velocity Range") in the same card + "Reset Zone" (.glass)
                SectionCard(
                    title: L("Keyboard Zone"),
                    headerTrailing: {
                        Button(L("Reset Zone")) {
                            vm.updateLayerParams(layer) {
                                $0.keyLow = 0
                                $0.keyHigh = 127
                                $0.velLow = 1
                                $0.velHigh = 127
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        // Block 1: Keyboard Zone (range slider over mini-keyboard)
                        KeyZoneRangeControl(
                            keyLow: layerBinding(layer, { Int($0.keyLow) }, { $0.keyLow = Int32($1) }),
                            keyHigh: layerBinding(layer, { Int($0.keyHigh) }, { $0.keyHigh = Int32($1) }),
                            layerIndex: layer
                        )

                        Divider().overlay(StudioTokens.borderHairline)

                        // Block 2: Velocity Range + MIDI Channel
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L("Velocity Range"))
                                .font(StudioTokens.fontSectionTitle)
                                .foregroundStyle(StudioTokens.textPrimary)

                            DualRangeSlider(
                                title: L("Velocity Range"),
                                lowValue: layerBinding(layer, { Int($0.velLow) }, { $0.velLow = Int32($1) }),
                                highValue: layerBinding(layer, { Int($0.velHigh) }, { $0.velHigh = Int32($1) }),
                                bounds: 1...127,
                                valueFormatter: { "\($0)" }
                            )

                            HStack {
                                Text(L("MIDI Channel"))
                                    .font(StudioTokens.fontLabel)
                                    .foregroundStyle(StudioTokens.textSecondary)
                                Spacer()
                                Picker(L("MIDI Channel"), selection: layerBinding(layer, { Int($0.midiChannel) }, { $0.midiChannel = Int32($1) })) {
                                    Text(L("Global / Omni")).tag(0)
                                    ForEach(1...16, id: \.self) { ch in
                                        Text(String(localized: "Channel \(ch)", bundle: .module)).tag(ch)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 140)
                            }
                        }
                    }
                }
            },
            panel3: {
                // Panel 3: Articulation
                SectionCard(title: L("Articulation")) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Spacer(minLength: 0)

                            ProKnob(
                                idKey: "L\(layer)_plo",
                                title: L("Bend ↓"),
                                value: layerBinding(layer, { Double($0.pitchBendDown) }, { $0.pitchBendDown = Int32($1.rounded()) }),
                                range: -24.0...0.0,
                                defaultValue: -2.0,
                                step: 1.0,
                                valueFormatter: { String(format: "%d st", Int($0.rounded())) },
                                size: 36
                            )

                            ProKnob(
                                idKey: "L\(layer)_phi",
                                title: L("Bend ↑"),
                                value: layerBinding(layer, { Double($0.pitchBendUp) }, { $0.pitchBendUp = Int32($1.rounded()) }),
                                range: 0.0...24.0,
                                defaultValue: 2.0,
                                step: 1.0,
                                valueFormatter: { String(format: "+%d st", Int($0.rounded())) },
                                size: 36
                            )

                            ProKnob(
                                idKey: "L\(layer)_port",
                                title: L("Portamento"),
                                value: layerBinding(layer, { Double($0.portamentoTimeMs) }, { $0.portamentoTimeMs = Float($1) }),
                                range: 5.0...1500.0,
                                defaultValue: 120.0,
                                valueFormatter: { String(format: "%.0f ms", $0) },
                                size: 36,
                                enabled: lp.portamentoOn || lp.legatoMono
                            )

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)

                        Divider().overlay(StudioTokens.borderHairline)

                        HStack(spacing: 16) {
                            Toggle(L("Portamento"), isOn: layerBinding(layer, { $0.portamentoOn }, { $0.portamentoOn = $1 }))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .font(StudioTokens.fontBody)

                            Toggle(L("Mono Legato"), isOn: layerBinding(layer, { $0.legatoMono }, { $0.legatoMono = $1 }))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .font(StudioTokens.fontBody)
                        }

                        HStack(spacing: 10) {
                            Toggle(L("Fixed Velocity"), isOn: layerBinding(layer, { $0.fixedVelocity }, { $0.fixedVelocity = $1 }))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .font(StudioTokens.fontBody)

                            Spacer(minLength: 4)

                            Stepper(
                                value: layerBinding(layer, { Int($0.fixedVelocityValue) }, { $0.fixedVelocityValue = Int32($1) }),
                                in: 1...127,
                                step: 1
                            ) {
                                Text(String(localized: "Value: \(lp.fixedVelocityValue)", bundle: .module))
                                    .font(StudioTokens.fontValue)
                                    .foregroundStyle(lp.fixedVelocity ? StudioTokens.textPrimary : StudioTokens.textDisabled)
                                    .fixedSize()
                            }
                            .disabled(!lp.fixedVelocity)
                        }
                    }
                }
            }
        )
    }

    // MARK: - Master Tab: MIDI (Layer MIDI Controls + Knob/Control Mappings)

    private func midiCCTabContent(layer: Int, availableWidth: CGFloat) -> some View {
        let lp = vm.layers[layer].params
        let mappings = vm.knobMidiMappings.sorted { $0.key < $1.key }
        let spacing: CGFloat = 12
        let colW = floor(max(300, availableWidth - spacing) / 2.0)

        return HStack(alignment: .top, spacing: spacing) {
            // Column 1: Layer CC Table (Parameter | CC | Learn) with Layer A/B/C/D selector
            SectionCard(
                title: L("Layer MIDI Controls"),
                headerTrailing: {
                    Picker(L("Layer"), selection: $vm.selectedLayer) {
                        ForEach(0..<4, id: \.self) { idx in
                            Text(String(localized: "Layer \(kLayerLetters[idx])", bundle: .module)).tag(idx)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L("Parameter"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(L("CC"))
                            .frame(width: 130, alignment: .leading)
                        Text(L("Learn"))
                            .frame(width: 96, alignment: .trailing)
                    }
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(StudioTokens.textSecondary)
                    .padding(.horizontal, 8)

                    Divider().overlay(StudioTokens.borderHairline)

                    layerCCRow(
                        layer: layer,
                        slot: 0,
                        parameterName: L("Layer Volume"),
                        ccValue: Int(lp.ccVolume)
                    ) { newCC in
                        vm.updateLayerParams(layer) { $0.ccVolume = Int32(newCC) }
                    }

                    layerCCRow(
                        layer: layer,
                        slot: 1,
                        parameterName: L("LP/HP Cutoff"),
                        ccValue: Int(lp.ccFilter)
                    ) { newCC in
                        vm.updateLayerParams(layer) { $0.ccFilter = Int32(newCC) }
                    }

                    layerCCRow(
                        layer: layer,
                        slot: 2,
                        parameterName: L("String Resonance"),
                        ccValue: Int(lp.ccFxaAmount)
                    ) { newCC in
                        vm.updateLayerParams(layer) { $0.ccFxaAmount = Int32(newCC) }
                    }

                    layerCCRow(
                        layer: layer,
                        slot: 3,
                        parameterName: L("Release Tail"),
                        ccValue: Int(lp.ccFxaRelease)
                    ) { newCC in
                        vm.updateLayerParams(layer) { $0.ccFxaRelease = Int32(newCC) }
                    }
                }
            }
            .frame(width: colW)

            // Column 2: Knob Mappings Table
            SectionCard(
                title: L("MIDI Mappings"),
                subtitle: String(localized: "\(mappings.count) active", bundle: .module),
                headerTrailing: {
                    if let activeKey = vm.activeMidiLearnKey {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(StudioTokens.accent)
                                .frame(width: 8, height: 8)
                            Text(String(localized: "Waiting for CC for \(friendlyKnobName(activeKey))…", bundle: .module))
                                .font(StudioTokens.fontLabel)
                                .foregroundStyle(StudioTokens.textPrimary)
                                .lineLimit(1)
                            Button(L("Cancel")) {
                                vm.activeMidiLearnKey = nil
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                    }
                }
            ) {
                if mappings.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 20))
                            .foregroundStyle(StudioTokens.textSecondary)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("No MIDI mappings"))
                                .font(StudioTokens.fontBodyMedium)
                                .foregroundStyle(StudioTokens.textPrimary)
                            Text(L("Right-click any knob or control and choose \"Learn MIDI CC\", then move a physical control on your MIDI controller."))
                                .font(StudioTokens.fontLabel)
                                .foregroundStyle(StudioTokens.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(StudioTokens.surfaceControl.opacity(0.45), in: .rect(cornerRadius: 8))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L("Parameter"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(L("CC"))
                                .frame(width: 72, alignment: .leading)
                            Text(L("Remove"))
                                .frame(width: 64, alignment: .trailing)
                        }
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                        .padding(.horizontal, 10)

                        Divider().overlay(StudioTokens.borderHairline)

                        VStack(spacing: 4) {
                            ForEach(mappings, id: \.key) { item in
                                HStack {
                                    Text(friendlyKnobName(item.key))
                                        .font(StudioTokens.fontBodyMedium)
                                        .foregroundStyle(StudioTokens.textPrimary)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Text(String(localized: "CC \(item.value)", bundle: .module))
                                        .font(StudioTokens.fontValue)
                                        .foregroundStyle(StudioTokens.textPrimary)
                                        .frame(width: 72, alignment: .leading)

                                    Button(role: .destructive) {
                                        vm.unassignKnobCC(idKey: item.key)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 12))
                                    }
                                    .buttonStyle(.glass)
                                    .controlSize(.small)
                                    .frame(width: 64, alignment: .trailing)
                                    .help(String(localized: "Remove mapping for \(friendlyKnobName(item.key))", bundle: .module))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    StudioTokens.surfaceControl,
                                    in: .rect(cornerRadius: StudioTokens.controlRadius)
                                )
                            }
                        }
                    }
                }
            }
            .frame(width: max(100, availableWidth - spacing - colW))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func layerCCRow(
        layer: Int,
        slot: Int,
        parameterName: String,
        ccValue: Int,
        onSelect: @escaping (Int) -> Void
    ) -> some View {
        let isLearning = (vm.midiLearnLayer == layer && vm.midiLearnSlot == slot)
        let commonCCs = [1, 2, 4, 7, 10, 11, 16, 17, 18, 19, 71, 72, 73, 74, 91, 93]

        return HStack {
            Text(parameterName)
                .font(StudioTokens.fontBodyMedium)
                .foregroundStyle(StudioTokens.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker(L("CC"), selection: Binding(
                get: { ccValue },
                set: { onSelect($0) }
            )) {
                Text(L("Off")).tag(-1)
                Divider()
                ForEach(commonCCs, id: \.self) { c in
                    Text(String(localized: "CC \(c)", bundle: .module)).tag(c)
                }
                if ccValue >= 0 && !commonCCs.contains(ccValue) {
                    Text(String(localized: "CC \(ccValue)", bundle: .module)).tag(ccValue)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Button {
                vm.toggleMidiLearn(layer: layer, slot: slot)
            } label: {
                Text(isLearning ? L("Waiting…") : L("Learn"))
                    .frame(width: 82)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            StudioTokens.surfaceControl.opacity(0.6),
            in: .rect(cornerRadius: StudioTokens.controlRadius)
        )
    }

    // MARK: - Master Tab: EQ (3-Band Equalizer with Visual Response Curve)

    private func eqTabContent(availableWidth: CGFloat) -> some View {
        SectionCard(
            title: L("3-Band Equalizer"),
            headerTrailing: {
                Button(L("Flat (0 dB)")) {
                    vm.resetEq()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        ) {
            HStack(alignment: .center, spacing: 24) {
                EQResponseGraph(
                    bassDb: vm.eqBassDb,
                    midDb: vm.eqMidDb,
                    midFreqHz: vm.eqMidFreqHz,
                    trebleDb: vm.eqTrebleDb
                )
                .frame(minWidth: 280, maxWidth: .infinity)
                .frame(height: 112)

                Divider()
                    .overlay(StudioTokens.borderHairline)
                    .frame(height: 100)

                HStack(spacing: 18) {
                    ProKnob(
                        idKey: "eq_bass",
                        title: L("Bass"),
                        value: $vm.eqBassDb,
                        range: -15.0...15.0,
                        defaultValue: 0.0,
                        valueFormatter: { String(format: "%+.1f dB", $0) },
                        size: 56
                    )

                    ProKnob(
                        idKey: "eq_mid",
                        title: L("Mid"),
                        value: $vm.eqMidDb,
                        range: -15.0...15.0,
                        defaultValue: 0.0,
                        valueFormatter: { String(format: "%+.1f dB", $0) },
                        size: 56
                    )

                    ProKnob(
                        idKey: "eq_midf",
                        title: L("Mid Freq"),
                        value: $vm.eqMidFreqHz,
                        range: 200.0...5000.0,
                        defaultValue: 1000.0,
                        valueFormatter: {
                            $0 >= 1000.0
                                ? String(format: "%.1f kHz", $0 / 1000.0)
                                : String(format: "%.0f Hz", $0)
                        },
                        size: 56
                    )

                    ProKnob(
                        idKey: "eq_treb",
                        title: L("Treble"),
                        value: $vm.eqTrebleDb,
                        range: -15.0...15.0,
                        defaultValue: 0.0,
                        valueFormatter: { String(format: "%+.1f dB", $0) },
                        size: 56
                    )
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Master Tab: Drive (Harmonic Saturation)

    private func driveTabContent(availableWidth: CGFloat) -> some View {
        SectionCard(
            title: L("Drive"),
            headerTrailing: {
                Toggle(L("Enable Drive"), isOn: $vm.driveEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        ) {
            HStack(alignment: .center, spacing: 24) {
                // Saturation transfer curve visualization
                Canvas { context, size in
                    let w = size.width
                    let h = size.height
                    let midX = w / 2.0
                    let midY = h / 2.0

                    let bgRect = CGRect(origin: .zero, size: size)
                    context.fill(Path(roundedRect: bgRect, cornerRadius: 6), with: .color(StudioTokens.surfaceControl))

                    var grid = Path()
                    grid.move(to: CGPoint(x: 0, y: midY))
                    grid.addLine(to: CGPoint(x: w, y: midY))
                    grid.move(to: CGPoint(x: midX, y: 0))
                    grid.addLine(to: CGPoint(x: midX, y: h))
                    context.stroke(grid, with: .color(StudioTokens.borderHairline), lineWidth: 1.0)

                    let driveNorm = vm.driveEnabled ? (vm.driveAmountPercent / 100.0) : 0.0
                    let k = 1.0 + driveNorm * 4.5
                    let normDenom = tanh(k)
                    let steps = 80
                    var curve = Path()
                    for i in 0...steps {
                        let t = Double(i) / Double(steps)
                        let xIn = (t * 2.0) - 1.0
                        let yOut = normDenom > 0.0001 ? (tanh(k * xIn) / normDenom) : xIn
                        let pt = CGPoint(
                            x: CGFloat(t) * w,
                            y: midY - CGFloat(yOut) * (h * 0.42)
                        )
                        if i == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
                    }
                    context.stroke(
                        curve,
                        with: .color(vm.driveEnabled ? StudioTokens.textPrimary : StudioTokens.textSecondary),
                        style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
                    )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(StudioTokens.borderHairline, lineWidth: 1)
                )
                .frame(minWidth: 260, maxWidth: .infinity)
                .frame(height: 112)

                Divider()
                    .overlay(StudioTokens.borderHairline)
                    .frame(height: 100)

                HStack(spacing: 24) {
                    Toggle(L("Drive"), isOn: $vm.driveEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(StudioTokens.fontBodyMedium)
                        .fixedSize()

                    ProKnob(
                        idKey: "eq_drive",
                        title: L("Amount"),
                        value: $vm.driveAmountPercent,
                        range: 0.0...100.0,
                        defaultValue: 25.0,
                        valueFormatter: { String(format: "%.0f%%", $0) },
                        size: 56,
                        enabled: vm.driveEnabled
                    )
                }
                .padding(.horizontal, 12)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Master Tab: Mod (Mod 1 & Mod 2 Side by Side)

    private func modTabContent(availableWidth: CGFloat) -> some View {
        let spacing: CGFloat = 12
        let colW = floor(max(300, availableWidth - spacing) / 2.0)

        return HStack(alignment: .top, spacing: spacing) {
            modulatorCard(title: L("Mod 1"), index: 1, mod: $vm.mod1)
                .frame(width: colW)
            modulatorCard(title: L("Mod 2"), index: 2, mod: $vm.mod2)
                .frame(width: max(100, availableWidth - spacing - colW))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func modulatorCard(title: String, index: Int, mod: Binding<NPNOModulatorParams>) -> some View {
        let m = mod.wrappedValue
        return SectionCard(
            title: title,
            headerTrailing: {
                Toggle(String(localized: "Enable \(title)", bundle: .module), isOn: Binding(
                    get: { mod.wrappedValue.enabled },
                    set: { mod.wrappedValue.enabled = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("Destination"))
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                    Spacer()
                    Picker(L("Destination"), selection: Binding(
                        get: { Int(mod.wrappedValue.target) },
                        set: { mod.wrappedValue.target = Int32($0) }
                    )) {
                        Text(L("Tremolo")).tag(0)
                        Text(L("Wah (Filter)")).tag(1)
                        Text(L("Vibrato")).tag(2)
                        Text(L("Auto-Pan")).tag(3)
                    }
                    .labelsHidden()
                    .frame(width: 145)
                    .disabled(!m.enabled)
                }

                HStack {
                    Text(L("Wave"))
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                    Spacer()
                    Picker(L("Waveform"), selection: Binding(
                        get: { Int(mod.wrappedValue.wave) },
                        set: { mod.wrappedValue.wave = Int32($0) }
                    )) {
                        Text(L("Sine")).tag(0)
                        Text(L("Triangle")).tag(1)
                        Text(L("Saw")).tag(2)
                        Text(L("Square")).tag(3)
                        Text(L("Envelope")).tag(4)
                    }
                    .labelsHidden()
                    .frame(width: 145)
                    .disabled(!m.enabled)
                }

                Divider().overlay(StudioTokens.borderHairline)

                HStack(spacing: 18) {
                    Spacer(minLength: 0)

                    ProKnob(
                        idKey: "mod\(index)_rate",
                        title: L("Rate"),
                        value: Binding(
                            get: { Double(mod.wrappedValue.rateHz) },
                            set: { mod.wrappedValue.rateHz = Float($0) }
                        ),
                        range: 0.1...20.0,
                        defaultValue: index == 1 ? 4.5 : 5.5,
                        valueFormatter: { String(format: "%.1f Hz", $0) },
                        size: 56,
                        enabled: m.enabled
                    )

                    ProKnob(
                        idKey: "mod\(index)_depth",
                        title: L("Depth"),
                        value: Binding(
                            get: { Double(mod.wrappedValue.depth) * 100.0 },
                            set: { mod.wrappedValue.depth = Float($0 / 100.0) }
                        ),
                        range: 0.0...100.0,
                        defaultValue: index == 1 ? 35.0 : 20.0,
                        valueFormatter: { String(format: "%.0f%%", $0) },
                        size: 56,
                        enabled: m.enabled
                    )

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Master Tab: Delay (Stereo Delay)

    private func delayTabContent(availableWidth: CGFloat) -> some View {
        let divisions = [L("1/4"), L("1/8"), L("1/8 Dotted"), L("1/8 Triplet"), L("1/16")]

        return SectionCard(
            title: L("Stereo Delay"),
            headerTrailing: {
                HStack(spacing: 10) {
                    Button {
                        vm.tapDelayTempo()
                    } label: {
                        Label(L("Tap Tempo"), systemImage: "hand.tap")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)

                    Toggle(L("Enable Delay"), isOn: $vm.delay.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 20) {
                    Toggle(L("Stereo Ping-Pong"), isOn: $vm.delay.pingPong)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(StudioTokens.fontBody)
                        .disabled(!vm.delay.enabled)

                    Toggle(L("Sync to BPM"), isOn: $vm.delay.syncToHost)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(StudioTokens.fontBody)
                        .disabled(!vm.delay.enabled)
                }

                Divider().overlay(StudioTokens.borderHairline)

                HStack(spacing: 24) {
                    Spacer(minLength: 0)

                    ProKnob(
                        idKey: "dly_amt",
                        title: L("Mix"),
                        value: Binding(
                            get: { Double(vm.delay.amount) * 100.0 },
                            set: { vm.delay.amount = Float($0 / 100.0) }
                        ),
                        range: 0.0...100.0,
                        defaultValue: 25.0,
                        valueFormatter: { String(format: "%.0f%%", $0) },
                        size: 56,
                        enabled: vm.delay.enabled
                    )

                    ProKnob(
                        idKey: "dly_fb",
                        title: L("Feedback"),
                        value: Binding(
                            get: { Double(vm.delay.feedback) * 100.0 },
                            set: { vm.delay.feedback = Float($0 / 100.0) }
                        ),
                        range: 0.0...92.0,
                        defaultValue: 35.0,
                        valueFormatter: { String(format: "%.0f%%", $0) },
                        size: 56,
                        enabled: vm.delay.enabled
                    )

                    if vm.delay.syncToHost {
                        ProKnob(
                            idKey: "dly_div",
                            title: L("Division"),
                            value: Binding(
                                get: { Double(vm.delay.syncDivision) },
                                set: { vm.delay.syncDivision = Int32($0.rounded()) }
                            ),
                            range: 0.0...4.0,
                            defaultValue: 1.0,
                            step: 1.0,
                            valueFormatter: { divisions[min(max(Int($0.rounded()), 0), 4)] },
                            size: 56,
                            enabled: vm.delay.enabled
                        )

                        ProKnob(
                            idKey: "dly_bpm",
                            title: L("BPM"),
                            value: Binding(
                                get: { Double(vm.delay.hostBpm) },
                                set: { vm.delay.hostBpm = Float($0.rounded()) }
                            ),
                            range: 40.0...240.0,
                            defaultValue: 120.0,
                            step: 1.0,
                            valueFormatter: { String(format: "%.0f BPM", $0) },
                            size: 56,
                            enabled: vm.delay.enabled
                        )
                    } else {
                        ProKnob(
                            idKey: "dly_time",
                            title: L("Time"),
                            value: Binding(
                                get: { Double(vm.delay.timeMs) },
                                set: { vm.delay.timeMs = Float($0) }
                            ),
                            range: 20.0...2000.0,
                            defaultValue: 360.0,
                            valueFormatter: { String(format: "%.0f ms", $0) },
                            size: 56,
                            enabled: vm.delay.enabled
                        )
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Master Tab: Reverb (Stereo Reverb)

    private func reverbTabContent(availableWidth: CGFloat) -> some View {
        SectionCard(
            title: L("Stereo Reverb"),
            headerTrailing: {
                Toggle(L("Enable Reverb"), isOn: $vm.reverb.enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Algorithmic stereo reverb with room size, decay, and high-frequency damping."))
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(StudioTokens.textSecondary)
                    .lineLimit(1)

                Divider().overlay(StudioTokens.borderHairline)

                HStack(spacing: 20) {
                    Spacer(minLength: 0)

                    ProKnob(
                        idKey: "rev_amt",
                        title: L("Mix"),
                        value: Binding(
                            get: { Double(vm.reverb.amount) * 100.0 },
                            set: { vm.reverb.amount = Float($0 / 100.0) }
                        ),
                        range: 0.0...100.0,
                        defaultValue: 22.0,
                        valueFormatter: { String(format: "%.0f%%", $0) },
                        size: 56,
                        enabled: vm.reverb.enabled
                    )

                    ProKnob(
                        idKey: "rev_size",
                        title: L("Size"),
                        value: Binding(
                            get: { Double(vm.reverb.size) * 100.0 },
                            set: { vm.reverb.size = Float($0 / 100.0) }
                        ),
                        range: 10.0...100.0,
                        defaultValue: 65.0,
                        valueFormatter: { String(format: "%.0f%%", $0) },
                        size: 56,
                        enabled: vm.reverb.enabled
                    )

                    ProKnob(
                        idKey: "rev_dec",
                        title: L("Decay"),
                        value: Binding(
                            get: { Double(vm.reverb.decay) * 100.0 },
                            set: { vm.reverb.decay = Float($0 / 100.0) }
                        ),
                        range: 10.0...100.0,
                        defaultValue: 55.0,
                        valueFormatter: { String(format: "%.0f%%", $0) },
                        size: 56,
                        enabled: vm.reverb.enabled
                    )

                    ProKnob(
                        idKey: "rev_damp",
                        title: L("Damping"),
                        value: Binding(
                            get: { Double(vm.reverb.damping) * 100.0 },
                            set: { vm.reverb.damping = Float($0 / 100.0) }
                        ),
                        range: 0.0...100.0,
                        defaultValue: 45.0,
                        valueFormatter: { String(format: "%.0f%%", $0) },
                        size: 56,
                        enabled: vm.reverb.enabled
                    )

                    ProKnob(
                        idKey: "rev_predly",
                        title: L("Pre-Delay"),
                        value: Binding(
                            get: { Double(vm.reverb.preDelayMs) },
                            set: { vm.reverb.preDelayMs = Float($0) }
                        ),
                        range: 0.0...120.0,
                        defaultValue: 18.0,
                        valueFormatter: { String(format: "%.0f ms", $0) },
                        size: 56,
                        enabled: vm.reverb.enabled
                    )

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 4. Bottom Status Bar (safeAreaInset, Light Material, Not Glass)

    private var statusBarSection: some View {
        HStack(spacing: 14) {
            // Sustain Pedal (isolated in leaf subview to avoid invalidating ContentView at 60 Hz)
            StatusBarSustainButton(vm: vm, telemetry: vm.telemetry)

            Divider().frame(height: 14)

            // MIDI Device (truncated + full tooltip)
            HStack(spacing: 6) {
                Circle()
                    .fill(vm.midiSourceCount > 0 ? StudioTokens.meterGreen : StudioTokens.textDisabled)
                    .frame(width: 7, height: 7)

                Text(String(localized: "MIDI: \(vm.midiSources)", bundle: .module))
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(StudioTokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 240, alignment: .leading)
            }
            .help(String(localized: "MIDI Controllers: \(vm.midiSources)", bundle: .module))

            if let err = vm.errorMessage {
                Divider().frame(height: 14)
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(StudioTokens.meterYellow)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            // Sample Rate
            Text(verbatim: String(format: "%.1f kHz", vm.sampleRate / 1000.0))
                .font(StudioTokens.fontLabel.monospacedDigit())
                .foregroundStyle(StudioTokens.textSecondary)
                .help(L("Active Core Audio engine sample rate"))

            Divider().frame(height: 14)

            // Active Voices / Limit (isolated in leaf subview with fixed width so it never jumps while playing)
            StatusBarVoicesMenu(vm: vm, telemetry: vm.telemetry)

            Divider().frame(height: 14)

            // RAM + Purge / Reload
            HStack(spacing: 8) {
                Text(verbatim: String(
                    format: "RAM: %.0f / %.0f MiB",
                    Double(vm.totalMemoryBytes) / 1048576.0,
                    Double(vm.totalUnpurgedBytes) / 1048576.0
                ))
                .font(StudioTokens.fontLabel.monospacedDigit())
                .foregroundStyle(StudioTokens.textSecondary)
                .frame(minWidth: 118, alignment: .trailing)

                if vm.totalMemoryBytes < vm.totalUnpurgedBytes {
                    Button(L("Reload")) {
                        vm.reloadPurgedMemory()
                    }
                    .buttonStyle(.plain)
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(StudioTokens.textPrimary)
                    .help(L("Reload purged samples into RAM"))
                } else {
                    Button(L("Purge")) {
                        vm.purgeUnusedMemory()
                    }
                    .buttonStyle(.plain)
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(StudioTokens.textPrimary)
                    .help(L("Purge unused samples from RAM (⇧⌘P)"))
                }
            }

            Divider().frame(height: 14)

            if abs(vm.uiScale - 1.0) > 0.01 {
                Button {
                    vm.uiScale = 1.0
                } label: {
                    Text(String(localized: "Zoom: \(Int((vm.uiScale * 100).rounded()))%", bundle: .module))
                        .font(StudioTokens.fontLabel.monospacedDigit())
                        .foregroundStyle(StudioTokens.textPrimary)
                }
                .buttonStyle(.plain)
                .help(L("Click to reset zoom to 100% (⌘0)"))

                Divider().frame(height: 14)
            }

            // Toggle 61-key Keyboard (Cmd+K)
            Button {
                vm.showVirtualKeyboard.toggle()
            } label: {
                Label(L("Keyboard"), systemImage: "pianokeys")
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(vm.showVirtualKeyboard ? StudioTokens.textPrimary : StudioTokens.textSecondary)
            }
            .buttonStyle(.plain)
            .help(L("Show or hide 61-key on-screen keyboard (⌘K)"))
        }
        .padding(.horizontal, StudioTokens.grid2)
        .frame(height: 28)
        .background(reduceTransparency ? AnyShapeStyle(StudioTokens.surfacePanel) : AnyShapeStyle(.ultraThinMaterial))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(StudioTokens.borderHairline)
                .frame(height: 1)
        }
    }
}

// MARK: - Isolated Leaf Subviews for 60 Hz Telemetry (Zero Main Window Re-render)

private struct ToolbarPeakMeterView: View {
    @ObservedObject var telemetry: AudioTelemetryModel

    var body: some View {
        StereoPeakMeter(peakL: telemetry.peakL, peakR: telemetry.peakR, segments: 10, barWidth: 52)
    }
}

private struct StatusBarSustainButton: View {
    let vm: PianoViewModel
    @ObservedObject var telemetry: AudioTelemetryModel

    var body: some View {
        Button {
            vm.setSustain(!telemetry.sustainDown)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(telemetry.sustainDown ? StudioTokens.meterGreen : StudioTokens.textDisabled)
                    .frame(width: 7, height: 7)
                Text(L("Sustain"))
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(telemetry.sustainDown ? StudioTokens.textPrimary : StudioTokens.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .help(L("Sustain pedal state (Spacebar to hold)"))
    }
}

private struct StatusBarVoicesMenu: View {
    @ObservedObject var vm: PianoViewModel
    @ObservedObject var telemetry: AudioTelemetryModel

    var body: some View {
        Menu {
            ForEach([64, 128, 256, 512], id: \.self) { limit in
                Button {
                    vm.maxVoices = limit
                } label: {
                    if vm.maxVoices == limit {
                        Label(String(localized: "Max Polyphony: \(limit) voices", bundle: .module), systemImage: "checkmark")
                    } else {
                        Text(String(localized: "Max Polyphony: \(limit) voices", bundle: .module))
                    }
                }
            }
        } label: {
            Text(String(localized: "Voices: \(String(format: "%3d", telemetry.activeVoices))/\(vm.maxVoices)", bundle: .module))
                .font(StudioTokens.fontLabel.monospacedDigit())
                .foregroundStyle(telemetry.activeVoices > 0 ? StudioTokens.textPrimary : StudioTokens.textSecondary)
                .frame(width: 96, alignment: .trailing)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Active polyphonic voices / click to change polyphony limit"))
    }
}

// MARK: - 61-Key On-Screen Keyboard at Bottom (~120pt, C1 = 24 to C6 = 84) with Layer Zones

struct VirtualKeyboard61View: View {
    @ObservedObject var vm: PianoViewModel
    @ObservedObject var telemetry: AudioTelemetryModel
    @State private var mouseHeldNote: Int? = nil

    private let startNote: Int = 24 // C1
    private let endNote: Int = 84   // C6 (61 keys)

    private func isBlackKey(_ note: Int) -> Bool {
        let pc = note % 12
        return pc == 1 || pc == 3 || pc == 6 || pc == 8 || pc == 10
    }

    private var whiteNotes: [Int] {
        (startNote...endNote).filter { !isBlackKey($0) }
    }

    var body: some View {
        VStack(spacing: 4) {
            // Zone strips for enabled layers (A, B, C, D)
            GeometryReader { geo in
                let totalSpan = CGFloat(endNote - startNote + 1)
                ZStack(alignment: .leading) {
                    ForEach(0..<4, id: \.self) { l in
                        let lp = vm.layers[l].params
                        if lp.enabled {
                            let clampedLow = max(startNote, min(endNote, Int(lp.keyLow)))
                            let clampedHigh = max(startNote, min(endNote, Int(lp.keyHigh)))
                            if clampedHigh >= clampedLow {
                                let xStart = geo.size.width * CGFloat(clampedLow - startNote) / totalSpan
                                let xEnd = geo.size.width * CGFloat(clampedHigh - startNote + 1) / totalSpan
                                Capsule()
                                    .fill(StudioTokens.layerZoneColors[l])
                                    .frame(width: max(6, xEnd - xStart), height: 3)
                                    .offset(x: xStart, y: CGFloat(l - 1) * 3.5)
                            }
                        }
                    }
                }
            }
            .frame(height: 14)

            // 61-key Canvas keyboard + mouse and MIDI interaction
            GeometryReader { geo in
                let whites = whiteNotes
                let whiteW = max(1.0, geo.size.width / CGFloat(whites.count))
                let h = geo.size.height

                Canvas { context, size in
                    // 1. White keys
                    for (idx, note) in whites.enumerated() {
                        let x = CGFloat(idx) * whiteW
                        let rect = CGRect(x: x + 0.5, y: 0, width: whiteW - 1.0, height: size.height)
                        let active = telemetry.keyVelocities[note] > 0 || mouseHeldNote == note
                        let fill = active ? StudioTokens.accent : StudioTokens.textPrimary.opacity(0.92)
                        context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(fill))

                        if note % 12 == 0 {
                            let label = Text(verbatim: shortNoteName(note))
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundColor(active ? .white : Color.black.opacity(0.68))
                            context.draw(label, at: CGPoint(x: x + whiteW / 2, y: size.height - 10))
                        }
                    }

                    // 2. Black keys
                    let blackW = whiteW * 0.62
                    let blackH = size.height * 0.60
                    for (idx, wNote) in whites.enumerated() {
                        let nextNote = wNote + 1
                        if nextNote <= endNote && isBlackKey(nextNote) {
                            let x = CGFloat(idx + 1) * whiteW - (blackW / 2.0)
                            let rect = CGRect(x: x, y: 0, width: blackW, height: blackH)
                            let active = telemetry.keyVelocities[nextNote] > 0 || mouseHeldNote == nextNote
                            let fill = active ? StudioTokens.accent : StudioTokens.surfaceWindow
                            context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(fill))
                            context.stroke(
                                Path(roundedRect: rect, cornerRadius: 2.5),
                                with: .color(StudioTokens.borderHairline),
                                lineWidth: 1
                            )
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            let note = hitTestNote(at: g.location, width: geo.size.width, height: h, whites: whites, whiteW: whiteW)
                            if mouseHeldNote != note {
                                if let old = mouseHeldNote {
                                    vm.noteOff(old)
                                }
                                mouseHeldNote = note
                                vm.noteOn(note, velocity: 0.80)
                            }
                        }
                        .onEnded { _ in
                            if let old = mouseHeldNote {
                                vm.noteOff(old)
                                mouseHeldNote = nil
                            }
                        }
                )
            }
        }
        .padding(8)
        .background(StudioTokens.surfacePanel, in: .rect(cornerRadius: StudioTokens.panelRadius))
        .overlay(
            RoundedRectangle(cornerRadius: StudioTokens.panelRadius)
                .stroke(StudioTokens.borderHairline, lineWidth: 1)
        )
    }

    private func hitTestNote(
        at point: CGPoint,
        width: CGFloat,
        height: CGFloat,
        whites: [Int],
        whiteW: CGFloat
    ) -> Int {
        let clampedX = min(max(0, point.x), width - 0.1)
        if point.y <= height * 0.60 {
            let blackW = whiteW * 0.62
            for (idx, wNote) in whites.enumerated() {
                let nextNote = wNote + 1
                if nextNote <= endNote && isBlackKey(nextNote) {
                    let x = CGFloat(idx + 1) * whiteW - (blackW / 2.0)
                    if clampedX >= x && clampedX <= x + blackW {
                        return nextNote
                    }
                }
            }
        }
        let wIdx = min(max(Int(clampedX / whiteW), 0), whites.count - 1)
        return whites[wIdx]
    }
}

// MARK: - Previews of the 5 Tabs at 1100, 1280, and 1440 Widths

@MainActor
private func makePreviewViewModel(tab: WorkstationTab) -> PianoViewModel {
    let vm = PianoViewModel()
    vm.selectedTab = tab
    return vm
}

#Preview("Tab 1: Sound — 1100pt") {
    ContentView(vm: makePreviewViewModel(tab: .timbre))
        .frame(width: 1100, height: 720)
}

#Preview("Tab 1: Sound — 1280pt") {
    ContentView(vm: makePreviewViewModel(tab: .timbre))
        .frame(width: 1280, height: 760)
}

#Preview("Tab 1: Sound — 1440pt") {
    ContentView(vm: makePreviewViewModel(tab: .timbre))
        .frame(width: 1440, height: 820)
}

#Preview("Tab 2: Keyboard & Touch — 1100pt") {
    ContentView(vm: makePreviewViewModel(tab: .keyboard))
        .frame(width: 1100, height: 720)
}

#Preview("Tab 2: Keyboard & Touch — 1280pt") {
    ContentView(vm: makePreviewViewModel(tab: .keyboard))
        .frame(width: 1280, height: 760)
}

#Preview("Tab 2: Keyboard & Touch — 1440pt") {
    ContentView(vm: makePreviewViewModel(tab: .keyboard))
        .frame(width: 1440, height: 820)
}

#Preview("Master: MIDI — 1280pt") {
    ContentView(vm: makePreviewViewModel(tab: .midiCC))
        .frame(width: 1280, height: 760)
}

#Preview("Master: EQ — 1280pt") {
    ContentView(vm: makePreviewViewModel(tab: .eq))
        .frame(width: 1280, height: 760)
}

#Preview("Master: Drive — 1280pt") {
    ContentView(vm: makePreviewViewModel(tab: .drive))
        .frame(width: 1280, height: 760)
}

#Preview("Master: Mod — 1280pt") {
    ContentView(vm: makePreviewViewModel(tab: .mod))
        .frame(width: 1280, height: 760)
}

#Preview("Master: Delay — 1280pt") {
    ContentView(vm: makePreviewViewModel(tab: .delay))
        .frame(width: 1280, height: 760)
}

#Preview("Master: Reverb — 1280pt") {
    ContentView(vm: makePreviewViewModel(tab: .reverb))
        .frame(width: 1280, height: 760)
}
