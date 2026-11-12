import AppKit
import Foundation
import NPNOBridge
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Modelos Auxiliares de Áudio, MIDI e Camadas

struct AudioOutputDeviceItem: Identifiable, Hashable {
    let id: UInt32
    let name: String
}

struct MidiInputDeviceItem: Identifiable, Hashable {
    let id: Int
    let name: String
    var enabled: Bool
}

struct EmbeddedBankItem: Identifiable, Hashable {
    var id: String { path }
    let index: Int
    let name: String
    let path: String
    var displayName: String {
        let pad = index < 10 ? "0\(index)" : "\(index)"
        return "\(pad). \(name)"
    }
}

struct LayerSlotState {
    var loaded: Bool = false
    var isLoading: Bool = false
    var loadProgress: Float = 0.0
    var name: String = "Slot Vazio"
    var model: String = "Carregue um .npno"
    var path: String = ""
    var summary: String = ""
    var decodedBytes: UInt64 = 0
    var totalDecodedBytes: UInt64 = 0
    var residentSamples: Int = 0
    var totalSamples: Int = 0
    var bankIndex: Int = 0
    var bankCount: Int = 0
    var activeVoices: Int = 0
    var params: NPNOLayerParams = {
        var p = NPNOLayerParams()
        p.enabled = false
        p.volume = 1.0
        p.filter = 1.0
        p.fxaAmount = 0.20
        p.fxaRelease = 0.50
        p.ccVolume = -1
        p.ccFilter = -1
        p.ccFxaAmount = -1
        p.ccFxaRelease = -1
        p.keyLow = 0
        p.keyHigh = 127
        p.velLow = 1
        p.velHigh = 127
        p.midiChannel = 0
        p.velocityCurve = 0
        p.pitchBendDown = -2
        p.pitchBendUp = 2
        p.portamentoOn = false
        p.portamentoTimeMs = 120.0
        p.fixedVelocity = false
        p.fixedVelocityValue = 100
        p.legatoMono = false
        p.timbreMode = 0
        p.sustainPedalOn = true
        p.undampedOn = true
        p.compOn = false
        p.compAmount = 0.45
        p.compFast = false
        p.octaveShift = 0
        p.originalEnvelope = true
        p.attackMs = 1.0
        p.releaseMs = 600.0
        return p
    }()
}

// MARK: - Modelos de Memória de Salvamento dos 4 Timbres

struct LayerMemoryPreset: Codable, Equatable {
    var path: String = ""
    var enabled: Bool = false
    var volume: Float = 1.0
    var filter: Float = 1.0
    var fxaAmount: Float = 0.20
    var fxaRelease: Float = 0.50
}

struct ProgramMemoryPreset: Codable, Equatable {
    var name: String = "Vazio"
    var hasData: Bool = false
    var layers: [LayerMemoryPreset] = [
        LayerMemoryPreset(enabled: true),
        LayerMemoryPreset(enabled: false),
        LayerMemoryPreset(enabled: false),
        LayerMemoryPreset(enabled: false)
    ]
}

enum WorkstationTab: Int, CaseIterable, Identifiable {
    case timbre = 0
    case keyboard = 1
    case midiCC = 2
    case eqMod = 3
    case delayReverb = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .timbre: return "Timbre"
        case .keyboard: return "Teclado & Toque"
        case .midiCC: return "MIDI CC"
        case .eqMod: return "EQ · Drive · Mod"
        case .delayReverb: return "Delay · Reverb"
        }
    }

    var icon: String {
        switch self {
        case .timbre: return "waveform"
        case .keyboard: return "pianokeys"
        case .midiCC: return "slider.horizontal.3"
        case .eqMod: return "slider.vertical.3"
        case .delayReverb: return "wave.3.right"
        }
    }

    /// Abas que editam a camada selecionada (A/B/C/D).
    var isPerLayer: Bool { self == .timbre || self == .keyboard || self == .midiCC }
}

func midiNoteName(_ note: Int) -> String {
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let clamped = min(max(note, 0), 127)
    let name = names[clamped % 12]
    let oct = (clamped / 12) - 1
    return "\(name)\(oct) (\(clamped))"
}

func decodeNullTerminatedCString(_ buffer: [CChar]) -> String {
    let prefix = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: prefix, as: UTF8.self)
}

// MARK: - ViewModel Principal da Workstation Nord

@MainActor
final class PianoViewModel: ObservableObject {
    nonisolated(unsafe) static weak var shared: PianoViewModel?
    nonisolated(unsafe) private var host: OpaquePointer?
    private var telemetryTimer: Timer?
    nonisolated(unsafe) private var keyMonitorDown: Any?
    nonisolated(unsafe) private var keyMonitorUp: Any?
    private var heldComputerKeys: Set<UInt16> = []

    // Mapeamento MIDI Universal dos Knobs (Right-Click Context Menu & MIDI Learn)
    @Published var knobMidiMappings: [String: Int] = [:]
    @Published var activeMidiLearnKey: String? = nil
    private var knobSetters: [String: (Double) -> Void] = [:]
    private var knobRanges: [String: ClosedRange<Double>] = [:]
    private var knobSteps: [String: Double] = [:]

    func registerKnob(idKey: String, range: ClosedRange<Double>, step: Double, setter: @escaping (Double) -> Void) {
        knobRanges[idKey] = range
        knobSteps[idKey] = step
        knobSetters[idKey] = setter
    }

    func startKnobMidiLearn(idKey: String) {
        if activeMidiLearnKey == idKey {
            activeMidiLearnKey = nil
        } else {
            activeMidiLearnKey = idKey
        }
    }

    func assignKnobCC(idKey: String, cc: Int) {
        knobMidiMappings[idKey] = cc
        if activeMidiLearnKey == idKey {
            activeMidiLearnKey = nil
        }
    }

    func unassignKnobCC(idKey: String) {
        knobMidiMappings.removeValue(forKey: idKey)
        if activeMidiLearnKey == idKey {
            activeMidiLearnKey = nil
        }
    }

    func handleIncomingMidiCC(cc: Int, value: Int) {
        if let learnKey = activeMidiLearnKey {
            knobMidiMappings[learnKey] = cc
            activeMidiLearnKey = nil
            return
        }

        let norm = Double(value) / 127.0
        for (idKey, mappedCC) in knobMidiMappings {
            if mappedCC == cc, let range = knobRanges[idKey], let setter = knobSetters[idKey] {
                var next = range.lowerBound + norm * (range.upperBound - range.lowerBound)
                if let st = knobSteps[idKey], st > 0 {
                    next = (next / st).rounded() * st
                }
                setter(next)
            }
        }
    }

    // Aba selecionada e camada selecionada para edição detalhada (0=A, 1=B, 2=C, 3=D)
    @Published var selectedTab: WorkstationTab = .timbre
    @Published var selectedLayer: Int = 0
    @Published var activeLoadingLayer: Int = 0
    @Published var showTuningPopover: Bool = false
    @Published var showVirtualKeyboard: Bool = false
    @Published var keyVelocities: [UInt8] = Array(repeating: 0, count: 128)
    @Published var errorMessage: String? = nil

    // Cor de acento (Configurações > Aparência)
    @Published var accentOption: AccentOption = {
        let saved = UserDefaults.standard.integer(forKey: "ElectroPiano_AccentOption")
        return AccentOption(rawValue: saved) ?? .nordRed
    }() {
        didSet {
            UserDefaults.standard.set(accentOption.rawValue, forKey: "ElectroPiano_AccentOption")
        }
    }

    // MARK: - 8 Memórias de Salvamento dos 4 Timbres
    @Published var selectedMemorySlot: Int = {
        let saved = UserDefaults.standard.integer(forKey: "ElectroPiano_ActiveMemorySlot")
        return (saved >= 1 && saved <= 8) ? saved : 1
    }()
    @Published var memorySlots: [ProgramMemoryPreset] = {
        if let data = UserDefaults.standard.data(forKey: "ElectroPiano_Memories_JSON"),
           let decoded = try? JSONDecoder().decode([ProgramMemoryPreset].self, from: data),
           decoded.count == 8 {
            return decoded
        }
        return Array(repeating: ProgramMemoryPreset(), count: 8)
    }()
    @Published var memoryStatusText: String = "M1: Inicial"
    @Published var storeConfirmationActive: Bool = false

    func memoryHasData(slot: Int) -> Bool {
        guard (1...8).contains(slot) else { return false }
        return memorySlots[slot - 1].hasData
    }

    func storeCurrentToMemory(slot: Int) {
        guard (1...8).contains(slot) else { return }
        selectedMemorySlot = slot
        var p = ProgramMemoryPreset()
        p.hasData = true

        var names: [String] = []
        for i in 0..<4 {
            let s = layers[i]
            p.layers[i] = LayerMemoryPreset(
                path: s.loaded ? s.path : "",
                enabled: s.params.enabled,
                volume: s.params.volume,
                filter: s.params.filter,
                fxaAmount: s.params.fxaAmount,
                fxaRelease: s.params.fxaRelease
            )
            if s.loaded && s.params.enabled {
                let short = (s.name as NSString).lastPathComponent.components(separatedBy: ".").first ?? s.name
                names.append(short)
            }
        }

        p.name = names.isEmpty ? "Vazio" : names.joined(separator: " + ")
        memorySlots[slot - 1] = p
        persistMemories()

        memoryStatusText = "M\(slot): \(p.name) (SALVO!)"
        storeConfirmationActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.storeConfirmationActive = false
        }
    }

    func recallMemory(slot: Int) {
        guard (1...8).contains(slot) else { return }
        selectedMemorySlot = slot
        UserDefaults.standard.set(slot, forKey: "ElectroPiano_ActiveMemorySlot")

        let p = memorySlots[slot - 1]
        if !p.hasData {
            memoryStatusText = "M\(slot): Vazio"
            return
        }

        memoryStatusText = "M\(slot): \(p.name)"
        for i in 0..<4 {
            let lp = p.layers[i]
            if !lp.path.isEmpty {
                if layers[i].path != lp.path || !layers[i].loaded {
                    loadLayerInstrument(layer: i, from: lp.path)
                }
            }
            updateLayerParams(i) {
                $0.enabled = lp.enabled
                $0.volume = lp.volume
                $0.filter = lp.filter
                $0.fxaAmount = lp.fxaAmount
                $0.fxaRelease = lp.fxaRelease
            }
        }
    }

    private func persistMemories() {
        UserDefaults.standard.set(selectedMemorySlot, forKey: "ElectroPiano_ActiveMemorySlot")
        if let encoded = try? JSONEncoder().encode(memorySlots) {
            UserDefaults.standard.set(encoded, forKey: "ElectroPiano_Memories_JSON")
        }
    }

    // Escala da interface (zoom via Menu Visualizar: Cmd+, Cmd-, Cmd 0).
    @Published var uiScale: Double = PianoViewModel.initialUIScale() {
        didSet {
            UserDefaults.standard.set(uiScale, forKey: "ElectroPiano_UIScale")
        }
    }

    // 4 Camadas independentes (A, B, C, D)
    @Published var layers: [LayerSlotState] = {
        var arr = Array(repeating: LayerSlotState(), count: 4)
        arr[0].params.enabled = true
        return arr
    }()

    // Telemetria em tempo real (Seção 1)
    @Published var activeVoices: Int = 0
    @Published var maxVoices: Int = 256 {
        didSet {
            if let h = host { npno_host_set_max_voices(h, Int32(maxVoices)) }
        }
    }
    @Published var totalMemoryBytes: UInt64 = 0
    @Published var totalUnpurgedBytes: UInt64 = 0
    @Published var midiLearnLayer: Int = -1
    @Published var midiLearnSlot: Int = -1
    @Published var sustainDown: Bool = false
    @Published var peakL: Float = 0.0
    @Published var peakR: Float = 0.0
    @Published var sampleRate: Double = 48000.0
    @Published var midiSources: String = "Nenhum controlador MIDI conectado"
    @Published var midiSourceCount: Int = 0

    // Dispositivos de Áudio e MIDI
    @Published var audioOutputDevices: [AudioOutputDeviceItem] = []
    @Published var selectedAudioDeviceID: UInt32 = 0 {
        didSet {
            guard let h = host else { return }
            if npno_host_get_current_audio_output_device(h) != selectedAudioDeviceID {
                _ = npno_host_set_audio_output_device(h, selectedAudioDeviceID)
            }
        }
    }
    @Published var midiInputDevices: [MidiInputDeviceItem] = []
    @Published var midiChannel: Int = 0 { // 0 = Omni, 1..16
        didSet {
            if let h = host { npno_host_set_midi_channel(h, Int32(midiChannel)) }
        }
    }

    // Seção 1 & Global: Controles Gerais
    @Published var fineTuneCents: Double = 0.0 {
        didSet {
            if let h = host { npno_host_set_fine_tune_cents(h, Float(fineTuneCents)) }
        }
    }
    @Published var baseTuningHz: Double = 440.0 {
        didSet {
            if let h = host { npno_host_set_base_tuning_hz(h, Float(baseTuningHz)) }
        }
    }
    @Published var masterGainDb: Double = 0.0 {
        didSet {
            let lin = Float(pow(10.0, masterGainDb / 20.0))
            if let h = host { npno_host_set_master_gain(h, lin) }
        }
    }
    @Published var masterPan: Double = 0.0 { // -100 .. +100
        didSet {
            if let h = host { npno_host_set_master_pan(h, Float(masterPan / 100.0)) }
        }
    }
    @Published var transposeSemitones: Double = 0.0 {
        didSet {
            if let h = host { npno_host_set_transpose(h, Int32(transposeSemitones.rounded())) }
        }
    }
    @Published var globalVelocityCurve: Double = 0.0 { // -1 = Soft, 0 = Main, +1 = Hard
        didSet {
            if let h = host { npno_host_set_velocity_curve(h, Int32(globalVelocityCurve.rounded())) }
        }
    }
    @Published var releaseScalePercent: Double = 100.0 {
        didSet {
            if let h = host { npno_host_set_release_scale(h, Float(releaseScalePercent / 100.0)) }
        }
    }
    @Published var releaseNoisePercent: Double = 100.0 {
        didSet {
            let gain = Float(releaseNoisePercent / 100.0)
            if let h = host {
                npno_host_set_release_sample_gain(h, gain)
                npno_host_set_release_samples_enabled(h, gain > 0.005)
            }
        }
    }

    // Seção 6: EQ | Drive + Mod 1 & Mod 2
    @Published var eqBassDb: Double = 0.0 {
        didSet { if let h = host { npno_host_set_eq_bass_db(h, Float(eqBassDb)) } }
    }
    @Published var eqMidDb: Double = 0.0 {
        didSet { if let h = host { npno_host_set_eq_mid_db(h, Float(eqMidDb)) } }
    }
    @Published var eqMidFreqHz: Double = 1000.0 {
        didSet { if let h = host { npno_host_set_eq_mid_freq_hz(h, Float(eqMidFreqHz)) } }
    }
    @Published var eqTrebleDb: Double = 0.0 {
        didSet { if let h = host { npno_host_set_eq_treble_db(h, Float(eqTrebleDb)) } }
    }
    @Published var driveEnabled: Bool = false {
        didSet { if let h = host { npno_host_set_drive_enabled(h, driveEnabled) } }
    }
    @Published var driveAmountPercent: Double = 25.0 {
        didSet { if let h = host { npno_host_set_drive_amount(h, Float(driveAmountPercent / 100.0)) } }
    }

    @Published var mod1: NPNOModulatorParams = {
        var m = NPNOModulatorParams()
        m.enabled = false
        m.target = 0
        m.wave = 0
        m.rateHz = 4.5
        m.depth = 0.35
        return m
    }() {
        didSet { pushModulator(0, mod1) }
    }

    @Published var mod2: NPNOModulatorParams = {
        var m = NPNOModulatorParams()
        m.enabled = false
        m.target = 2
        m.wave = 0
        m.rateHz = 5.5
        m.depth = 0.20
        return m
    }() {
        didSet { pushModulator(1, mod2) }
    }

    // Seção 7: Delay e Reverb
    @Published var delay: NPNODelayParams = {
        var d = NPNODelayParams()
        d.enabled = false
        d.amount = 0.25
        d.feedback = 0.35
        d.timeMs = 360.0
        d.syncToHost = false
        d.hostBpm = 120.0
        d.syncDivision = 1
        d.pingPong = true
        return d
    }() {
        didSet { pushDelay() }
    }

    @Published var reverb: NPNOReverbParams = {
        var r = NPNOReverbParams()
        r.enabled = true
        r.amount = 0.22
        r.size = 0.65
        r.decay = 0.55
        r.damping = 0.45
        r.preDelayMs = 18.0
        return r
    }() {
        didSet { pushReverb() }
    }

    // Teclado do Mac (QWERTY) & Demo
    @Published var computerBaseOctave: Int = 4
    @Published var computerVelocity: Int = 96
    @Published var isPlayingDemo: Bool = false
    private var demoTask: Task<Void, Never>?

    private static let keyCodeToSemitone: [UInt16: Int] = [
        0: 0, 13: 1, 1: 2, 14: 3, 2: 4, 3: 5, 17: 6, 5: 7, 16: 8,
        4: 9, 32: 10, 38: 11, 40: 12, 31: 13, 37: 14, 35: 15, 41: 16, 39: 17
    ]

    init() {
        Self.shared = self
        host = npno_host_create()
        if let h = host {
            _ = npno_host_start_audio(h)
            for l in 0..<4 {
                var lp = NPNOLayerParams()
                npno_host_get_layer_params(h, Int32(l), &lp)
                layers[l].params = lp
            }
            npno_host_set_midi_cc_callback(h, { cc, val, chan, ctx in
                guard let ctx = ctx else { return }
                let vm = Unmanaged<PianoViewModel>.fromOpaque(ctx).takeUnretainedValue()
                DispatchQueue.main.async {
                    vm.handleIncomingMidiCC(cc: Int(cc), value: Int(val))
                }
            }, Unmanaged.passUnretained(self).toOpaque())
        }
        refreshAudioAndMidiDevices()
        startTelemetryTimer()
        installKeyboardMonitors()
        autoLoadDefaultBank()
    }

    deinit {
        if let down = keyMonitorDown { NSEvent.removeMonitor(down) }
        if let up = keyMonitorUp { NSEvent.removeMonitor(up) }
        if let h = host {
            npno_host_destroy(h)
        }
    }

    // MARK: - Sincronização de Parâmetros

    func updateLayerParams(_ layer: Int, _ mutate: (inout NPNOLayerParams) -> Void) {
        guard (0..<4).contains(layer), let h = host else { return }
        var p = layers[layer].params
        mutate(&p)
        layers[layer].params = p
        npno_host_set_layer_params(h, Int32(layer), &p)
    }

    private func pushModulator(_ idx: Int, _ m: NPNOModulatorParams) {
        guard let h = host else { return }
        var copy = m
        npno_host_set_modulator_params(h, Int32(idx), &copy)
    }

    private func pushDelay() {
        guard let h = host else { return }
        var copy = delay
        npno_host_set_delay_params(h, &copy)
    }

    private func pushReverb() {
        guard let h = host else { return }
        var copy = reverb
        npno_host_set_reverb_params(h, &copy)
    }

    func tapDelayTempo() {
        guard let h = host else { return }
        npno_host_tap_delay(h)
        var d = NPNODelayParams()
        npno_host_get_delay_params(h, &d)
        delay = d
    }

    func toggleMidiLearn(layer: Int, slot: Int) {
        guard let h = host else { return }
        if midiLearnLayer == layer && midiLearnSlot == slot {
            npno_host_cancel_midi_learn(h)
        } else {
            npno_host_start_midi_learn(h, Int32(layer), Int32(slot))
        }
    }

    func purgeUnusedMemory() {
        guard let h = host else { return }
        _ = npno_host_purge_unused(h)
        for l in 0..<4 { refreshLayerInfo(l) }
    }

    func reloadPurgedMemory() {
        guard let h = host else { return }
        _ = npno_host_reload_purged(h)
        for l in 0..<4 { refreshLayerInfo(l) }
    }

    func resetEq() {
        eqBassDb = 0.0
        eqMidDb = 0.0
        eqMidFreqHz = 1000.0
        eqTrebleDb = 0.0
    }

    // MARK: - Áudio e MIDI

    func refreshAudioAndMidiDevices() {
        guard let h = host else { return }
        npno_host_refresh_audio_devices(h)
        let audioCount = npno_host_get_audio_output_device_count(h)
        var outDevs: [AudioOutputDeviceItem] = []
        for i in 0..<audioCount {
            var devID: UInt32 = 0
            var nameBuf = [CChar](repeating: 0, count: 256)
            if npno_host_get_audio_output_device_info(h, i, &devID, &nameBuf, Int32(nameBuf.count)) {
                outDevs.append(AudioOutputDeviceItem(id: devID, name: decodeNullTerminatedCString(nameBuf)))
            }
        }
        audioOutputDevices = outDevs
        selectedAudioDeviceID = npno_host_get_current_audio_output_device(h)

        npno_host_rescan_midi(h)
        let midiCount = npno_host_get_midi_input_count(h)
        var inDevs: [MidiInputDeviceItem] = []
        for i in 0..<midiCount {
            var nameBuf = [CChar](repeating: 0, count: 256)
            var enabled = true
            if npno_host_get_midi_input_info(h, i, &nameBuf, Int32(nameBuf.count), &enabled) {
                inDevs.append(MidiInputDeviceItem(id: Int(i), name: decodeNullTerminatedCString(nameBuf), enabled: enabled))
            }
        }
        midiInputDevices = inDevs
        midiChannel = Int(npno_host_get_midi_channel(h))
    }

    func setMidiDeviceEnabled(index: Int, enabled: Bool) {
        guard let h = host else { return }
        npno_host_set_midi_input_enabled(h, Int32(index), enabled)
        if index >= 0 && index < midiInputDevices.count {
            midiInputDevices[index].enabled = enabled
        }
    }

    // MARK: - Carregamento de Bancos .npno nas Camadas A/B/C/D

    @Published var embeddedBanks: [EmbeddedBankItem] = []

    private func autoLoadDefaultBank() {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        let bundleParent = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
        let resPath = Bundle.main.resourcePath ?? ""
        let homeLib = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Nord Electro Piano/Sounds")

        let searchDirs = [
            (resPath as NSString).appendingPathComponent("Sounds"),
            resPath,
            "/Library/Application Support/Nord Electro Piano/Sounds",
            homeLib,
            (bundleParent as NSString).appendingPathComponent("Sounds"),
            (cwd as NSString).appendingPathComponent("Sounds"),
            cwd,
            bundleParent,
            (cwd as NSString).deletingLastPathComponent
        ]

        var discovered: [EmbeddedBankItem] = []
        var seenNames = Set<String>()
        let addSampleFile = { (dirPath: String, fileName: String) in
            let lower = fileName.lowercased()
            guard lower.hasSuffix(".npno") || lower.hasSuffix(".nsmp4") else { return }
            if !seenNames.contains(fileName) {
                seenNames.insert(fileName)
                let full = (dirPath as NSString).appendingPathComponent(fileName)
                let display = (fileName as NSString).deletingPathExtension
                let item = EmbeddedBankItem(index: discovered.count + 1, name: display, path: full)
                discovered.append(item)
            }
        }
        for dir in searchDirs {
            guard !dir.isEmpty, let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for itemName in items.sorted() {
                let fullPath = (dir as NSString).appendingPathComponent(itemName)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir) {
                    if isDir.boolValue {
                        if let subItems = try? fm.contentsOfDirectory(atPath: fullPath) {
                            for sub in subItems.sorted() {
                                addSampleFile(fullPath, sub)
                            }
                        }
                    } else {
                        addSampleFile(dir, itemName)
                    }
                }
            }
        }
        embeddedBanks = discovered

        // Se houver uma memória gravada para o slot ativo, restaura-a automaticamente
        if memorySlots[selectedMemorySlot - 1].hasData {
            recallMemory(slot: selectedMemorySlot)
            return
        }

        if let astoria = discovered.first(where: { $0.name.lowercased().contains("astoria") }) {
            loadLayerInstrument(layer: 0, from: astoria.path)
            return
        }
        if let first = discovered.first {
            loadLayerInstrument(layer: 0, from: first.path)
            return
        }
    }

    func openFilePicker(forLayer layer: Int) {
        let panel = NSOpenPanel()
        let layerNames = ["A", "B", "C", "D"]
        let lName = (0..<4).contains(layer) ? layerNames[layer] : "A"
        panel.title = "Selecionar timbre .npno / .nsmp4 para a Camada \(lName)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let firstBank = embeddedBanks.first {
            let dir = (firstBank.path as NSString).deletingLastPathComponent
            panel.directoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        }
        var allowed: [UTType] = []
        if let utNpno = UTType(filenameExtension: "npno") { allowed.append(utNpno) }
        if let utNsmp4 = UTType(filenameExtension: "nsmp4") { allowed.append(utNsmp4) }
        if !allowed.isEmpty {
            panel.allowedContentTypes = allowed
        }
        if panel.runModal() == .OK, let url = panel.url {
            loadLayerInstrument(layer: layer, from: url.path)
        }
    }

    func loadLayerInstrument(layer: Int, from path: String) {
        guard (0..<4).contains(layer), let h = host, !layers[layer].isLoading else { return }
        activeLoadingLayer = layer
        layers[layer].isLoading = true
        layers[layer].loadProgress = 0.0
        errorMessage = nil

        let box = Unmanaged.passRetained(self)
        let hAddr = Int(bitPattern: h)
        let boxAddr = Int(bitPattern: box.toOpaque())
        let layerIdx = Int32(layer)

        DispatchQueue.global(qos: .userInitiated).async {
            guard let hostPtr = OpaquePointer(bitPattern: hAddr),
                  let ctxPtr = UnsafeMutableRawPointer(bitPattern: boxAddr) else { return }
            var errBuf = [CChar](repeating: 0, count: 512)
            let ok = npno_host_load_layer_instrument(
                hostPtr,
                layerIdx,
                path,
                { progress, ctx in
                    guard let ctx = ctx else { return }
                    let vm = Unmanaged<PianoViewModel>.fromOpaque(ctx).takeUnretainedValue()
                    DispatchQueue.main.async {
                        let l = vm.activeLoadingLayer
                        if (0..<4).contains(l) {
                            vm.layers[l].loadProgress = progress
                        }
                    }
                },
                ctxPtr,
                &errBuf,
                Int32(errBuf.count)
            )
            let errText = decodeNullTerminatedCString(errBuf)
            DispatchQueue.main.async {
                guard let raw = UnsafeMutableRawPointer(bitPattern: boxAddr) else { return }
                let retained = Unmanaged<PianoViewModel>.fromOpaque(raw)
                let vm = retained.takeUnretainedValue()
                retained.release()
                vm.layers[layer].isLoading = false
                if ok {
                    vm.refreshLayerInfo(layer)
                } else {
                    vm.errorMessage = errText.isEmpty ? "Falha ao carregar o arquivo .npno" : errText
                }
            }
        }
    }

    func stepLayerInstrument(layer: Int, delta: Int) {
        guard (0..<4).contains(layer), let h = host, !layers[layer].isLoading else { return }
        if !layers[layer].loaded && !embeddedBanks.isEmpty {
            let idx = ((layer + max(0, delta)) % embeddedBanks.count + embeddedBanks.count) % embeddedBanks.count
            loadLayerInstrument(layer: layer, from: embeddedBanks[idx].path)
            return
        }
        if !layers[layer].loaded && !layers[0].loaded {
            openFilePicker(forLayer: layer)
            return
        }
        activeLoadingLayer = layer
        layers[layer].isLoading = true
        layers[layer].loadProgress = 0.0

        let box = Unmanaged.passRetained(self)
        let hAddr = Int(bitPattern: h)
        let boxAddr = Int(bitPattern: box.toOpaque())
        let layerIdx = Int32(layer)
        let stepDelta = Int32(delta)

        DispatchQueue.global(qos: .userInitiated).async {
            guard let hostPtr = OpaquePointer(bitPattern: hAddr),
                  let ctxPtr = UnsafeMutableRawPointer(bitPattern: boxAddr) else { return }
            var errBuf = [CChar](repeating: 0, count: 512)
            let ok = npno_host_step_layer_instrument(
                hostPtr,
                layerIdx,
                stepDelta,
                { progress, ctx in
                    guard let ctx = ctx else { return }
                    let vm = Unmanaged<PianoViewModel>.fromOpaque(ctx).takeUnretainedValue()
                    DispatchQueue.main.async {
                        let l = vm.activeLoadingLayer
                        if (0..<4).contains(l) {
                            vm.layers[l].loadProgress = progress
                        }
                    }
                },
                ctxPtr,
                &errBuf,
                Int32(errBuf.count)
            )
            DispatchQueue.main.async {
                guard let raw = UnsafeMutableRawPointer(bitPattern: boxAddr) else { return }
                let retained = Unmanaged<PianoViewModel>.fromOpaque(raw)
                let vm = retained.takeUnretainedValue()
                retained.release()
                vm.layers[layer].isLoading = false
                if ok {
                    vm.refreshLayerInfo(layer)
                }
            }
        }
    }

    func refreshLayerInfo(_ layer: Int) {
        guard (0..<4).contains(layer), let h = host else { return }
        var info = NPNOInstrumentInfo()
        npno_host_get_layer_instrument_info(h, Int32(layer), &info)
        var lp = NPNOLayerParams()
        npno_host_get_layer_params(h, Int32(layer), &lp)

        layers[layer].params = lp
        layers[layer].loaded = info.loaded
        guard info.loaded else { return }

        let name = withUnsafePointer(to: &info.name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
        }
        let model = withUnsafePointer(to: &info.model) {
            $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
        }
        let path = withUnsafePointer(to: &info.path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 512) { String(cString: $0) }
        }
        let summary = withUnsafePointer(to: &info.summary) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        layers[layer].name = name.isEmpty ? "Piano .npno" : name
        layers[layer].model = model
        layers[layer].path = path
        layers[layer].summary = summary
        layers[layer].decodedBytes = info.decodedBytes
        layers[layer].totalDecodedBytes = info.totalDecodedBytes
        layers[layer].residentSamples = Int(info.residentSampleCount)
        layers[layer].totalSamples = Int(info.normalSampleCount + info.releaseSampleCount)
        layers[layer].bankIndex = Int(info.bankIndex)
        layers[layer].bankCount = Int(info.bankCount)
    }

    private func startTelemetryTimer() {
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollTelemetry()
            }
        }
    }

    private func pollTelemetry() {
        guard let h = host else { return }
        var tel = NPNOTelemetry()
        npno_host_get_telemetry(h, &tel)
        activeVoices = Int(tel.activeVoices)
        totalMemoryBytes = tel.totalMemoryBytes
        totalUnpurgedBytes = tel.totalUnpurgedBytes
        midiLearnLayer = Int(tel.midiLearnLayer)
        midiLearnSlot = Int(tel.midiLearnSlot)
        sustainDown = tel.sustainDown
        peakL = tel.peakL
        peakR = tel.peakR
        sampleRate = tel.sampleRate
        midiSourceCount = Int(tel.midiSourceCount)
        midiSources = withUnsafePointer(to: &tel.midiSources) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }

        let lv = (
            Int(tel.layerActiveVoices.0),
            Int(tel.layerActiveVoices.1),
            Int(tel.layerActiveVoices.2),
            Int(tel.layerActiveVoices.3)
        )
        let counts = [lv.0, lv.1, lv.2, lv.3]
        for l in 0..<4 {
            layers[l].activeVoices = counts[l]
            // Sincroniza de volta eventuais alterações feitas por CC MIDI ou MIDI Learn
            var lp = NPNOLayerParams()
            npno_host_get_layer_params(h, Int32(l), &lp)
            layers[l].params = lp
        }

        if showVirtualKeyboard {
            withUnsafePointer(to: &tel.keyVelocities) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: 128) { buf in
                    var changed = false
                    for i in 0..<128 where keyVelocities[i] != buf[i] {
                        changed = true
                        break
                    }
                    if changed {
                        var copy = [UInt8](repeating: 0, count: 128)
                        for i in 0..<128 { copy[i] = buf[i] }
                        keyVelocities = copy
                    }
                }
            }
        }
    }

    // MARK: - Disparo de notas e controles

    func noteOn(_ note: Int, velocity: Float = 0.78) {
        guard let h = host else { return }
        npno_host_note_on(h, Int32(note), velocity)
    }

    func noteOff(_ note: Int) {
        guard let h = host else { return }
        npno_host_note_off(h, Int32(note))
    }

    func setSustain(_ down: Bool) {
        guard let h = host else { return }
        npno_host_sustain(h, down)
    }

    func panic() {
        demoTask?.cancel()
        isPlayingDemo = false
        guard let h = host else { return }
        npno_host_panic(h)
    }

    func toggleDemo() {
        if isPlayingDemo {
            demoTask?.cancel()
            isPlayingDemo = false
            panic()
            return
        }
        guard layers.contains(where: { $0.loaded && $0.params.enabled }) else { return }
        isPlayingDemo = true
        demoTask = Task { @MainActor in
            defer { isPlayingDemo = false }
            let chords: [(notes: [Int], melody: [(note: Int, vel: Float, durMs: UInt64)])] = [
                ([36, 48, 55, 64], [(72, 0.62, 360), (74, 0.68, 360), (76, 0.76, 520), (79, 0.85, 640)]),
                ([33, 45, 52, 60], [(76, 0.72, 360), (74, 0.66, 360), (72, 0.74, 520), (69, 0.60, 640)]),
                ([29, 41, 48, 57], [(69, 0.68, 360), (72, 0.78, 360), (76, 0.88, 520), (81, 0.94, 680)]),
                ([31, 43, 50, 59], [(79, 0.82, 420), (76, 0.72, 420), (74, 0.68, 520), (72, 0.86, 900)])
            ]
            for phrase in chords {
                if Task.isCancelled { break }
                setSustain(true)
                for (i, n) in phrase.notes.enumerated() {
                    noteOn(n, velocity: 0.58 + Float(i) * 0.05)
                    try? await Task.sleep(nanoseconds: 35_000_000)
                }
                for n in phrase.notes { noteOff(n) }
                for m in phrase.melody {
                    if Task.isCancelled { break }
                    noteOn(m.note, velocity: m.vel)
                    try? await Task.sleep(nanoseconds: m.durMs * 1_000_000)
                    noteOff(m.note)
                }
                setSustain(false)
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
            setSustain(false)
        }
    }

    // MARK: - Teclado do Mac (QWERTY)

    private func installKeyboardMonitors() {
        keyMonitorDown = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.window?.firstResponder is NSText {
                return event
            }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false {
                return event
            }
            if self.handleKeyDown(event) { return nil }
            return event
        }
        keyMonitorUp = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self = self else { return event }
            if event.window?.firstResponder is NSText {
                return event
            }
            if self.handleKeyUp(event) { return nil }
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let code = event.keyCode
        if code == 49 {
            if !event.isARepeat { setSustain(true) }
            return true
        }
        if code == 6 && !event.isARepeat {
            releaseAllComputerNotes()
            computerBaseOctave = max(1, computerBaseOctave - 1)
            return true
        }
        if code == 7 && !event.isARepeat {
            releaseAllComputerNotes()
            computerBaseOctave = min(6, computerBaseOctave + 1)
            return true
        }
        if code == 8 && !event.isARepeat {
            computerVelocity = max(16, computerVelocity - 12)
            return true
        }
        if code == 9 && !event.isARepeat {
            computerVelocity = min(127, computerVelocity + 12)
            return true
        }
        guard let offset = Self.keyCodeToSemitone[code] else { return false }
        if event.isARepeat || heldComputerKeys.contains(code) { return true }
        heldComputerKeys.insert(code)
        let midiNote = (computerBaseOctave + 1) * 12 + offset
        if (0...127).contains(midiNote) {
            noteOn(midiNote, velocity: Float(computerVelocity) / 127.0)
        }
        return true
    }

    private func handleKeyUp(_ event: NSEvent) -> Bool {
        let code = event.keyCode
        if code == 49 {
            setSustain(false)
            return true
        }
        guard let offset = Self.keyCodeToSemitone[code] else { return false }
        heldComputerKeys.remove(code)
        let midiNote = (computerBaseOctave + 1) * 12 + offset
        if (0...127).contains(midiNote) {
            noteOff(midiNote)
        }
        return true
    }

    private func releaseAllComputerNotes() {
        for code in heldComputerKeys {
            if let offset = Self.keyCodeToSemitone[code] {
                let midiNote = (computerBaseOctave + 1) * 12 + offset
                if (0...127).contains(midiNote) {
                    noteOff(midiNote)
                }
            }
        }
        heldComputerKeys.removeAll()
    }
}

// MARK: - Cena Nativa de Configurações (Cmd+,) — Abas: Áudio · MIDI · Aparência · Teclado

struct ElectroProSettingsView: View {
    @ObservedObject var vm: PianoViewModel

    var body: some View {
        TabView {
            Tab("Áudio", systemImage: "speaker.wave.3.fill") {
                audioSettingsTab
            }

            Tab("MIDI", systemImage: "pianokeys") {
                midiSettingsTab
            }

            Tab("Aparência", systemImage: "paintpalette.fill") {
                appearanceSettingsTab
            }

            Tab("Teclado", systemImage: "keyboard") {
                keyboardSettingsTab
            }
        }
        .frame(width: 540, height: 380)
        .preferredColorScheme(.dark)
        .tint(StudioTokens.accent)
        .onAppear {
            vm.refreshAudioAndMidiDevices()
        }
    }

    // Aba 1: Áudio
    private var audioSettingsTab: some View {
        Form {
            Section("Saída de Áudio (CoreAudio)") {
                Picker("Dispositivo de saída", selection: $vm.selectedAudioDeviceID) {
                    ForEach(vm.audioOutputDevices) { dev in
                        Text(dev.name).tag(dev.id)
                    }
                }

                LabeledContent("Taxa de amostragem ativa") {
                    Text(String(format: "%.1f kHz • 32-bit Float Estéreo", vm.sampleRate / 1000.0))
                        .font(StudioTokens.fontValue)
                        .foregroundStyle(StudioTokens.textSecondary)
                }

                Picker("Polifonia máxima", selection: $vm.maxVoices) {
                    Text("64 vozes").tag(64)
                    Text("128 vozes").tag(128)
                    Text("256 vozes (Padrão)").tag(256)
                    Text("512 vozes").tag(512)
                }

                HStack {
                    Button {
                        vm.refreshAudioAndMidiDevices()
                    } label: {
                        Label("Atualizar dispositivos", systemImage: "arrow.clockwise")
                    }

                    Spacer()

                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
                    } label: {
                        Label("Abrir Configuração Áudio e MIDI…", systemImage: "slider.horizontal.below.rectangle")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // Aba 2: MIDI
    private var midiSettingsTab: some View {
        Form {
            Section("Recepção MIDI Global") {
                Picker("Canal MIDI principal", selection: $vm.midiChannel) {
                    Text("Omni (Todos os canais 1–16)").tag(0)
                    Divider()
                    ForEach(1...16, id: \.self) { ch in
                        Text("Canal \(ch)").tag(ch)
                    }
                }
            }

            Section {
                if vm.midiInputDevices.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "pianokeys")
                            .font(.system(size: 18))
                            .foregroundStyle(StudioTokens.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nenhum controlador conectado")
                                .font(StudioTokens.fontBodyMedium)
                                .foregroundStyle(StudioTokens.textPrimary)
                            Text("Conecte um teclado MIDI USB ou interface DIN e clique em Reescanear.")
                                .font(StudioTokens.fontLabel)
                                .foregroundStyle(StudioTokens.textSecondary)
                        }
                        Spacer()
                        Button {
                            vm.refreshAudioAndMidiDevices()
                        } label: {
                            Label("Reescanear", systemImage: "arrow.clockwise")
                        }
                    }
                    .padding(.vertical, 6)
                } else {
                    ForEach(vm.midiInputDevices) { item in
                        Toggle(
                            item.name,
                            isOn: Binding(
                                get: { item.enabled },
                                set: { newVal in vm.setMidiDeviceEnabled(index: item.id, enabled: newVal) }
                            )
                        )
                    }

                    HStack {
                        Spacer()
                        Button {
                            vm.refreshAudioAndMidiDevices()
                        } label: {
                            Label("Reescanear", systemImage: "arrow.clockwise")
                        }
                    }
                }
            } header: {
                Text("Controladores MIDI")
            }
        }
        .formStyle(.grouped)
    }

    // Aba 3: Aparência
    private var appearanceSettingsTab: some View {
        Form {
            Section("Cor de Acento") {
                Picker("Cor de acento da interface", selection: $vm.accentOption) {
                    ForEach(AccentOption.allCases) { option in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(option.color)
                                .frame(width: 10, height: 10)
                            Text(option.title)
                        }
                        .tag(option)
                    }
                }
                .pickerStyle(.radioGroup)

                Text("A cor de acento destaca exclusivamente a camada em edição, estados ativos e arcos de valor dos controles.")
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(StudioTokens.textSecondary)
            }
        }
        .formStyle(.grouped)
    }

    // Aba 4: Teclado (QWERTY)
    private var keyboardSettingsTab: some View {
        Form {
            Section("Teclado do Mac (QWERTY)") {
                Stepper(
                    "Oitava base: C\(vm.computerBaseOctave)",
                    value: $vm.computerBaseOctave,
                    in: 1...6
                )

                Stepper(
                    "Velocidade das notas: \(vm.computerVelocity)",
                    value: $vm.computerVelocity,
                    in: 16...127,
                    step: 8
                )

                Toggle("Exibir teclado virtual de 61 teclas na janela (⌘K)", isOn: $vm.showVirtualKeyboard)
            }

            Section("Atalhos Rápidos de Execução") {
                LabeledContent("Notas brancas") {
                    Text("A S D F G H J K L Ç")
                        .font(StudioTokens.fontValue)
                }
                LabeledContent("Notas pretas") {
                    Text("W E   T Y U   O P")
                        .font(StudioTokens.fontValue)
                }
                LabeledContent("Oitava − / + e Velocity − / +") {
                    Text("Z / X  •  C / V")
                        .font(StudioTokens.fontValue)
                }
                LabeledContent("Pedal Sustain") {
                    Text("Barra de Espaço")
                        .font(StudioTokens.fontValue)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Ponto de Entrada do App (macOS 26 Tahoe)

@main
struct ElectroPianoApp: App {
    @StateObject private var viewModel = PianoViewModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Electro Pro") {
            ContentView(vm: viewModel)
        }
        .defaultSize(width: 1220, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            // Menu Arquivo
            CommandGroup(replacing: .newItem) {
                Button("Carregar Timbre na Camada A…") {
                    viewModel.openFilePicker(forLayer: 0)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Carregar Timbre na Camada B…") {
                    viewModel.openFilePicker(forLayer: 1)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button("Carregar Timbre na Camada C…") {
                    viewModel.openFilePicker(forLayer: 2)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Carregar Timbre na Camada D…") {
                    viewModel.openFilePicker(forLayer: 3)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("Salvar no Programa Atual (M\(viewModel.selectedMemorySlot))") {
                    viewModel.storeCurrentToMemory(slot: viewModel.selectedMemorySlot)
                }
                .keyboardShortcut("s", modifiers: [.command])

                Divider()

                Button("Liberar Samples Não Usados da RAM (Purge)") {
                    viewModel.purgeUnusedMemory()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Recarregar Samples Purgados") {
                    viewModel.reloadPurgedMemory()
                }
            }

            // Menu Editar
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Restaurar Equalizador (Flat 0 dB)") {
                    viewModel.resetEq()
                }
                Button("Panic — Silenciar Todas as Vozes") {
                    viewModel.panic()
                }
                .keyboardShortcut(".", modifiers: [.command])
            }

            // Menu Visualizar (Abas, Camadas, Teclado Virtual e Zoom em Cmd +/−)
            CommandGroup(after: .toolbar) {
                Button(viewModel.showVirtualKeyboard ? "Ocultar Teclado Virtual (61 Teclas)" : "Mostrar Teclado Virtual (61 Teclas)") {
                    viewModel.showVirtualKeyboard.toggle()
                }
                .keyboardShortcut("k", modifiers: [.command])

                Divider()

                ForEach(WorkstationTab.allCases) { tab in
                    Button("Aba \(tab.title)") {
                        viewModel.selectedTab = tab
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(tab.rawValue + 1)")), modifiers: [.command])
                }

                Divider()

                ForEach(0..<4, id: \.self) { layer in
                    Button("Selecionar Camada \(kLayerLetters[layer])") {
                        viewModel.selectedLayer = layer
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(layer + 1)")), modifiers: [.option])
                }

                Divider()

                Button("Aumentar Zoom") {
                    viewModel.zoomIn()
                }
                .keyboardShortcut("=", modifiers: [.command])

                Button("Diminuir Zoom") {
                    viewModel.zoomOut()
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button("Tamanho Real (100%)") {
                    viewModel.uiScale = 1.0
                }
                .keyboardShortcut("0", modifiers: [.command])
            }

            // Menu Ajuda (Demo + Guia de Gestos)
            CommandGroup(replacing: .help) {
                Button(viewModel.isPlayingDemo ? "Parar Demonstração Musical" : "Tocar Demonstração Musical (Demo)") {
                    viewModel.toggleDemo()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("Guia Rápido de Controles: Arraste = Ajustar • Shift = Fino • Duplo Clique = Padrão/Digitar • Botão Direito = MIDI Learn") {}
                    .disabled(true)
            }
        }

        // Cena Nativa de Configurações (Cmd+,)
        Settings {
            ElectroProSettingsView(vm: viewModel)
        }
    }
}
