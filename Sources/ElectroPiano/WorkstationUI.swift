import AppKit
import NPNOBridge
import SwiftUI

// MARK: - Utilitários de Notas e Nomes de Parâmetros

let kLayerLetters = ["A", "B", "C", "D"]

func shortNoteName(_ note: Int) -> String {
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let n = min(max(note, 0), 127)
    return "\(names[n % 12])\((n / 12) - 1)"
}

/// Mesmas curvas do motor (Engine.cpp): primeiro a sensibilidade global, depois a curva da camada.
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
        "global_vol": "Volume Master",
        "global_pan": "Pan Master",
        "global_tune": "Afinação Fina",
        "global_a4": "Referência A4",
        "global_relnoise": "Ruído de Soltura",
        "eq_bass": "EQ Graves",
        "eq_mid": "EQ Médios",
        "eq_midf": "EQ Freq. Médios",
        "eq_treb": "EQ Agudos",
        "eq_drive": "Drive Intensidade",
        "dly_amt": "Delay Mix",
        "dly_fb": "Delay Feedback",
        "dly_time": "Delay Tempo",
        "dly_div": "Delay Divisão",
        "dly_bpm": "Delay BPM",
        "rev_amt": "Reverb Mix",
        "rev_size": "Reverb Tamanho",
        "rev_dec": "Reverb Decaimento",
        "rev_damp": "Reverb Absorção",
        "rev_predly": "Reverb Pré-Delay",
        "mod1_rate": "Mod 1 Velocidade",
        "mod1_depth": "Mod 1 Profundidade",
        "mod2_rate": "Mod 2 Velocidade",
        "mod2_depth": "Mod 2 Profundidade"
    ]
    if let f = fixed[key] { return f }
    if key.hasPrefix("L"),
       key.count > 3,
       let idx = Int(String(key[key.index(key.startIndex, offsetBy: 1)])),
       (0..<4).contains(idx) {
        let suffix = String(key.dropFirst(3))
        let names: [String: String] = [
            "vol": "Volume",
            "flt": "Filtro",
            "fxam": "Ambiência",
            "fxrt": "Cauda de Ambiência",
            "comp": "Compressor",
            "att": "Ataque",
            "rel": "Soltura",
            "klo": "Nota Inicial",
            "khi": "Nota Final",
            "vlo": "Velocity Mínima",
            "vhi": "Velocity Máxima",
            "plo": "Pitch Bend ↓",
            "phi": "Pitch Bend ↑",
            "port": "Tempo de Portamento"
        ]
        return "Camada \(kLayerLetters[idx]) · \(names[suffix] ?? suffix)"
    }
    return key
}

// MARK: - Escala de Zoom da Interface (Menu Visualizar: Cmd+, Cmd-, Cmd 0)

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

// MARK: - Curva de Velocidade & Grade 3x2 de Miniaturas

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

    // Ordem 3x2: Suave, Log, Normal / Linear, Forte, Exp
    private let rows: [[CurveItem]] = [
        [
            CurveItem(id: 1, title: "Suave"),
            CurveItem(id: 5, title: "Log"),
            CurveItem(id: 0, title: "Normal")
        ],
        [
            CurveItem(id: 2, title: "Linear"),
            CurveItem(id: 3, title: "Forte"),
            CurveItem(id: 4, title: "Exp")
        ]
    ]

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

                    // Grade sutil 2x2 + linha diagonal de referência
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
        .accessibilityLabel("Curva de velocidade \(item.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Menu Seletor de Timbre (.npno / .nsmp4) — Visual Neutro

struct TimbrePickerMenu: View {
    @ObservedObject var vm: PianoViewModel
    let layer: Int

    private var slot: LayerSlotState { vm.layers[layer] }

    var body: some View {
        Menu {
            if !vm.embeddedBanks.isEmpty {
                Section("Biblioteca de Timbres") {
                    ForEach(vm.embeddedBanks) { bank in
                        Button {
                            vm.loadLayerInstrument(layer: layer, from: bank.path)
                        } label: {
                            if slot.path == bank.path && slot.loaded {
                                Label(bank.displayName, systemImage: "checkmark")
                            } else {
                                Text(bank.displayName)
                            }
                        }
                    }
                }
                Divider()
            }
            Button {
                vm.openFilePicker(forLayer: layer)
            } label: {
                Label("Carregar arquivo .npno / .nsmp4…", systemImage: "folder")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: slot.loaded ? "pianokeys" : "folder.badge.plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioTokens.textSecondary)

                Text(slot.loaded ? slot.name : "Carregar timbre…")
                    .font(StudioTokens.fontBodyMedium)
                    .foregroundStyle(StudioTokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

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
        .menuStyle(.borderlessButton)
        .help(slot.loaded ? "\(slot.name) — \(slot.model)" : "Escolher arquivo .npno ou .nsmp4 para a Camada \(kLayerLetters[layer])")
    }
}

// MARK: - Janela Principal (ContentView)

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
        return activeNames.isEmpty ? "Inicial" : activeNames.joined(separator: " + ")
    }

    var body: some View {
        GeometryReader { geo in
            let scale = CGFloat(vm.uiScale)
            VStack(spacing: StudioTokens.grid2) {
                // 1. Faixa compacta de 4 camadas (~100pt) dentro de UM único GlassEffectContainer
                layerStripSection

                // 2. Editor da camada selecionada (painéis dimensionados ao conteúdo, alinhados ao topo; só rola na vertical)
                layerEditorSection
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                // 3. Teclado virtual de 61 teclas na base (~120pt), aberto por padrão (Cmd+K)
                if vm.showVirtualKeyboard {
                    VirtualKeyboard61View(vm: vm)
                        .frame(height: 118)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, StudioTokens.grid2)
            .padding(.top, StudioTokens.grid2)
            .padding(.bottom, StudioTokens.grid1)
            .frame(width: geo.size.width / scale, height: geo.size.height / scale, alignment: .top)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(minWidth: 1100, minHeight: 720)
        .background(StudioTokens.surfaceWindow)
        .preferredColorScheme(.dark)
        .navigationTitle("Electro Pro")
        .navigationSubtitle("Programa \(vm.selectedMemorySlot) — \(currentPresetTitle)")
        .toolbar {
            workstationToolbar
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            statusBarSection
        }
    }

    // MARK: - 1. Toolbar Nativa (5 Grupos Separados por ToolbarSpacer = 5 Cápsulas de Glass)

    @ToolbarContentBuilder
    private var workstationToolbar: some ToolbarContent {
        // Grupo 1: Programas 1–8 (Picker segmented, .fixedSize()) + Salvar (.glass, neutro)
        ToolbarItemGroup(placement: .automatic) {
            Picker("Programa", selection: Binding(
                get: { vm.selectedMemorySlot },
                set: { slot in vm.recallMemory(slot: slot) }
            )) {
                ForEach(1...8, id: \.self) { slot in
                    Text("\(slot)").tag(slot)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Selecionar Programa de Memória (1 a 8)")

            Button {
                vm.storeCurrentToMemory(slot: vm.selectedMemorySlot)
            } label: {
                Label(
                    vm.storeConfirmationActive ? "Salvo" : "Salvar",
                    systemImage: vm.storeConfirmationActive ? "checkmark" : "square.and.arrow.down"
                )
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glass)
            .popover(isPresented: $vm.showRenameProgramPopover, arrowEdge: .bottom) {
                renameProgramPopover
            }
            .help("Salvar estado atual no Programa \(vm.selectedMemorySlot) (⌘S). Para renomear: Arquivo > Renomear programa… (⇧⌘R)")
        }

        ToolbarSpacer(.fixed)

        // Grupo 2: Transpose [−] valor [+] com sinal (ex.: +2 st) + botão de Afinação (A4/Fine em popover)
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
                .help("Diminuir transposição em 1 semitom")

                let st = Int(vm.transposeSemitones.rounded())
                Text(st == 0 ? "0 st" : String(format: "%+d st", st))
                    .font(StudioTokens.fontValue)
                    .foregroundStyle(StudioTokens.textPrimary)
                    .fixedSize()
                    .frame(minWidth: 40, alignment: .center)
                    .onTapGesture(count: 2) {
                        vm.transposeSemitones = 0.0
                    }
                    .help("Transposição global em semitons (duplo clique para 0 st)")

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
                .help("Aumentar transposição em 1 semitom")
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
            .help("Afinação (Referência A4, Afinação Fina e Balanço Master)")
        }

        ToolbarSpacer(.fixed)

        // Grupo 3: Volume master: slider ~140pt + valor em dB + medidor L/R sem corte
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
                    Text("Volume Master")
                }
                .labelsHidden()
                .frame(width: 136)
                .help(String(format: "Volume Master: %+.1f dB (duplo clique no valor para 0 dB)", vm.masterGainDb))

                Text(String(format: "%+.1f dB", vm.masterGainDb))
                    .font(StudioTokens.fontValue)
                    .foregroundStyle(StudioTokens.textPrimary)
                    .fixedSize()
                    .frame(minWidth: 52, alignment: .trailing)
                    .onTapGesture(count: 2) {
                        vm.masterGainDb = 0.0
                    }

                StereoPeakMeter(peakL: vm.peakL, peakR: vm.peakR, segments: 10, barWidth: 52)
            }
        }

        ToolbarSpacer(.flexible)

        // Grupo 4 (separado): Panic
        ToolbarItem(placement: .automatic) {
            Button(role: .destructive) {
                vm.panic()
            } label: {
                Label("Panic", systemImage: "xmark.octagon")
            }
            .buttonStyle(.glass)
            .help("Silenciar imediatamente todas as vozes ativas (⌘.)")
        }

        ToolbarSpacer(.fixed)

        // Grupo 5 (separado, à direita): Configurações
        ToolbarItem(placement: .automatic) {
            SettingsLink {
                Label("Configurações", systemImage: "gearshape")
            }
            .buttonStyle(.glass)
            .help("Abrir Configurações de Áudio, MIDI, Aparência e Teclado (⌘,)")
        }
    }

    // MARK: - Popover "Renomear Programa…" (Arquivo > Renomear programa…)

    private var renameProgramPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Renomear Programa \(vm.selectedMemorySlot)")
                .font(StudioTokens.fontSectionTitle)
                .foregroundStyle(StudioTokens.textPrimary)

            TextField("Nome do programa", text: $vm.renameProgramDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    vm.commitRenameCurrentProgram()
                }

            HStack {
                Spacer()
                Button("Cancelar") {
                    vm.showRenameProgramPopover = false
                }
                .buttonStyle(.glass)

                Button("Salvar") {
                    vm.commitRenameCurrentProgram()
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(StudioTokens.grid2)
        .frame(width: 260)
    }

    // MARK: - Popover "Afinação" (A4 / Fine / Pan Master)

    private var masterTuningPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Afinação & Master")
                    .font(StudioTokens.fontSectionTitle)
                Spacer()
                Button("Restaurar Padrão") {
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

            // Referência A4 (neutralValue em 440.0 Hz)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Referência Lá (A4)")
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                    Spacer()
                    Text(String(format: "%.1f Hz", vm.baseTuningHz))
                        .font(StudioTokens.fontValue)
                }
                Slider(value: $vm.baseTuningHz, in: 432.0...446.0, step: 0.5, neutralValue: 440.0) {
                    Text("Referência A4")
                }
                .labelsHidden()
            }

            // Afinação Fina (cents, neutralValue em 0.0 ct)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Afinação Fina")
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                    Spacer()
                    Text(String(format: "%+.0f ct", vm.fineTuneCents))
                        .font(StudioTokens.fontValue)
                }
                Slider(value: $vm.fineTuneCents, in: -100.0...100.0, step: 5.0, neutralValue: 0.0) {
                    Text("Afinação Fina")
                }
                .labelsHidden()
            }

            // Pan Master (centro em 0 com neutralValue)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Balanço (Pan)")
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                    Spacer()
                    let panInt = Int(vm.masterPan.rounded())
                    Text(panInt == 0 ? "Centro" : (panInt < 0 ? "\(-panInt)% L" : "\(panInt)% R"))
                        .font(StudioTokens.fontValue)
                }
                Slider(value: $vm.masterPan, in: -100.0...100.0, step: 5.0, neutralValue: 0.0) {
                    Text("Balanço")
                }
                .labelsHidden()
            }
        }
        .padding(StudioTokens.grid2)
        .frame(width: 280)
    }

    // MARK: - 2. Faixa de Camadas (~100pt) dentro de UM único GlassEffectContainer

    private var layerStripSection: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { layer in
                    layerCardView(layer)
                }
            }
        }
        .frame(height: 100)
    }

    private func layerCardView(_ layer: Int) -> some View {
        let letter = kLayerLetters[layer]
        let slot = vm.layers[layer]
        let p = slot.params
        let isSelected = vm.selectedLayer == layer

        return VStack(alignment: .leading, spacing: 6) {
            if p.enabled {
                // Camada ligada: Switch + Ponto + Letra + Faixa de notas (11pt, >= 4.5:1) + Setas ‹ › (>= 28pt)
                HStack(spacing: 6) {
                    Toggle(
                        "Ativar Camada \(letter)",
                        isOn: Binding(
                            get: { p.enabled },
                            set: { newVal in vm.updateLayerParams(layer) { $0.enabled = newVal } }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Ligar ou desligar a Camada \(letter)")

                    Circle()
                        .fill(isSelected ? StudioTokens.accent : StudioTokens.textSecondary)
                        .frame(width: 7, height: 7)

                    Text("Camada \(letter)")
                        .font(StudioTokens.fontValueSemibold)
                        .foregroundStyle(StudioTokens.textPrimary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Text("\(shortNoteName(Int(p.keyLow)))–\(shortNoteName(Int(p.keyHigh)))")
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
                        .help("Timbre anterior na pasta")

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
                        .help("Próximo timbre na pasta")
                    }
                }
                .frame(height: 24)

                // Linha 2: Seletor de timbre (1 linha) ou barra de carregamento
                if slot.isLoading {
                    ProgressView(value: Double(slot.loadProgress), total: 1.0)
                        .frame(height: 24)
                } else {
                    TimbrePickerMenu(vm: vm, layer: layer)
                }

                // Linha 3: Volume da camada
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
                        Text("Volume")
                    }
                    .labelsHidden()
                    .controlSize(.small)

                    Text(String(format: "%.0f%%", volPercent))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(StudioTokens.textPrimary)
                        .fixedSize()
                        .frame(minWidth: 36, alignment: .trailing)
                }
                .frame(height: 18)
            } else {
                // Camada desligada: só switch + letra + nome do timbre (1 linha). Sem "Carregar timbre…", sem "Camada desligada", sem faixa de notas.
                HStack(spacing: 8) {
                    Toggle(
                        "Ativar Camada \(letter)",
                        isOn: Binding(
                            get: { p.enabled },
                            set: { newVal in vm.updateLayerParams(layer) { $0.enabled = newVal } }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Ligar ou desligar a Camada \(letter)")

                    if isSelected {
                        Circle()
                            .fill(StudioTokens.accent)
                            .frame(width: 7, height: 7)
                    }

                    Text("Camada \(letter)")
                        .font(StudioTokens.fontValueSemibold)
                        .foregroundStyle(StudioTokens.textSecondary)
                        .lineLimit(1)

                    Spacer()
                }

                Text(slot.loaded ? slot.name : "Nenhum timbre")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            if reduceMotion {
                vm.selectedLayer = layer
            } else {
                withAnimation(.easeInOut(duration: 0.15)) {
                    vm.selectedLayer = layer
                }
            }
        }
        // Regra de Ouro: .glassEffect() DEPOIS dos modificadores de layout; sem preenchimento sólido vermelho; borda 1.5pt vermelha no selecionado
        .glassEffect(
            .regular.interactive(),
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
        .accessibilityLabel("Camada \(letter), \(slot.loaded ? slot.name : "Nenhum timbre"), \(p.enabled ? "Ligada" : "Desligada")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 3. Editor Principal da Camada Selecionada (Superfícies Sólidas, Altura do Conteúdo)

    private var layerEditorSection: some View {
        let layer = vm.selectedLayer
        let letter = kLayerLetters[layer]
        let slot = vm.layers[layer]
        let p = slot.params

        return VStack(alignment: .leading, spacing: 12) {
            // Cabeçalho do Editor: "Camada A — nome do timbre" ("Nenhum timbre" quando vazio) + Abas em Picker segmented (.fixedSize())
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(StudioTokens.accent)
                        .frame(width: 8, height: 8)

                    Text("Camada \(letter) — \(slot.loaded ? slot.name : "Nenhum timbre")")
                        .font(StudioTokens.fontSectionTitle)
                        .foregroundStyle(StudioTokens.textPrimary)
                        .lineLimit(1)

                    if slot.loaded {
                        Text("\(shortNoteName(Int(p.keyLow)))–\(shortNoteName(Int(p.keyHigh))) • \(String(format: "%.0f MiB", Double(slot.decodedBytes) / 1048576.0))")
                            .font(StudioTokens.fontLabel.monospacedDigit())
                            .foregroundStyle(StudioTokens.textSecondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(StudioTokens.surfacePanel, in: .capsule)
                            .overlay(Capsule().stroke(StudioTokens.borderHairline, lineWidth: 1))
                    }
                }

                Spacer(minLength: 8)

                Picker("Seção do Editor", selection: $vm.selectedTab) {
                    ForEach(WorkstationTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 2)

            // Só o editor rola, e só na vertical; painéis alinhados ao topo com altura do conteúdo
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    switch vm.selectedTab {
                    case .timbre:
                        timbreTabContent(layer: layer)
                    case .keyboard:
                        keyboardTabContent(layer: layer)
                    case .midiCC:
                        midiCCTabContent(layer: layer)
                    case .eqMod:
                        eqModTabContent
                    case .delayReverb:
                        delayReverbTabContent
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // Helper para Binding de parâmetros da camada
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

    // MARK: - Helper de Layout Responsivo: 3 Colunas quando couber, senão 2 + 1 abaixo

    @ViewBuilder
    private func responsiveThreePanelLayout<P1: View, P2: View, P3: View>(
        p1Priority: Double = 1.2,
        p2Priority: Double = 1.0,
        p3Priority: Double = 1.0,
        @ViewBuilder panel1: () -> P1,
        @ViewBuilder panel2: () -> P2,
        @ViewBuilder panel3: () -> P3
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                panel1()
                    .frame(maxWidth: .infinity)
                    .layoutPriority(p1Priority)
                panel2()
                    .frame(maxWidth: .infinity)
                    .layoutPriority(p2Priority)
                panel3()
                    .frame(maxWidth: .infinity)
                    .layoutPriority(p3Priority)
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    panel1()
                        .frame(maxWidth: .infinity)
                    panel2()
                        .frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)

                panel3()
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Aba 1: Timbre (Perfil & Filtro · Compressor · Envelope)

    private func timbreTabContent(layer: Int) -> some View {
        let lp = vm.layers[layer].params

        // Estado combinado do compressor: 0 = Desligado, 1 = Normal, 2 = Rápido
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
            (2, "Suave"),
            (0, "Neutro"),
            (1, "Brilhante"),
            (3, "Dyno 1"),
            (4, "Dyno 2")
        ]

        return responsiveThreePanelLayout(
            p1Priority: 1.25,
            p2Priority: 0.85,
            p3Priority: 1.10,
            panel1: {
                // Painel 1: Perfil & Filtro (Knobs centralizados em 56pt; sem "Camada A" repetido)
                SectionCard(title: "Perfil & Filtro") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Text("Caráter tonal")
                                .font(StudioTokens.fontLabel)
                                .foregroundStyle(StudioTokens.textSecondary)

                            Spacer()

                            // Como há 5 modos tonais (acima do limite de 4 para segmented), usamos pílulas compactas
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
                                "Pedal Sustain",
                                isOn: layerBinding(layer, { $0.sustainPedalOn }, { $0.sustainPedalOn = $1 })
                            )
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(StudioTokens.fontBody)
                            .help("Permitir que o pedal de sustain sustente as notas desta camada")

                            Toggle(
                                "Ressonância",
                                isOn: layerBinding(layer, { $0.undampedOn }, { $0.undampedOn = $1 })
                            )
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(StudioTokens.fontBody)
                            .help("Ressonância simpatética das cordas agudas sem abafador")

                            Spacer(minLength: 4)

                            Stepper(
                                value: layerBinding(layer, { Int($0.octaveShift) }, { $0.octaveShift = Int32($1) }),
                                in: -3...3
                            ) {
                                let oct = Int(lp.octaveShift)
                                Text("Oitava: \(oct == 0 ? "0" : String(format: "%+d", oct))")
                                    .font(StudioTokens.fontValue)
                                    .fixedSize()
                            }
                            .help("Transposição de oitava da camada (-3 a +3)")
                        }

                        Divider().overlay(StudioTokens.borderHairline)

                        // Knobs do painel Perfil: centralizados, 56pt
                        HStack(spacing: 18) {
                            Spacer(minLength: 0)

                            ProKnob(
                                idKey: "L\(layer)_flt",
                                title: "Filtro",
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
                                title: "Ambiência",
                                value: layerBinding(layer, { Double($0.fxaAmount) * 100.0 }, { $0.fxaAmount = Float($1 / 100.0) }),
                                range: 0.0...100.0,
                                defaultValue: 20.0,
                                valueFormatter: { String(format: "%.0f%%", $0) },
                                size: 56
                            )

                            ProKnob(
                                idKey: "L\(layer)_fxrt",
                                title: "Cauda",
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
                // Painel 2: Compressor (Segmented Desligado/Normal/Rápido neutro + knob Intensidade)
                SectionCard(title: "Compressor") {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Modo de resposta")
                                .font(StudioTokens.fontLabel)
                                .foregroundStyle(StudioTokens.textSecondary)

                            Picker("Modo do Compressor", selection: compModeBinding) {
                                Text("Desligado").tag(0)
                                Text("Normal").tag(1)
                                Text("Rápido").tag(2)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        Divider().overlay(StudioTokens.borderHairline)

                        HStack {
                            Spacer()
                            ProKnob(
                                idKey: "L\(layer)_comp",
                                title: "Intensidade",
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
                // Painel 3: Envelope (Ataque/Soltura desabilitados em cinza com envelope original ligado)
                SectionCard(title: "Envelope") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(
                            "Usar envelope original da amostra",
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
                                title: "Ataque",
                                value: layerBinding(layer, { Double($0.attackMs) }, { $0.attackMs = Float($1) }),
                                range: 0.5...1500.0,
                                defaultValue: 1.0,
                                valueFormatter: { $0 < 10 ? String(format: "%.1f ms", $0) : String(format: "%.0f ms", $0) },
                                size: 48,
                                enabled: !lp.originalEnvelope
                            )

                            ProKnob(
                                idKey: "L\(layer)_rel",
                                title: "Soltura",
                                value: layerBinding(layer, { Double($0.releaseMs) }, { $0.releaseMs = Float($1) }),
                                range: 30.0...4000.0,
                                defaultValue: 600.0,
                                valueFormatter: { String(format: "%.0f ms", $0) },
                                size: 48,
                                enabled: !lp.originalEnvelope
                            )

                            ProKnob(
                                idKey: "global_relnoise",
                                title: "Ruído soltura",
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

    // MARK: - Aba 2: Teclado & Toque (Sensibilidade · Zona do teclado / Dinâmica · Articulação)

    private func keyboardTabContent(layer: Int) -> some View {
        let lp = vm.layers[layer].params
        let globalIdx = Int(vm.globalVelocityCurve.rounded())

        return responsiveThreePanelLayout(
            p1Priority: 1.05,
            p2Priority: 1.15,
            p3Priority: 0.95,
            panel1: {
                // Painel 1: Sensibilidade (Grade 3x2 de miniaturas da curva + Segmented 3 itens de sensibilidade global)
                SectionCard(title: "Sensibilidade") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Curva de velocidade")
                            .font(StudioTokens.fontLabel)
                            .foregroundStyle(StudioTokens.textSecondary)

                        VelocityCurveThumbnailGrid(
                            selectedCurve: layerBinding(layer, { Int($0.velocityCurve) }, { $0.velocityCurve = Int32($1) }),
                            globalCurve: globalIdx
                        )

                        Divider().overlay(StudioTokens.borderHairline)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Sensibilidade global")
                                .font(StudioTokens.fontLabel)
                                .foregroundStyle(StudioTokens.textSecondary)

                            Picker("Sensibilidade global", selection: Binding(
                                get: { Int(vm.globalVelocityCurve.rounded()) },
                                set: { vm.globalVelocityCurve = Double($0) }
                            )) {
                                Text("Leve").tag(-1)
                                Text("Normal").tag(0)
                                Text("Pesada").tag(1)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }
                }
            },
            panel2: {
                // Painel 2: Dividido em dois blocos ("Zona do teclado" e "Dinâmica") no mesmo painel + "Restaurar Zona" (.glass neutro)
                SectionCard(
                    title: "Zona do teclado",
                    headerTrailing: {
                        Button("Restaurar Zona") {
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
                        // Bloco 1: Zona do teclado (range slider sobre mini-teclado)
                        KeyZoneRangeControl(
                            keyLow: layerBinding(layer, { Int($0.keyLow) }, { $0.keyLow = Int32($1) }),
                            keyHigh: layerBinding(layer, { Int($0.keyHigh) }, { $0.keyHigh = Int32($1) }),
                            layerIndex: layer
                        )

                        Divider().overlay(StudioTokens.borderHairline)

                        // Bloco 2: Dinâmica (faixa de velocity + canal MIDI)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Dinâmica")
                                .font(StudioTokens.fontSectionTitle)
                                .foregroundStyle(StudioTokens.textPrimary)

                            DualRangeSlider(
                                title: "Faixa de velocity",
                                lowValue: layerBinding(layer, { Int($0.velLow) }, { $0.velLow = Int32($1) }),
                                highValue: layerBinding(layer, { Int($0.velHigh) }, { $0.velHigh = Int32($1) }),
                                bounds: 1...127,
                                valueFormatter: { "\($0)" }
                            )

                            HStack {
                                Text("Canal MIDI")
                                    .font(StudioTokens.fontLabel)
                                    .foregroundStyle(StudioTokens.textSecondary)
                                Spacer()
                                Picker("Canal MIDI", selection: layerBinding(layer, { Int($0.midiChannel) }, { $0.midiChannel = Int32($1) })) {
                                    Text("Global / Omni").tag(0)
                                    ForEach(1...16, id: \.self) { ch in
                                        Text("Canal \(ch)").tag(ch)
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
                // Painel 3: Articulação
                SectionCard(title: "Articulação") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Spacer(minLength: 0)

                            ProKnob(
                                idKey: "L\(layer)_plo",
                                title: "Bend ↓",
                                value: layerBinding(layer, { Double($0.pitchBendDown) }, { $0.pitchBendDown = Int32($1.rounded()) }),
                                range: -24.0...0.0,
                                defaultValue: -2.0,
                                step: 1.0,
                                valueFormatter: { String(format: "%d st", Int($0.rounded())) },
                                size: 36
                            )

                            ProKnob(
                                idKey: "L\(layer)_phi",
                                title: "Bend ↑",
                                value: layerBinding(layer, { Double($0.pitchBendUp) }, { $0.pitchBendUp = Int32($1.rounded()) }),
                                range: 0.0...24.0,
                                defaultValue: 2.0,
                                step: 1.0,
                                valueFormatter: { String(format: "+%d st", Int($0.rounded())) },
                                size: 36
                            )

                            ProKnob(
                                idKey: "L\(layer)_port",
                                title: "Portamento",
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
                            Toggle("Portamento", isOn: layerBinding(layer, { $0.portamentoOn }, { $0.portamentoOn = $1 }))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .font(StudioTokens.fontBody)

                            Toggle("Legato mono", isOn: layerBinding(layer, { $0.legatoMono }, { $0.legatoMono = $1 }))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .font(StudioTokens.fontBody)
                        }

                        HStack(spacing: 10) {
                            Toggle("Velocity fixa", isOn: layerBinding(layer, { $0.fixedVelocity }, { $0.fixedVelocity = $1 }))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .font(StudioTokens.fontBody)

                            Spacer(minLength: 4)

                            Stepper(
                                value: layerBinding(layer, { Int($0.fixedVelocityValue) }, { $0.fixedVelocityValue = Int32($1) }),
                                in: 1...127,
                                step: 1
                            ) {
                                Text("Valor: \(lp.fixedVelocityValue)")
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

    // MARK: - Aba 3: MIDI CC (Tabela Parâmetro | CC | Learn + Mapeamentos dos Knobs)

    private func midiCCTabContent(layer: Int) -> some View {
        let lp = vm.layers[layer].params
        let mappings = vm.knobMidiMappings.sorted { $0.key < $1.key }

        return HStack(alignment: .top, spacing: 12) {
            // Coluna 1: Tabela de CC da Camada (Parâmetro | CC | Learn)
            SectionCard(title: "Controles MIDI da camada") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Parâmetro")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("CC")
                            .frame(width: 130, alignment: .leading)
                        Text("Learn")
                            .frame(width: 96, alignment: .trailing)
                    }
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(StudioTokens.textSecondary)
                    .padding(.horizontal, 8)

                    Divider().overlay(StudioTokens.borderHairline)

                    layerCCRow(
                        layer: layer,
                        slot: 0,
                        parameterName: "Volume da camada",
                        ccValue: Int(lp.ccVolume)
                    ) { newCC in
                        vm.updateLayerParams(layer) { $0.ccVolume = Int32(newCC) }
                    }

                    layerCCRow(
                        layer: layer,
                        slot: 1,
                        parameterName: "Filtro passa-baixas",
                        ccValue: Int(lp.ccFilter)
                    ) { newCC in
                        vm.updateLayerParams(layer) { $0.ccFilter = Int32(newCC) }
                    }

                    layerCCRow(
                        layer: layer,
                        slot: 2,
                        parameterName: "Ambiência",
                        ccValue: Int(lp.ccFxaAmount)
                    ) { newCC in
                        vm.updateLayerParams(layer) { $0.ccFxaAmount = Int32(newCC) }
                    }

                    layerCCRow(
                        layer: layer,
                        slot: 3,
                        parameterName: "Cauda de ambiência",
                        ccValue: Int(lp.ccFxaRelease)
                    ) { newCC in
                        vm.updateLayerParams(layer) { $0.ccFxaRelease = Int32(newCC) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(1.0)

            // Coluna 2: Tabela de Mapeamentos dos Knobs
            SectionCard(
                title: "Mapeamentos MIDI dos knobs",
                subtitle: "\(mappings.count) ativo(s)",
                headerTrailing: {
                    if let activeKey = vm.activeMidiLearnKey {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(StudioTokens.accent)
                                .frame(width: 8, height: 8)
                            Text("Aguardando CC para \(friendlyKnobName(activeKey))…")
                                .font(StudioTokens.fontLabel)
                                .foregroundStyle(StudioTokens.textPrimary)
                                .lineLimit(1)
                            Button("Cancelar") {
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
                            Text("Nenhum knob mapeado")
                                .font(StudioTokens.fontBodyMedium)
                                .foregroundStyle(StudioTokens.textPrimary)
                            Text("Clique com o botão direito em qualquer knob e escolha \"Aprender MIDI CC\", depois mova um controle físico no seu teclado MIDI.")
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
                            Text("Parâmetro")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("CC")
                                .frame(width: 72, alignment: .leading)
                            Text("Remover")
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

                                    Text("CC \(item.value)")
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
                                    .help("Remover mapeamento de \(friendlyKnobName(item.key))")
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
            .frame(maxWidth: .infinity)
            .layoutPriority(1.0)
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

            Picker("CC", selection: Binding(
                get: { ccValue },
                set: { onSelect($0) }
            )) {
                Text("Desligado").tag(-1)
                Divider()
                ForEach(commonCCs, id: \.self) { c in
                    Text("CC \(c)").tag(c)
                }
                if ccValue >= 0 && !commonCCs.contains(ccValue) {
                    Text("CC \(ccValue)").tag(ccValue)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Button {
                vm.toggleMidiLearn(layer: layer, slot: slot)
            } label: {
                Text(isLearning ? "Aguardando…" : "Learn")
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

    // MARK: - Aba 4: EQ · Drive · Mod (EQ com Curva Visual + Mod 1 e Mod 2 Idênticos)

    private var eqModTabContent: some View {
        responsiveThreePanelLayout(
            p1Priority: 1.35,
            p2Priority: 0.9,
            p3Priority: 0.9,
            panel1: {
                // Card 1: Equalizador 3 Bandas (com gráfico de resposta) + Drive
                SectionCard(
                    title: "Equalizador & Drive",
                    headerTrailing: {
                        Button("Flat (0 dB)") {
                            vm.resetEq()
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                ) {
                    VStack(spacing: 14) {
                        HStack(spacing: 14) {
                            EQResponseGraph(
                                bassDb: vm.eqBassDb,
                                midDb: vm.eqMidDb,
                                midFreqHz: vm.eqMidFreqHz,
                                trebleDb: vm.eqTrebleDb
                            )
                            .frame(minWidth: 140, maxWidth: .infinity)
                            .frame(height: 82)

                            Divider().overlay(StudioTokens.borderHairline)

                            HStack(spacing: 10) {
                                Toggle("Drive", isOn: $vm.driveEnabled)
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .font(StudioTokens.fontBodyMedium)
                                    .fixedSize()

                                ProKnob(
                                    idKey: "eq_drive",
                                    title: "Saturação",
                                    value: $vm.driveAmountPercent,
                                    range: 0.0...100.0,
                                    defaultValue: 25.0,
                                    valueFormatter: { String(format: "%.0f%%", $0) },
                                    size: 36,
                                    enabled: vm.driveEnabled
                                )
                            }
                        }

                        HStack(spacing: 8) {
                            Spacer(minLength: 0)

                            ProKnob(
                                idKey: "eq_bass",
                                title: "Graves",
                                value: $vm.eqBassDb,
                                range: -15.0...15.0,
                                defaultValue: 0.0,
                                valueFormatter: { String(format: "%+.1f dB", $0) },
                                size: 48
                            )

                            ProKnob(
                                idKey: "eq_mid",
                                title: "Médios",
                                value: $vm.eqMidDb,
                                range: -15.0...15.0,
                                defaultValue: 0.0,
                                valueFormatter: { String(format: "%+.1f dB", $0) },
                                size: 48
                            )

                            ProKnob(
                                idKey: "eq_midf",
                                title: "Freq. médios",
                                value: $vm.eqMidFreqHz,
                                range: 200.0...5000.0,
                                defaultValue: 1000.0,
                                valueFormatter: {
                                    $0 >= 1000.0
                                        ? String(format: "%.1f kHz", $0 / 1000.0)
                                        : String(format: "%.0f Hz", $0)
                                },
                                size: 48
                            )

                            ProKnob(
                                idKey: "eq_treb",
                                title: "Agudos",
                                value: $vm.eqTrebleDb,
                                range: -15.0...15.0,
                                defaultValue: 0.0,
                                valueFormatter: { String(format: "%+.1f dB", $0) },
                                size: 48
                            )

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            },
            panel2: {
                modulatorCard(title: "Mod 1", index: 1, mod: $vm.mod1)
            },
            panel3: {
                modulatorCard(title: "Mod 2", index: 2, mod: $vm.mod2)
            }
        )
    }

    private func modulatorCard(title: String, index: Int, mod: Binding<NPNOModulatorParams>) -> some View {
        let m = mod.wrappedValue
        return SectionCard(
            title: title,
            headerTrailing: {
                Toggle("Ativar \(title)", isOn: Binding(
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
                    Text("Destino")
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                    Spacer()
                    Picker("Destino", selection: Binding(
                        get: { Int(mod.wrappedValue.target) },
                        set: { mod.wrappedValue.target = Int32($0) }
                    )) {
                        Text("Tremolo").tag(0)
                        Text("Wah (Filtro)").tag(1)
                        Text("Vibrato").tag(2)
                        Text("Auto-Pan").tag(3)
                    }
                    .labelsHidden()
                    .frame(width: 145)
                    .disabled(!m.enabled)
                }

                HStack {
                    Text("Onda")
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                    Spacer()
                    Picker("Forma de onda", selection: Binding(
                        get: { Int(mod.wrappedValue.wave) },
                        set: { mod.wrappedValue.wave = Int32($0) }
                    )) {
                        Text("Seno").tag(0)
                        Text("Triângulo").tag(1)
                        Text("Serra").tag(2)
                        Text("Quadrada").tag(3)
                        Text("Envelope").tag(4)
                    }
                    .labelsHidden()
                    .frame(width: 145)
                    .disabled(!m.enabled)
                }

                Divider().overlay(StudioTokens.borderHairline)

                HStack(spacing: 14) {
                    Spacer(minLength: 0)

                    ProKnob(
                        idKey: "mod\(index)_rate",
                        title: "Velocidade",
                        value: Binding(
                            get: { Double(mod.wrappedValue.rateHz) },
                            set: { mod.wrappedValue.rateHz = Float($0) }
                        ),
                        range: 0.1...20.0,
                        defaultValue: index == 1 ? 4.5 : 5.5,
                        valueFormatter: { String(format: "%.1f Hz", $0) },
                        size: 48,
                        enabled: m.enabled
                    )

                    ProKnob(
                        idKey: "mod\(index)_depth",
                        title: "Profundidade",
                        value: Binding(
                            get: { Double(mod.wrappedValue.depth) * 100.0 },
                            set: { mod.wrappedValue.depth = Float($0 / 100.0) }
                        ),
                        range: 0.0...100.0,
                        defaultValue: index == 1 ? 35.0 : 20.0,
                        valueFormatter: { String(format: "%.0f%%", $0) },
                        size: 48,
                        enabled: m.enabled
                    )

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Aba 5: Delay · Reverb (Mesma Gramática Visual, Painéis Dimensionados ao Conteúdo)

    private var delayReverbTabContent: some View {
        let divisions = ["1/4", "1/8", "1/8 Pont.", "1/8 Terc.", "1/16"]

        return HStack(alignment: .top, spacing: 12) {
            // Card 1: Delay Estéreo
            SectionCard(
                title: "Delay Estéreo",
                headerTrailing: {
                    HStack(spacing: 10) {
                        Button {
                            vm.tapDelayTempo()
                        } label: {
                            Label("Tap Tempo", systemImage: "hand.tap")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)

                        Toggle("Ativar Delay", isOn: $vm.delay.enabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 20) {
                        Toggle("Ping-Pong estéreo", isOn: $vm.delay.pingPong)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(StudioTokens.fontBody)
                            .disabled(!vm.delay.enabled)

                        Toggle("Sincronizar ao BPM", isOn: $vm.delay.syncToHost)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(StudioTokens.fontBody)
                            .disabled(!vm.delay.enabled)
                    }

                    Divider().overlay(StudioTokens.borderHairline)

                    HStack(spacing: 14) {
                        Spacer(minLength: 0)

                        ProKnob(
                            idKey: "dly_amt",
                            title: "Mix",
                            value: Binding(
                                get: { Double(vm.delay.amount) * 100.0 },
                                set: { vm.delay.amount = Float($0 / 100.0) }
                            ),
                            range: 0.0...100.0,
                            defaultValue: 25.0,
                            valueFormatter: { String(format: "%.0f%%", $0) },
                            size: 48,
                            enabled: vm.delay.enabled
                        )

                        ProKnob(
                            idKey: "dly_fb",
                            title: "Feedback",
                            value: Binding(
                                get: { Double(vm.delay.feedback) * 100.0 },
                                set: { vm.delay.feedback = Float($0 / 100.0) }
                            ),
                            range: 0.0...92.0,
                            defaultValue: 35.0,
                            valueFormatter: { String(format: "%.0f%%", $0) },
                            size: 48,
                            enabled: vm.delay.enabled
                        )

                        if vm.delay.syncToHost {
                            ProKnob(
                                idKey: "dly_div",
                                title: "Divisão",
                                value: Binding(
                                    get: { Double(vm.delay.syncDivision) },
                                    set: { vm.delay.syncDivision = Int32($0.rounded()) }
                                ),
                                range: 0.0...4.0,
                                defaultValue: 1.0,
                                step: 1.0,
                                valueFormatter: { divisions[min(max(Int($0.rounded()), 0), 4)] },
                                size: 48,
                                enabled: vm.delay.enabled
                            )

                            ProKnob(
                                idKey: "dly_bpm",
                                title: "BPM",
                                value: Binding(
                                    get: { Double(vm.delay.hostBpm) },
                                    set: { vm.delay.hostBpm = Float($0.rounded()) }
                                ),
                                range: 40.0...240.0,
                                defaultValue: 120.0,
                                step: 1.0,
                                valueFormatter: { String(format: "%.0f BPM", $0) },
                                size: 48,
                                enabled: vm.delay.enabled
                            )
                        } else {
                            ProKnob(
                                idKey: "dly_time",
                                title: "Tempo",
                                value: Binding(
                                    get: { Double(vm.delay.timeMs) },
                                    set: { vm.delay.timeMs = Float($0) }
                                ),
                                range: 20.0...2000.0,
                                defaultValue: 360.0,
                                valueFormatter: { String(format: "%.0f ms", $0) },
                                size: 48,
                                enabled: vm.delay.enabled
                            )
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(1.0)

            // Card 2: Reverb Estéreo
            SectionCard(
                title: "Reverb Estéreo",
                headerTrailing: {
                    Toggle("Ativar Reverb", isOn: $vm.reverb.enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Reverberação algorítmica com controle de sala, decaimento e absorção de agudos.")
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(StudioTokens.textSecondary)
                        .lineLimit(1)

                    Divider().overlay(StudioTokens.borderHairline)

                    HStack(spacing: 8) {
                        Spacer(minLength: 0)

                        ProKnob(
                            idKey: "rev_amt",
                            title: "Mix",
                            value: Binding(
                                get: { Double(vm.reverb.amount) * 100.0 },
                                set: { vm.reverb.amount = Float($0 / 100.0) }
                            ),
                            range: 0.0...100.0,
                            defaultValue: 22.0,
                            valueFormatter: { String(format: "%.0f%%", $0) },
                            size: 48,
                            enabled: vm.reverb.enabled
                        )

                        ProKnob(
                            idKey: "rev_size",
                            title: "Tamanho",
                            value: Binding(
                                get: { Double(vm.reverb.size) * 100.0 },
                                set: { vm.reverb.size = Float($0 / 100.0) }
                            ),
                            range: 10.0...100.0,
                            defaultValue: 65.0,
                            valueFormatter: { String(format: "%.0f%%", $0) },
                            size: 48,
                            enabled: vm.reverb.enabled
                        )

                        ProKnob(
                            idKey: "rev_dec",
                            title: "Decaimento",
                            value: Binding(
                                get: { Double(vm.reverb.decay) * 100.0 },
                                set: { vm.reverb.decay = Float($0 / 100.0) }
                            ),
                            range: 10.0...100.0,
                            defaultValue: 55.0,
                            valueFormatter: { String(format: "%.0f%%", $0) },
                            size: 48,
                            enabled: vm.reverb.enabled
                        )

                        ProKnob(
                            idKey: "rev_damp",
                            title: "Absorção",
                            value: Binding(
                                get: { Double(vm.reverb.damping) * 100.0 },
                                set: { vm.reverb.damping = Float($0 / 100.0) }
                            ),
                            range: 0.0...100.0,
                            defaultValue: 45.0,
                            valueFormatter: { String(format: "%.0f%%", $0) },
                            size: 48,
                            enabled: vm.reverb.enabled
                        )

                        ProKnob(
                            idKey: "rev_predly",
                            title: "Pré-Delay",
                            value: Binding(
                                get: { Double(vm.reverb.preDelayMs) },
                                set: { vm.reverb.preDelayMs = Float($0) }
                            ),
                            range: 0.0...120.0,
                            defaultValue: 18.0,
                            valueFormatter: { String(format: "%.0f ms", $0) },
                            size: 48,
                            enabled: vm.reverb.enabled
                        )

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(1.15)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 4. Barra de Status Inferior (safeAreaInset, Material Leve, Não Glass)

    private var statusBarSection: some View {
        HStack(spacing: 14) {
            // Pedal Sustain
            Button {
                vm.setSustain(!vm.sustainDown)
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(vm.sustainDown ? StudioTokens.meterGreen : StudioTokens.textDisabled)
                        .frame(width: 7, height: 7)
                    Text("Sustain")
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(vm.sustainDown ? StudioTokens.textPrimary : StudioTokens.textSecondary)
                }
            }
            .buttonStyle(.plain)
            .help("Estado do pedal Sustain (Espaço para acionar)")

            Divider().frame(height: 14)

            // Dispositivo MIDI (truncado + tooltip completo)
            HStack(spacing: 6) {
                Circle()
                    .fill(vm.midiSourceCount > 0 ? StudioTokens.meterGreen : StudioTokens.textDisabled)
                    .frame(width: 7, height: 7)

                Text("MIDI: \(vm.midiSources)")
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(StudioTokens.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 240, alignment: .leading)
            }
            .help("Controladores MIDI: \(vm.midiSources)")

            if let err = vm.errorMessage {
                Divider().frame(height: 14)
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(StudioTokens.meterYellow)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            // Sample Rate
            Text(String(format: "%.1f kHz", vm.sampleRate / 1000.0))
                .font(StudioTokens.fontLabel.monospacedDigit())
                .foregroundStyle(StudioTokens.textSecondary)
                .help("Taxa de amostragem ativa do motor CoreAudio")

            Divider().frame(height: 14)

            // Vozes ativas / limite
            Menu {
                ForEach([64, 128, 256, 512], id: \.self) { limit in
                    Button {
                        vm.maxVoices = limit
                    } label: {
                        if vm.maxVoices == limit {
                            Label("Polifonia máxima: \(limit) vozes", systemImage: "checkmark")
                        } else {
                            Text("Polifonia máxima: \(limit) vozes")
                        }
                    }
                }
            } label: {
                Text("Vozes: \(vm.activeVoices)/\(vm.maxVoices)")
                    .font(StudioTokens.fontLabel.monospacedDigit())
                    .foregroundStyle(vm.activeVoices > 0 ? StudioTokens.textPrimary : StudioTokens.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Vozes polifônicas ativas / clique para alterar o limite de polifonia")

            Divider().frame(height: 14)

            // Memória RAM + Purge / Reload
            HStack(spacing: 8) {
                Text(String(
                    format: "RAM: %.0f / %.0f MiB",
                    Double(vm.totalMemoryBytes) / 1048576.0,
                    Double(vm.totalUnpurgedBytes) / 1048576.0
                ))
                .font(StudioTokens.fontLabel.monospacedDigit())
                .foregroundStyle(StudioTokens.textSecondary)

                if vm.totalMemoryBytes < vm.totalUnpurgedBytes {
                    Button("Recarregar") {
                        vm.reloadPurgedMemory()
                    }
                    .buttonStyle(.plain)
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(StudioTokens.textPrimary)
                    .help("Recarregar samples purgados na memória RAM")
                } else {
                    Button("Purge") {
                        vm.purgeUnusedMemory()
                    }
                    .buttonStyle(.plain)
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(StudioTokens.textPrimary)
                    .help("Liberar samples não tocados da memória RAM (⇧⌘P)")
                }
            }

            Divider().frame(height: 14)

            if abs(vm.uiScale - 1.0) > 0.01 {
                Button {
                    vm.uiScale = 1.0
                } label: {
                    Text("Zoom: \(Int((vm.uiScale * 100).rounded()))%")
                        .font(StudioTokens.fontLabel.monospacedDigit())
                        .foregroundStyle(StudioTokens.textPrimary)
                }
                .buttonStyle(.plain)
                .help("Clique para restaurar o zoom em 100% (⌘0)")

                Divider().frame(height: 14)
            }

            // Toggle Teclado 61 teclas (Cmd+K)
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    vm.showVirtualKeyboard.toggle()
                }
            } label: {
                Label("Teclado", systemImage: "pianokeys")
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(vm.showVirtualKeyboard ? StudioTokens.textPrimary : StudioTokens.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Mostrar ou recolher teclado virtual de 61 teclas (⌘K)")
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

// MARK: - Teclado Virtual de 61 Teclas na Base (~120pt, C1 = 24 até C6 = 84) com Zonas das Camadas

struct VirtualKeyboard61View: View {
    @ObservedObject var vm: PianoViewModel
    @State private var mouseHeldNote: Int? = nil

    private let startNote: Int = 24 // C1
    private let endNote: Int = 84   // C6 (61 teclas)

    private func isBlackKey(_ note: Int) -> Bool {
        let pc = note % 12
        return pc == 1 || pc == 3 || pc == 6 || pc == 8 || pc == 10
    }

    private var whiteNotes: [Int] {
        (startNote...endNote).filter { !isBlackKey($0) }
    }

    var body: some View {
        VStack(spacing: 4) {
            // Faixas de zonas das camadas ligadas (A, B, C, D)
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

            // Teclado de 61 teclas em Canvas + interação por mouse e MIDI
            GeometryReader { geo in
                let whites = whiteNotes
                let whiteW = max(1.0, geo.size.width / CGFloat(whites.count))
                let h = geo.size.height

                Canvas { context, size in
                    // 1. Teclas brancas
                    for (idx, note) in whites.enumerated() {
                        let x = CGFloat(idx) * whiteW
                        let rect = CGRect(x: x + 0.5, y: 0, width: whiteW - 1.0, height: size.height)
                        let active = vm.keyVelocities[note] > 0 || mouseHeldNote == note
                        let fill = active ? StudioTokens.accent : StudioTokens.textPrimary.opacity(0.92)
                        context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(fill))

                        if note % 12 == 0 {
                            let label = Text(shortNoteName(note))
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundColor(active ? .white : Color.black.opacity(0.68))
                            context.draw(label, at: CGPoint(x: x + whiteW / 2, y: size.height - 10))
                        }
                    }

                    // 2. Teclas pretas
                    let blackW = whiteW * 0.62
                    let blackH = size.height * 0.60
                    for (idx, wNote) in whites.enumerated() {
                        let nextNote = wNote + 1
                        if nextNote <= endNote && isBlackKey(nextNote) {
                            let x = CGFloat(idx + 1) * whiteW - (blackW / 2.0)
                            let rect = CGRect(x: x, y: 0, width: blackW, height: blackH)
                            let active = vm.keyVelocities[nextNote] > 0 || mouseHeldNote == nextNote
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

// MARK: - Previews das 5 Abas nas Larguras 1100, 1280 e 1440

@MainActor
private func makePreviewViewModel(tab: WorkstationTab) -> PianoViewModel {
    let vm = PianoViewModel()
    vm.selectedTab = tab
    return vm
}

#Preview("Aba 1: Timbre — 1100pt") {
    ContentView(vm: makePreviewViewModel(tab: .timbre))
        .frame(width: 1100, height: 720)
}

#Preview("Aba 1: Timbre — 1280pt") {
    ContentView(vm: makePreviewViewModel(tab: .timbre))
        .frame(width: 1280, height: 760)
}

#Preview("Aba 1: Timbre — 1440pt") {
    ContentView(vm: makePreviewViewModel(tab: .timbre))
        .frame(width: 1440, height: 820)
}

#Preview("Aba 2: Teclado & Toque — 1100pt") {
    ContentView(vm: makePreviewViewModel(tab: .keyboard))
        .frame(width: 1100, height: 720)
}

#Preview("Aba 2: Teclado & Toque — 1280pt") {
    ContentView(vm: makePreviewViewModel(tab: .keyboard))
        .frame(width: 1280, height: 760)
}

#Preview("Aba 2: Teclado & Toque — 1440pt") {
    ContentView(vm: makePreviewViewModel(tab: .keyboard))
        .frame(width: 1440, height: 820)
}

#Preview("Aba 3: MIDI CC — 1100pt") {
    ContentView(vm: makePreviewViewModel(tab: .midiCC))
        .frame(width: 1100, height: 720)
}

#Preview("Aba 3: MIDI CC — 1280pt") {
    ContentView(vm: makePreviewViewModel(tab: .midiCC))
        .frame(width: 1280, height: 760)
}

#Preview("Aba 3: MIDI CC — 1440pt") {
    ContentView(vm: makePreviewViewModel(tab: .midiCC))
        .frame(width: 1440, height: 820)
}

#Preview("Aba 4: EQ · Drive · Mod — 1100pt") {
    ContentView(vm: makePreviewViewModel(tab: .eqMod))
        .frame(width: 1100, height: 720)
}

#Preview("Aba 4: EQ · Drive · Mod — 1280pt") {
    ContentView(vm: makePreviewViewModel(tab: .eqMod))
        .frame(width: 1280, height: 760)
}

#Preview("Aba 4: EQ · Drive · Mod — 1440pt") {
    ContentView(vm: makePreviewViewModel(tab: .eqMod))
        .frame(width: 1440, height: 820)
}

#Preview("Aba 5: Delay · Reverb — 1100pt") {
    ContentView(vm: makePreviewViewModel(tab: .delayReverb))
        .frame(width: 1100, height: 720)
}

#Preview("Aba 5: Delay · Reverb — 1280pt") {
    ContentView(vm: makePreviewViewModel(tab: .delayReverb))
        .frame(width: 1280, height: 760)
}

#Preview("Aba 5: Delay · Reverb — 1440pt") {
    ContentView(vm: makePreviewViewModel(tab: .delayReverb))
        .frame(width: 1440, height: 820)
}
