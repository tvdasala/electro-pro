import AppKit
import Foundation
import NPNOBridge
import os
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Thread-Safe Bridge for Continuous MIDI / C++ Progress Stream (Nonisolated, Zero Task per Event)

final class RealtimeMIDIBridge: @unchecked Sendable {
    static let shared = RealtimeMIDIBridge()

    struct RawMIDIEvent: Sendable {
        var statusType: UInt8
        var data1: UInt8
        var data2: UInt8
        var channel: UInt8
        var timestamp: TimeInterval
    }

    private static let kRingCapacity = 128

    private var lock = os_unfair_lock()
    private var dirtyCCLow: UInt64 = 0
    private var dirtyCCHigh: UInt64 = 0
    private var ccValues: [UInt8] = Array(repeating: 0, count: 128)
    private var ccChannels: [UInt8] = Array(repeating: 1, count: 128)
    private var latestLearnCC: Int32 = -1
    private var latestLearnChannel: Int32 = 0
    private var latestProgramChange: Int32 = -1
    private var latestProgramChangeChannel: Int32 = 0

    private var eventRing: [RawMIDIEvent] = Array(
        repeating: RawMIDIEvent(statusType: 0, data1: 0, data2: 0, channel: 1, timestamp: 0),
        count: 128
    )
    private var eventWriteIndex: Int = 0
    private var eventCount: Int = 0

    private var dirtyLoadMask: UInt8 = 0
    private var loadProgress: (Float, Float, Float, Float) = (0, 0, 0, 0)

    private init() {}

    nonisolated func recordMidiCC(cc: Int32, value: Int32, channel: Int32 = 1) {
        let clampedCC = Int(cc) & 0x7F
        let clampedVal = UInt8(clamping: value)
        let clampedCh = UInt8(clamping: max(1, min(16, Int(channel))))
        os_unfair_lock_lock(&lock)
        ccValues[clampedCC] = clampedVal
        ccChannels[clampedCC] = clampedCh
        if clampedCC < 64 {
            dirtyCCLow |= (UInt64(1) << UInt64(clampedCC))
        } else {
            dirtyCCHigh |= (UInt64(1) << UInt64(clampedCC - 64))
        }
        latestLearnCC = Int32(clampedCC)
        latestLearnChannel = Int32(clampedCh)
        os_unfair_lock_unlock(&lock)
    }

    nonisolated func recordMidiEvent(statusType: UInt8, data1: Int32, data2: Int32, channel: Int32) {
        let now = CFAbsoluteTimeGetCurrent()
        let st = statusType
        let d1 = UInt8(clamping: data1)
        let d2 = UInt8(clamping: data2)
        let ch = UInt8(clamping: max(1, min(16, Int(channel))))

        os_unfair_lock_lock(&lock)
        eventRing[eventWriteIndex] = RawMIDIEvent(
            statusType: st,
            data1: d1,
            data2: d2,
            channel: ch,
            timestamp: now
        )
        eventWriteIndex = (eventWriteIndex + 1) % Self.kRingCapacity
        if eventCount < Self.kRingCapacity {
            eventCount += 1
        }
        if st == 0xC0 {
            latestProgramChange = Int32(d1)
            latestProgramChangeChannel = Int32(ch)
        } else if st == 0xB0 {
            let ccIdx = Int(d1) & 0x7F
            ccChannels[ccIdx] = ch
            latestLearnChannel = Int32(ch)
        }
        os_unfair_lock_unlock(&lock)
    }

    nonisolated func recordLoadProgress(layer: Int, progress: Float) {
        guard (0..<4).contains(layer) else { return }
        os_unfair_lock_lock(&lock)
        switch layer {
        case 0: loadProgress.0 = progress
        case 1: loadProgress.1 = progress
        case 2: loadProgress.2 = progress
        default: loadProgress.3 = progress
        }
        dirtyLoadMask |= (UInt8(1) << UInt8(layer))
        os_unfair_lock_unlock(&lock)
    }

    struct Snapshot: Sendable {
        var lowMask: UInt64
        var highMask: UInt64
        var values: [UInt8]
        var channels: [UInt8]
        var latestLearnCC: Int32
        var latestLearnChannel: Int32
        var latestProgramChange: Int32
        var latestProgramChangeChannel: Int32
        var loadMask: UInt8
        var loadProgress: (Float, Float, Float, Float)
    }

    nonisolated func drain() -> Snapshot? {
        os_unfair_lock_lock(&lock)
        if dirtyCCLow == 0 && dirtyCCHigh == 0 && dirtyLoadMask == 0 && latestLearnCC < 0 && latestProgramChange < 0 {
            os_unfair_lock_unlock(&lock)
            return nil
        }
        let snap = Snapshot(
            lowMask: dirtyCCLow,
            highMask: dirtyCCHigh,
            values: ccValues,
            channels: ccChannels,
            latestLearnCC: latestLearnCC,
            latestLearnChannel: latestLearnChannel,
            latestProgramChange: latestProgramChange,
            latestProgramChangeChannel: latestProgramChangeChannel,
            loadMask: dirtyLoadMask,
            loadProgress: loadProgress
        )
        dirtyCCLow = 0
        dirtyCCHigh = 0
        latestLearnCC = -1
        latestProgramChange = -1
        dirtyLoadMask = 0
        os_unfair_lock_unlock(&lock)
        return snap
    }

    nonisolated func drainEvents() -> [RawMIDIEvent] {
        os_unfair_lock_lock(&lock)
        guard eventCount > 0 else {
            os_unfair_lock_unlock(&lock)
            return []
        }
        let count = eventCount
        let start = (eventWriteIndex - count + Self.kRingCapacity) % Self.kRingCapacity
        var result: [RawMIDIEvent] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let idx = (start + i) % Self.kRingCapacity
            result.append(eventRing[idx])
        }
        eventCount = 0
        os_unfair_lock_unlock(&lock)
        return result
    }
}

// Pure C callbacks defined outside @MainActor so actor-isolation checks are never injected on CoreMIDI/Background threads
private nonisolated let kMidiCCBridgeCallback: NPNOMidiCCCallback = { cc, val, _, _ in
    RealtimeMIDIBridge.shared.recordMidiCC(cc: cc, value: val)
}

private nonisolated let kMidiEventBridgeCallback: NPNOMidiEventCallback = { statusType, data1, data2, channel, _ in
    RealtimeMIDIBridge.shared.recordMidiEvent(statusType: statusType, data1: data1, data2: data2, channel: channel)
}

private nonisolated let kLoadProgressCallbackLayer0: @convention(c) (Float, UnsafeMutableRawPointer?) -> Void = { progress, _ in
    RealtimeMIDIBridge.shared.recordLoadProgress(layer: 0, progress: progress)
}

private nonisolated let kLoadProgressCallbackLayer1: @convention(c) (Float, UnsafeMutableRawPointer?) -> Void = { progress, _ in
    RealtimeMIDIBridge.shared.recordLoadProgress(layer: 1, progress: progress)
}

private nonisolated let kLoadProgressCallbackLayer2: @convention(c) (Float, UnsafeMutableRawPointer?) -> Void = { progress, _ in
    RealtimeMIDIBridge.shared.recordLoadProgress(layer: 2, progress: progress)
}

private nonisolated let kLoadProgressCallbackLayer3: @convention(c) (Float, UnsafeMutableRawPointer?) -> Void = { progress, _ in
    RealtimeMIDIBridge.shared.recordLoadProgress(layer: 3, progress: progress)
}

private nonisolated func loadProgressCallback(forLayer layer: Int) -> (@convention(c) (Float, UnsafeMutableRawPointer?) -> Void) {
    switch layer {
    case 0: return kLoadProgressCallbackLayer0
    case 1: return kLoadProgressCallbackLayer1
    case 2: return kLoadProgressCallbackLayer2
    default: return kLoadProgressCallbackLayer3
    }
}

// MARK: - Helper Models for Audio, MIDI, and Layers

struct AudioOutputDeviceItem: Identifiable, Hashable {
    let id: UInt32
    let name: String
}

struct MidiInputDeviceItem: Identifiable, Hashable {
    let id: Int
    let name: String
    var enabled: Bool
}

enum SoundCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case grand = "Grand"
    case upright = "Upright"
    case electric = "Electric"
    case clavHarpsi = "Clav/Harpsi"
    case synthSample = "Synth/Sample"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .grand: return L("Grand")
        case .upright: return L("Upright")
        case .electric: return L("Electric")
        case .clavHarpsi: return L("Clav/Harpsi")
        case .synthSample: return L("Synth/Sample")
        }
    }

    nonisolated static func infer(fileName: String, fullPath: String) -> SoundCategory {
        let lowerName = fileName.lowercased()
        let lowerPath = fullPath.lowercased()
        if lowerName.hasSuffix(".nsmp4") {
            return .synthSample
        }
        let combined = lowerName + " " + lowerPath
        if combined.contains("clav") || combined.contains("harpsi") || combined.contains("cembalo") || combined.contains("lute") || combined.contains("virginal") {
            return .clavHarpsi
        }
        if combined.contains("synth") || combined.contains("pad") || combined.contains("string") || combined.contains("brass") || combined.contains("choir") || combined.contains("mellotron") || combined.contains("chamberlin") || combined.contains("organ") || combined.contains("sample") {
            return .synthSample
        }
        if combined.contains("ep") || combined.contains("electric") || combined.contains("rhodes") || combined.contains("wurli") || combined.contains("cp80") || combined.contains("cp-80") || combined.contains("dx") || combined.contains("tine") || combined.contains("reed") || combined.contains("mk i") || combined.contains("mk ii") || combined.contains("mk v") || combined.contains("sparkletop") || combined.contains("dyno") || combined.contains("suitcase") || combined.contains("pianet") {
            return .electric
        }
        if combined.contains("upright") || combined.contains("bambino") || combined.contains("amber") || combined.contains("rain") || combined.contains("honky") || combined.contains("saloon") || combined.contains("spinet") || combined.contains("felt") || combined.contains("ostertag") || combined.contains("mellow upright") || combined.contains("black upright") || combined.contains("blue swede") || combined.contains("white grand") == false && combined.contains("queen") {
            return .upright
        }
        return .grand
    }
}

struct EmbeddedBankItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    let index: Int
    let name: String
    let path: String
    let formatExtension: String
    let fileSizeBytes: UInt64
    let category: SoundCategory

    init(
        index: Int,
        name: String,
        path: String,
        formatExtension: String = ".npno",
        fileSizeBytes: UInt64 = 0,
        category: SoundCategory? = nil
    ) {
        self.index = index
        self.name = name
        self.path = path
        self.formatExtension = formatExtension
        self.fileSizeBytes = fileSizeBytes
        self.category = category ?? SoundCategory.infer(fileName: (path as NSString).lastPathComponent, fullPath: path)
    }

    var sizeMB: Double {
        Double(fileSizeBytes) / (1024.0 * 1024.0)
    }

    var displayName: String {
        let pad = index < 10 ? "0\(index)" : "\(index)"
        return "\(pad). \(name)"
    }

    var sizeLabel: String {
        let mb = Double(fileSizeBytes) / 1_048_576.0
        return String(format: "%.1f MB", mb)
    }
}

enum SoundBrowserFilter: Hashable, Identifiable {
    case all
    case favorites
    case recent
    case category(SoundCategory)

    var id: String {
        switch self {
        case .all: return "all"
        case .favorites: return "favorites"
        case .recent: return "recent"
        case .category(let cat): return "cat_\(cat.rawValue)"
        }
    }

    var title: String {
        switch self {
        case .all: return L("All")
        case .favorites: return L("Favorites")
        case .recent: return L("Recent")
        case .category(let cat): return cat.localizedTitle
        }
    }
}

enum LayerLoadError: Equatable {
    case corrupted(fileName: String)
    case unsupportedFormat
    case insufficientRAM(fileName: String, neededMB: Int, availableMB: Int)
    case missingFile(fileName: String, originalPath: String)

    var message: String {
        switch self {
        case .corrupted(let fileName):
            return String(localized: "Could not load \(fileName). The file may be corrupted or incomplete.", bundle: .module)
        case .unsupportedFormat:
            return L("Unsupported file format. Electro Pro supports .npno and .nsmp4 files.")
        case .insufficientRAM(let fileName, let neededMB, let availableMB):
            return String(
                localized: "Not enough memory to load \(fileName) (\(neededMB) MB required, \(availableMB) MB available). Try enabling Purge on Demand in Settings > Library.",
                bundle: .module
            )
        case .missingFile(let fileName, _):
            return String(localized: "Sound not found: \(fileName)", bundle: .module)
        }
    }
}

struct LayerSlotState {
    var loaded: Bool = false
    var isLoading: Bool = false
    var loadProgress: Float = 0.0
    var loadGeneration: Int = 0
    var loadError: LayerLoadError? = nil
    var name: String = L("No Sound")
    var model: String = L("Load a .npno or .nsmp4 file")
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

// MARK: - Full Program Serialization Models (.epprog JSON & 8 Memory Slots)

struct LayerMemoryPreset: Codable, Equatable, Sendable {
    var path: String = ""
    var enabled: Bool = false
    var volume: Float = 1.0
    var filter: Float = 1.0
    var fxaAmount: Float = 0.20
    var fxaRelease: Float = 0.50
    var ccVolume: Int32 = -1
    var ccFilter: Int32 = -1
    var ccFxaAmount: Int32 = -1
    var ccFxaRelease: Int32 = -1
    var keyLow: Int32 = 0
    var keyHigh: Int32 = 127
    var velLow: Int32 = 1
    var velHigh: Int32 = 127
    var midiChannel: Int32 = 0
    var velocityCurve: Int32 = 0
    var pitchBendDown: Int32 = -2
    var pitchBendUp: Int32 = 2
    var portamentoOn: Bool = false
    var portamentoTimeMs: Float = 120.0
    var fixedVelocity: Bool = false
    var fixedVelocityValue: Int32 = 100
    var legatoMono: Bool = false
    var timbreMode: Int32 = 0
    var sustainPedalOn: Bool = true
    var undampedOn: Bool = true
    var compOn: Bool = false
    var compAmount: Float = 0.45
    var compFast: Bool = false
    var octaveShift: Int32 = 0
    var originalEnvelope: Bool = true
    var attackMs: Float = 1.0
    var releaseMs: Float = 600.0

    init(
        path: String = "",
        enabled: Bool = false,
        volume: Float = 1.0,
        filter: Float = 1.0,
        fxaAmount: Float = 0.20,
        fxaRelease: Float = 0.50
    ) {
        self.path = path
        self.enabled = enabled
        self.volume = volume
        self.filter = filter
        self.fxaAmount = fxaAmount
        self.fxaRelease = fxaRelease
    }

    init(path: String, params p: NPNOLayerParams) {
        self.path = path
        self.enabled = p.enabled
        self.volume = p.volume
        self.filter = p.filter
        self.fxaAmount = p.fxaAmount
        self.fxaRelease = p.fxaRelease
        self.ccVolume = p.ccVolume
        self.ccFilter = p.ccFilter
        self.ccFxaAmount = p.ccFxaAmount
        self.ccFxaRelease = p.ccFxaRelease
        self.keyLow = p.keyLow
        self.keyHigh = p.keyHigh
        self.velLow = p.velLow
        self.velHigh = p.velHigh
        self.midiChannel = p.midiChannel
        self.velocityCurve = p.velocityCurve
        self.pitchBendDown = p.pitchBendDown
        self.pitchBendUp = p.pitchBendUp
        self.portamentoOn = p.portamentoOn
        self.portamentoTimeMs = p.portamentoTimeMs
        self.fixedVelocity = p.fixedVelocity
        self.fixedVelocityValue = p.fixedVelocityValue
        self.legatoMono = p.legatoMono
        self.timbreMode = p.timbreMode
        self.sustainPedalOn = p.sustainPedalOn
        self.undampedOn = p.undampedOn
        self.compOn = p.compOn
        self.compAmount = p.compAmount
        self.compFast = p.compFast
        self.octaveShift = p.octaveShift
        self.originalEnvelope = p.originalEnvelope
        self.attackMs = p.attackMs
        self.releaseMs = p.releaseMs
    }

    func apply(to p: inout NPNOLayerParams) {
        p.enabled = enabled
        p.volume = volume
        p.filter = filter
        p.fxaAmount = fxaAmount
        p.fxaRelease = fxaRelease
        p.ccVolume = ccVolume
        p.ccFilter = ccFilter
        p.ccFxaAmount = ccFxaAmount
        p.ccFxaRelease = ccFxaRelease
        p.keyLow = keyLow
        p.keyHigh = keyHigh
        p.velLow = velLow
        p.velHigh = velHigh
        p.midiChannel = midiChannel
        p.velocityCurve = velocityCurve
        p.pitchBendDown = pitchBendDown
        p.pitchBendUp = pitchBendUp
        p.portamentoOn = portamentoOn
        p.portamentoTimeMs = portamentoTimeMs
        p.fixedVelocity = fixedVelocity
        p.fixedVelocityValue = fixedVelocityValue
        p.legatoMono = legatoMono
        p.timbreMode = timbreMode
        p.sustainPedalOn = sustainPedalOn
        p.undampedOn = undampedOn
        p.compOn = compOn
        p.compAmount = compAmount
        p.compFast = compFast
        p.octaveShift = octaveShift
        p.originalEnvelope = originalEnvelope
        p.attackMs = attackMs
        p.releaseMs = releaseMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
        filter = try c.decodeIfPresent(Float.self, forKey: .filter) ?? 1.0
        fxaAmount = try c.decodeIfPresent(Float.self, forKey: .fxaAmount) ?? 0.20
        fxaRelease = try c.decodeIfPresent(Float.self, forKey: .fxaRelease) ?? 0.50
        ccVolume = try c.decodeIfPresent(Int32.self, forKey: .ccVolume) ?? -1
        ccFilter = try c.decodeIfPresent(Int32.self, forKey: .ccFilter) ?? -1
        ccFxaAmount = try c.decodeIfPresent(Int32.self, forKey: .ccFxaAmount) ?? -1
        ccFxaRelease = try c.decodeIfPresent(Int32.self, forKey: .ccFxaRelease) ?? -1
        keyLow = try c.decodeIfPresent(Int32.self, forKey: .keyLow) ?? 0
        keyHigh = try c.decodeIfPresent(Int32.self, forKey: .keyHigh) ?? 127
        velLow = try c.decodeIfPresent(Int32.self, forKey: .velLow) ?? 1
        velHigh = try c.decodeIfPresent(Int32.self, forKey: .velHigh) ?? 127
        midiChannel = try c.decodeIfPresent(Int32.self, forKey: .midiChannel) ?? 0
        velocityCurve = try c.decodeIfPresent(Int32.self, forKey: .velocityCurve) ?? 0
        pitchBendDown = try c.decodeIfPresent(Int32.self, forKey: .pitchBendDown) ?? -2
        pitchBendUp = try c.decodeIfPresent(Int32.self, forKey: .pitchBendUp) ?? 2
        portamentoOn = try c.decodeIfPresent(Bool.self, forKey: .portamentoOn) ?? false
        portamentoTimeMs = try c.decodeIfPresent(Float.self, forKey: .portamentoTimeMs) ?? 120.0
        fixedVelocity = try c.decodeIfPresent(Bool.self, forKey: .fixedVelocity) ?? false
        fixedVelocityValue = try c.decodeIfPresent(Int32.self, forKey: .fixedVelocityValue) ?? 100
        legatoMono = try c.decodeIfPresent(Bool.self, forKey: .legatoMono) ?? false
        timbreMode = try c.decodeIfPresent(Int32.self, forKey: .timbreMode) ?? 0
        sustainPedalOn = try c.decodeIfPresent(Bool.self, forKey: .sustainPedalOn) ?? true
        undampedOn = try c.decodeIfPresent(Bool.self, forKey: .undampedOn) ?? true
        compOn = try c.decodeIfPresent(Bool.self, forKey: .compOn) ?? false
        compAmount = try c.decodeIfPresent(Float.self, forKey: .compAmount) ?? 0.45
        compFast = try c.decodeIfPresent(Bool.self, forKey: .compFast) ?? false
        octaveShift = try c.decodeIfPresent(Int32.self, forKey: .octaveShift) ?? 0
        originalEnvelope = try c.decodeIfPresent(Bool.self, forKey: .originalEnvelope) ?? true
        attackMs = try c.decodeIfPresent(Float.self, forKey: .attackMs) ?? 1.0
        releaseMs = try c.decodeIfPresent(Float.self, forKey: .releaseMs) ?? 600.0
    }
}

struct MasterMemoryPreset: Codable, Equatable, Sendable {
    var masterGainDb: Double = 0.0
    var masterPan: Double = 0.0
    var baseTuningHz: Double = 440.0
    var fineTuneCents: Double = 0.0
    var transposeSemitones: Double = 0.0
    var globalVelocityCurve: Double = 0.0
    var releaseScalePercent: Double = 100.0
    var releaseNoisePercent: Double = 100.0

    var eqBassDb: Double = 0.0
    var eqMidDb: Double = 0.0
    var eqMidFreqHz: Double = 1000.0
    var eqTrebleDb: Double = 0.0
    var driveEnabled: Bool = false
    var driveAmountPercent: Double = 25.0

    var mod1Enabled: Bool = false
    var mod1Target: Int32 = 0
    var mod1Wave: Int32 = 0
    var mod1RateHz: Float = 4.5
    var mod1Depth: Float = 0.35

    var mod2Enabled: Bool = false
    var mod2Target: Int32 = 2
    var mod2Wave: Int32 = 0
    var mod2RateHz: Float = 5.5
    var mod2Depth: Float = 0.20

    var delayEnabled: Bool = false
    var delayAmount: Float = 0.25
    var delayFeedback: Float = 0.35
    var delayTimeMs: Float = 360.0
    var delaySyncToHost: Bool = false
    var delayHostBpm: Float = 120.0
    var delaySyncDivision: Int32 = 1
    var delayPingPong: Bool = true

    var reverbEnabled: Bool = true
    var reverbAmount: Float = 0.22
    var reverbSize: Float = 0.65
    var reverbDecay: Float = 0.55
    var reverbDamping: Float = 0.45
    var reverbPreDelayMs: Float = 18.0
}

struct MidiMappingMetadata: Codable, Equatable, Sendable {
    var channel: Int = 0       // 0 = Omni, 1...16 = Channel 1...16
    var isGlobal: Bool = true  // true = Global, false = This Program
}

struct MidiMonitorMessage: Identifiable, Equatable, Sendable {
    let id: Int
    let timeString: String
    let typeString: String
    let channelString: String
    let dataString: String
}

struct ProgramMemoryPreset: Codable, Equatable, Sendable {
    var version: Int = 1
    var name: String = "Init"
    var hasData: Bool = false
    var layers: [LayerMemoryPreset] = [
        LayerMemoryPreset(enabled: true),
        LayerMemoryPreset(enabled: false),
        LayerMemoryPreset(enabled: false),
        LayerMemoryPreset(enabled: false)
    ]
    var master: MasterMemoryPreset = MasterMemoryPreset()
    var programMidiMappings: [String: Int] = [:]
    var programMidiMappingMeta: [String: MidiMappingMetadata] = [:]

    init(
        version: Int = 1,
        name: String = "Init",
        hasData: Bool = false,
        layers: [LayerMemoryPreset] = [
            LayerMemoryPreset(enabled: true),
            LayerMemoryPreset(enabled: false),
            LayerMemoryPreset(enabled: false),
            LayerMemoryPreset(enabled: false)
        ],
        master: MasterMemoryPreset = MasterMemoryPreset(),
        programMidiMappings: [String: Int] = [:],
        programMidiMappingMeta: [String: MidiMappingMetadata] = [:]
    ) {
        self.version = version
        self.name = name
        self.hasData = hasData
        self.layers = layers
        self.master = master
        self.programMidiMappings = programMidiMappings
        self.programMidiMappingMeta = programMidiMappingMeta
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Init"
        hasData = try c.decodeIfPresent(Bool.self, forKey: .hasData) ?? false
        let decodedLayers = try c.decodeIfPresent([LayerMemoryPreset].self, forKey: .layers) ?? []
        if decodedLayers.count == 4 {
            layers = decodedLayers
        } else {
            layers = [
                LayerMemoryPreset(enabled: true),
                LayerMemoryPreset(enabled: false),
                LayerMemoryPreset(enabled: false),
                LayerMemoryPreset(enabled: false)
            ]
        }
        master = try c.decodeIfPresent(MasterMemoryPreset.self, forKey: .master) ?? MasterMemoryPreset()
        programMidiMappings = try c.decodeIfPresent([String: Int].self, forKey: .programMidiMappings) ?? [:]
        programMidiMappingMeta = try c.decodeIfPresent([String: MidiMappingMetadata].self, forKey: .programMidiMappingMeta) ?? [:]
    }
}

enum WorkstationTab: Int, CaseIterable, Identifiable {
    // LAYER tabs
    case timbre = 0
    case keyboard = 1
    // MASTER tabs
    case midiCC = 2
    case eq = 3
    case drive = 4
    case mod = 5
    case delay = 6
    case reverb = 7

    var id: Int { rawValue }

    static let layerTabs: [WorkstationTab] = [.timbre, .keyboard]
    static let masterTabs: [WorkstationTab] = [.midiCC, .eq, .drive, .mod, .delay, .reverb]

    var title: String {
        switch self {
        case .timbre: return L("Sound")
        case .keyboard: return L("Keyboard & Touch")
        case .midiCC: return L("MIDI")
        case .eq: return L("EQ")
        case .drive: return L("Drive")
        case .mod: return L("Mod")
        case .delay: return L("Delay")
        case .reverb: return L("Reverb")
        }
    }

    var icon: String {
        switch self {
        case .timbre: return "waveform"
        case .keyboard: return "pianokeys"
        case .midiCC: return "slider.horizontal.3"
        case .eq: return "slider.vertical.3"
        case .drive: return "bolt.horizontal.circle"
        case .mod: return "waveform.path.ecg"
        case .delay: return "repeat"
        case .reverb: return "wave.3.right"
        }
    }

    /// Tabs that edit the selected layer (A/B/C/D).
    var isPerLayer: Bool { self == .timbre || self == .keyboard }
}

func midiNoteName(_ note: Int) -> String {
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let clamped = min(max(note, 0), 127)
    let name = names[clamped % 12]
    let oct = (clamped / 12) - 1
    return "\(name)\(oct) (\(clamped))"
}

nonisolated func decodeNullTerminatedCString(_ buffer: [CChar]) -> String {
    let prefix = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: prefix, as: UTF8.self)
}

// MARK: - Isolated Real-Time Telemetry Model (60 Hz)
// Isolated from PianoViewModel so playing notes (peakL/R, voices, keys) does NOT rebuild Toolbar, Cards, or Editor.

@MainActor
final class AudioTelemetryModel: ObservableObject {
    @Published var activeVoices: Int = 0
    @Published var sustainDown: Bool = false
    @Published var peakL: Float = 0.0
    @Published var peakR: Float = 0.0
    @Published var clipped: Bool = false
    @Published var keyVelocities: [UInt8] = Array(repeating: 0, count: 128)
}

// MARK: - Main Nord Workstation ViewModel

@MainActor
final class PianoViewModel: ObservableObject {
    nonisolated(unsafe) static weak var shared: PianoViewModel?
    nonisolated(unsafe) private var host: OpaquePointer?
    private var telemetryTimer: Timer?
    nonisolated(unsafe) private var keyMonitorDown: Any?
    nonisolated(unsafe) private var keyMonitorUp: Any?
    private var heldComputerKeys: Set<UInt16> = []

    /// Isolated sub-model for L/R meter, virtual keyboard, and voice counter at 60 Hz.
    let telemetry = AudioTelemetryModel()

    // Universal Knob & Control MIDI Mapping (Right-Click Context Menu, Non-Knob Controls & Mapping Manager)
    @Published var knobMidiMappings: [String: Int] = [:]
    @Published var midiMappingMeta: [String: MidiMappingMetadata] = [:]
    @Published var activeMidiLearnKey: String? = nil
    private var knobSetters: [String: (Double) -> Void] = [:]
    private var knobRanges: [String: ClosedRange<Double>] = [:]
    private var knobSteps: [String: Double] = [:]
    private var lastTriggerCCValues: [Int: Int] = [:]

    // Live 30 Hz MIDI Monitor (last 100 messages) & Debug Manual CC Sender
    @Published var midiMonitorMessages: [MidiMonitorMessage] = []
    @Published var midiMonitorPaused: Bool = false
    private var midiMonitorNextID: Int = 1
    private var telemetryTickCounter: Int = 0
    @Published var showDebugManualCCSheet: Bool = false
    @Published var debugManualCCNumber: Int = 1
    @Published var debugManualCCValue: Double = 64.0

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

    func assignKnobCC(idKey: String, cc: Int, channel: Int? = nil, isGlobal: Bool? = nil) {
        knobMidiMappings[idKey] = cc
        var meta = midiMappingMeta[idKey] ?? MidiMappingMetadata()
        if let ch = channel { meta.channel = ch }
        if let gl = isGlobal { meta.isGlobal = gl }
        midiMappingMeta[idKey] = meta
        if activeMidiLearnKey == idKey {
            activeMidiLearnKey = nil
        }
        persistGlobalMidiMappings()
        if !meta.isGlobal {
            markProgramEditedAndAutosave()
        }
    }

    func unassignKnobCC(idKey: String) {
        let wasGlobal = midiMappingMeta[idKey]?.isGlobal ?? true
        knobMidiMappings.removeValue(forKey: idKey)
        midiMappingMeta.removeValue(forKey: idKey)
        if activeMidiLearnKey == idKey {
            activeMidiLearnKey = nil
        }
        persistGlobalMidiMappings()
        if !wasGlobal {
            markProgramEditedAndAutosave()
        }
    }

    func clearAllMidiMappings() {
        knobMidiMappings.removeAll()
        midiMappingMeta.removeAll()
        activeMidiLearnKey = nil
        if let h = host {
            npno_host_cancel_midi_learn(h)
        }
        for l in 0..<4 {
            updateLayerParams(l) {
                $0.ccVolume = -1
                $0.ccFilter = -1
                $0.ccFxaAmount = -1
                $0.ccFxaRelease = -1
            }
        }
        persistGlobalMidiMappings()
        markProgramEditedAndAutosave()
    }

    func setMappingChannel(idKey: String, channel: Int) {
        var meta = midiMappingMeta[idKey] ?? MidiMappingMetadata()
        meta.channel = min(max(0, channel), 16)
        midiMappingMeta[idKey] = meta
        persistGlobalMidiMappings()
        if !meta.isGlobal {
            markProgramEditedAndAutosave()
        }
    }

    func setMappingScope(idKey: String, isGlobal: Bool) {
        var meta = midiMappingMeta[idKey] ?? MidiMappingMetadata()
        meta.isGlobal = isGlobal
        midiMappingMeta[idKey] = meta
        persistGlobalMidiMappings()
        markProgramEditedAndAutosave()
    }

    private struct GlobalMappingsStorage: Codable {
        var mappings: [String: Int]
        var meta: [String: MidiMappingMetadata]
    }

    private func persistGlobalMidiMappings() {
        var globalMap: [String: Int] = [:]
        var globalMeta: [String: MidiMappingMetadata] = [:]
        for (k, cc) in knobMidiMappings {
            let m = midiMappingMeta[k] ?? MidiMappingMetadata()
            if m.isGlobal {
                globalMap[k] = cc
                globalMeta[k] = m
            }
        }
        if let data = try? JSONEncoder().encode(GlobalMappingsStorage(mappings: globalMap, meta: globalMeta)) {
            UserDefaults.standard.set(data, forKey: "ElectroPiano_GlobalMidiMappings_JSON")
        }
    }

    private func restoreGlobalMidiMappings() {
        guard let data = UserDefaults.standard.data(forKey: "ElectroPiano_GlobalMidiMappings_JSON"),
              let decoded = try? JSONDecoder().decode(GlobalMappingsStorage.self, from: data) else {
            return
        }
        for (k, cc) in decoded.mappings {
            knobMidiMappings[k] = cc
            midiMappingMeta[k] = decoded.meta[k] ?? MidiMappingMetadata(channel: 0, isGlobal: true)
        }
    }

    func clearMidiMonitor() {
        midiMonitorMessages.removeAll()
    }

    func sendDebugManualCC(cc: Int, value: Int) {
        guard let h = host else { return }
        npno_host_send_midi_cc(h, Int32(cc), Int32(value), 1)
    }

    func handleIncomingProgramChange(program: Int, channel: Int) {
        guard respondToProgramChange else { return }
        if midiChannel > 0 && channel > 0 && channel != midiChannel {
            return
        }
        if (0...7).contains(program) {
            let targetSlot = program + 1
            if selectedMemorySlot != targetSlot {
                recallMemory(slot: targetSlot)
            }
        }
    }

    func handleIncomingMidiCC(cc: Int, value: Int, channel: Int = 1) {
        if let learnKey = activeMidiLearnKey {
            knobMidiMappings[learnKey] = cc
            if midiMappingMeta[learnKey] == nil {
                midiMappingMeta[learnKey] = MidiMappingMetadata(channel: 0, isGlobal: true)
            }
            activeMidiLearnKey = nil
            persistGlobalMidiMappings()
            return
        }

        let prevVal = lastTriggerCCValues[cc] ?? 0
        lastTriggerCCValues[cc] = value
        let risingEdge = (value >= 64 && prevVal < 64)
        let norm = Double(value) / 127.0

        for (idKey, mappedCC) in knobMidiMappings where mappedCC == cc {
            let meta = midiMappingMeta[idKey] ?? MidiMappingMetadata()
            if meta.channel > 0 && channel > 0 && meta.channel != channel {
                continue
            }

            // 1. Non-knob switches & actions (Layer A-D switches, Prev/Next Program, Transpose ±, Panic)
            if idKey.hasPrefix("switch_L"),
               let layerIdx = Int(idKey.dropFirst("switch_L".count)),
               (0..<4).contains(layerIdx) {
                if risingEdge {
                    let cur = layers[layerIdx].params.enabled
                    updateLayerParams(layerIdx) { $0.enabled = !cur }
                }
                continue
            }
            if idKey == "action_prev_prog" {
                if risingEdge {
                    let prevSlot = ((selectedMemorySlot - 2 + 8) % 8) + 1
                    recallMemory(slot: prevSlot)
                }
                continue
            }
            if idKey == "action_next_prog" {
                if risingEdge {
                    let nextSlot = (selectedMemorySlot % 8) + 1
                    recallMemory(slot: nextSlot)
                }
                continue
            }
            if idKey == "action_transpose_down" {
                if risingEdge {
                    let cur = Int(transposeSemitones.rounded())
                    transposeSemitones = Double(max(-12, cur - 1))
                }
                continue
            }
            if idKey == "action_transpose_up" {
                if risingEdge {
                    let cur = Int(transposeSemitones.rounded())
                    transposeSemitones = Double(min(12, cur + 1))
                }
                continue
            }
            if idKey == "action_panic" {
                if risingEdge {
                    panic()
                }
                continue
            }

            // 2. Continuous knobs
            if let range = knobRanges[idKey], let setter = knobSetters[idKey] {
                var next = range.lowerBound + norm * (range.upperBound - range.lowerBound)
                if let st = knobSteps[idKey], st > 0 {
                    next = (next / st).rounded() * st
                }
                setter(next)
            }
        }
    }

    // Selected tab and layer for detailed editing (0=A, 1=B, 2=C, 3=D)
    @Published var selectedTab: WorkstationTab = {
        let saved = UserDefaults.standard.integer(forKey: "ElectroPiano_SelectedTab")
        return WorkstationTab(rawValue: saved) ?? .timbre
    }() {
        didSet {
            UserDefaults.standard.set(selectedTab.rawValue, forKey: "ElectroPiano_SelectedTab")
            if selectedTab.isPerLayer {
                lastLayerTab = selectedTab
            }
        }
    }
    var lastLayerTab: WorkstationTab = .timbre
    @Published var selectedLayer: Int = {
        let saved = UserDefaults.standard.integer(forKey: "ElectroPiano_SelectedLayer")
        return (0..<4).contains(saved) ? saved : 0
    }() {
        didSet {
            UserDefaults.standard.set(selectedLayer, forKey: "ElectroPiano_SelectedLayer")
        }
    }
    @Published var activeLoadingLayer: Int = 0
    @Published var showTuningPopover: Bool = false
    @Published var showRenameProgramPopover: Bool = false
    @Published var renameProgramDraft: String = ""
    // 61-key virtual keyboard at the bottom, open by default
    @Published var showVirtualKeyboard: Bool = {
        if UserDefaults.standard.object(forKey: "ElectroPiano_ShowVirtualKeyboard") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "ElectroPiano_ShowVirtualKeyboard")
    }() {
        didSet {
            UserDefaults.standard.set(showVirtualKeyboard, forKey: "ElectroPiano_ShowVirtualKeyboard")
        }
    }
    @Published var keyVelocities: [UInt8] = Array(repeating: 0, count: 128)
    @Published var errorMessage: String? = nil

    // Accent color (Settings > Appearance)
    @Published var accentOption: AccentOption = {
        let saved = UserDefaults.standard.integer(forKey: "ElectroPiano_AccentOption")
        return AccentOption(rawValue: saved) ?? .nordRed
    }() {
        didSet {
            UserDefaults.standard.set(accentOption.rawValue, forKey: "ElectroPiano_AccentOption")
        }
    }

    // MARK: - 8 Program Slots, Undo/Redo, Modified Indicator & Export/Import (.epprog)
    @Published var selectedMemorySlot: Int = {
        let saved = UserDefaults.standard.integer(forKey: "ElectroPiano_ActiveMemorySlot")
        return (saved >= 1 && saved <= 8) ? saved : 1
    }()
    @Published var memorySlots: [ProgramMemoryPreset] = {
        if let data = UserDefaults.standard.data(forKey: "ElectroPiano_Memories_JSON"),
           var decoded = try? JSONDecoder().decode([ProgramMemoryPreset].self, from: data),
           decoded.count == 8 {
            for i in 0..<decoded.count {
                if decoded[i].name == "Inicial" || decoded[i].name == "Vazio" || decoded[i].name.isEmpty {
                    decoded[i].name = L("Init")
                }
            }
            return decoded
        }
        return Array(repeating: ProgramMemoryPreset(), count: 8)
    }()
    @Published var memoryStatusText: String = "M1: Init"
    @Published var storeConfirmationActive: Bool = false
    @Published var isProgramEdited: Bool = false
    @Published var undoStack: [ProgramMemoryPreset] = []
    @Published var redoStack: [ProgramMemoryPreset] = []
    private var dragUndoBaseline: ProgramMemoryPreset? = nil
    private var isApplyingSnapshot: Bool = false

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func beginParameterInteraction() {
        if dragUndoBaseline == nil {
            dragUndoBaseline = captureCurrentProgramSnapshot()
        }
    }

    func endParameterInteraction() {
        guard let baseline = dragUndoBaseline else { return }
        dragUndoBaseline = nil
        let current = captureCurrentProgramSnapshot()
        if baseline != current {
            undoStack.append(baseline)
            if undoStack.count > 64 {
                undoStack.removeFirst()
            }
            redoStack.removeAll()
            markProgramEditedAndAutosave()
        }
    }

    func recordDiscreteUndoStep() {
        guard !isApplyingSnapshot && dragUndoBaseline == nil else { return }
        let current = captureCurrentProgramSnapshot()
        if undoStack.last != current {
            undoStack.append(current)
            if undoStack.count > 64 {
                undoStack.removeFirst()
            }
            redoStack.removeAll()
        }
    }

    func performUndo() {
        guard let prev = undoStack.popLast() else { return }
        let current = captureCurrentProgramSnapshot()
        redoStack.append(current)
        applyProgramSnapshot(prev, loadSounds: true)
        markProgramEditedAndAutosave()
    }

    func performRedo() {
        guard let next = redoStack.popLast() else { return }
        let current = captureCurrentProgramSnapshot()
        undoStack.append(current)
        applyProgramSnapshot(next, loadSounds: true)
        markProgramEditedAndAutosave()
    }

    func captureCurrentProgramSnapshot() -> ProgramMemoryPreset {
        let slotIdx = min(max(selectedMemorySlot - 1, 0), memorySlots.count - 1)
        var p = ProgramMemoryPreset()
        p.version = 1
        p.hasData = true
        p.name = memorySlots[slotIdx].name
        for i in 0..<4 {
            let s = layers[i]
            let path = !s.path.isEmpty ? s.path : memorySlots[slotIdx].layers[i].path
            p.layers[i] = LayerMemoryPreset(path: path, params: s.params)
        }
        p.master = MasterMemoryPreset(
            masterGainDb: masterGainDb,
            masterPan: masterPan,
            baseTuningHz: baseTuningHz,
            fineTuneCents: fineTuneCents,
            transposeSemitones: transposeSemitones,
            globalVelocityCurve: globalVelocityCurve,
            releaseScalePercent: releaseScalePercent,
            releaseNoisePercent: releaseNoisePercent,
            eqBassDb: eqBassDb,
            eqMidDb: eqMidDb,
            eqMidFreqHz: eqMidFreqHz,
            eqTrebleDb: eqTrebleDb,
            driveEnabled: driveEnabled,
            driveAmountPercent: driveAmountPercent,
            mod1Enabled: mod1.enabled,
            mod1Target: mod1.target,
            mod1Wave: mod1.wave,
            mod1RateHz: mod1.rateHz,
            mod1Depth: mod1.depth,
            mod2Enabled: mod2.enabled,
            mod2Target: mod2.target,
            mod2Wave: mod2.wave,
            mod2RateHz: mod2.rateHz,
            mod2Depth: mod2.depth,
            delayEnabled: delay.enabled,
            delayAmount: delay.amount,
            delayFeedback: delay.feedback,
            delayTimeMs: delay.timeMs,
            delaySyncToHost: delay.syncToHost,
            delayHostBpm: delay.hostBpm,
            delaySyncDivision: delay.syncDivision,
            delayPingPong: delay.pingPong,
            reverbEnabled: reverb.enabled,
            reverbAmount: reverb.amount,
            reverbSize: reverb.size,
            reverbDecay: reverb.decay,
            reverbDamping: reverb.damping,
            reverbPreDelayMs: reverb.preDelayMs
        )
        var progMappings: [String: Int] = [:]
        var progMeta: [String: MidiMappingMetadata] = [:]
        for (k, cc) in knobMidiMappings {
            let meta = midiMappingMeta[k] ?? MidiMappingMetadata()
            if !meta.isGlobal {
                progMappings[k] = cc
                progMeta[k] = meta
            }
        }
        p.programMidiMappings = progMappings
        p.programMidiMappingMeta = progMeta
        return p
    }

    func applyProgramSnapshot(_ p: ProgramMemoryPreset, loadSounds: Bool) {
        let wasApplying = isApplyingSnapshot
        isApplyingSnapshot = true
        defer { isApplyingSnapshot = wasApplying }

        let m = p.master
        masterGainDb = m.masterGainDb
        masterPan = m.masterPan
        baseTuningHz = m.baseTuningHz
        fineTuneCents = m.fineTuneCents
        transposeSemitones = m.transposeSemitones
        globalVelocityCurve = m.globalVelocityCurve
        releaseScalePercent = m.releaseScalePercent
        releaseNoisePercent = m.releaseNoisePercent

        eqBassDb = m.eqBassDb
        eqMidDb = m.eqMidDb
        eqMidFreqHz = m.eqMidFreqHz
        eqTrebleDb = m.eqTrebleDb
        driveEnabled = m.driveEnabled
        driveAmountPercent = m.driveAmountPercent

        var m1 = mod1
        m1.enabled = m.mod1Enabled
        m1.target = m.mod1Target
        m1.wave = m.mod1Wave
        m1.rateHz = m.mod1RateHz
        m1.depth = m.mod1Depth
        mod1 = m1

        var m2 = mod2
        m2.enabled = m.mod2Enabled
        m2.target = m.mod2Target
        m2.wave = m.mod2Wave
        m2.rateHz = m.mod2RateHz
        m2.depth = m.mod2Depth
        mod2 = m2

        var d = delay
        d.enabled = m.delayEnabled
        d.amount = m.delayAmount
        d.feedback = m.delayFeedback
        d.timeMs = m.delayTimeMs
        d.syncToHost = m.delaySyncToHost
        d.hostBpm = m.delayHostBpm
        d.syncDivision = m.delaySyncDivision
        d.pingPong = m.delayPingPong
        delay = d

        var r = reverb
        r.enabled = m.reverbEnabled
        r.amount = m.reverbAmount
        r.size = m.reverbSize
        r.decay = m.reverbDecay
        r.damping = m.reverbDamping
        r.preDelayMs = m.reverbPreDelayMs
        reverb = r

        // Merge global MIDI mappings with this program's per-program MIDI mappings
        var mergedMappings: [String: Int] = [:]
        var mergedMeta: [String: MidiMappingMetadata] = [:]
        for (k, cc) in knobMidiMappings {
            let meta = midiMappingMeta[k] ?? MidiMappingMetadata()
            if meta.isGlobal {
                mergedMappings[k] = cc
                mergedMeta[k] = meta
            }
        }
        for (k, cc) in p.programMidiMappings {
            mergedMappings[k] = cc
            var meta = p.programMidiMappingMeta[k] ?? MidiMappingMetadata(channel: 0, isGlobal: false)
            meta.isGlobal = false
            mergedMeta[k] = meta
        }
        knobMidiMappings = mergedMappings
        midiMappingMeta = mergedMeta

        for i in 0..<4 {
            let lp = p.layers[i]
            if loadSounds && !lp.path.isEmpty {
                if layers[i].path != lp.path || !layers[i].loaded {
                    loadLayerInstrument(layer: i, from: lp.path)
                }
            }
            updateLayerParams(i) { params in
                lp.apply(to: &params)
            }
        }
    }

    func markProgramEditedAndAutosave() {
        guard !isApplyingSnapshot else { return }
        let current = captureCurrentProgramSnapshot()
        let saved = memorySlots[min(max(selectedMemorySlot - 1, 0), memorySlots.count - 1)]
        if saved.hasData {
            isProgramEdited = (current != saved)
        } else {
            isProgramEdited = true
        }
        autosaveWorkingState(snapshot: current)
    }

    private func autosaveWorkingState(snapshot: ProgramMemoryPreset) {
        UserDefaults.standard.set(isProgramEdited, forKey: "ElectroPiano_IsProgramEdited")
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: "ElectroPiano_UnsavedWorkingProgram_JSON")
        }
    }

    private func clearAutosavedWorkingState() {
        isProgramEdited = false
        UserDefaults.standard.set(false, forKey: "ElectroPiano_IsProgramEdited")
        UserDefaults.standard.removeObject(forKey: "ElectroPiano_UnsavedWorkingProgram_JSON")
    }

    func memoryHasData(slot: Int) -> Bool {
        guard (1...8).contains(slot) else { return false }
        return memorySlots[slot - 1].hasData
    }

    func beginRenameCurrentProgram() {
        let idx = min(max(selectedMemorySlot - 1, 0), memorySlots.count - 1)
        let currentName = memorySlots[idx].name
        renameProgramDraft = currentName.isEmpty ? String(localized: "Program \(selectedMemorySlot)", bundle: .module) : currentName
        showRenameProgramPopover = true
    }

    func commitRenameCurrentProgram() {
        let trimmed = renameProgramDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, (1...8).contains(selectedMemorySlot) else {
            showRenameProgramPopover = false
            return
        }
        memorySlots[selectedMemorySlot - 1].name = trimmed
        memorySlots[selectedMemorySlot - 1].hasData = true
        persistMemories()
        memoryStatusText = "M\(selectedMemorySlot): \(trimmed)"
        showRenameProgramPopover = false
    }

    func storeCurrentToMemory(slot: Int) {
        guard (1...8).contains(slot) else { return }
        selectedMemorySlot = slot
        let existingName = memorySlots[slot - 1].hasData ? memorySlots[slot - 1].name : ""
        var p = captureCurrentProgramSnapshot()
        p.hasData = true

        var names: [String] = []
        for i in 0..<4 {
            let s = layers[i]
            if s.loaded && s.params.enabled {
                let short = (s.name as NSString).lastPathComponent.components(separatedBy: ".").first ?? s.name
                names.append(short)
            }
        }

        if !existingName.isEmpty && existingName != L("Init") && existingName != "Init" && existingName != "Inicial" && existingName != "Vazio" {
            p.name = existingName
        } else {
            p.name = names.isEmpty ? L("Init") : names.joined(separator: " + ")
        }
        memorySlots[slot - 1] = p
        persistMemories()
        clearAutosavedWorkingState()

        memoryStatusText = "M\(slot): \(p.name)"
        storeConfirmationActive = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self?.storeConfirmationActive = false
        }
    }

    func recallMemory(slot: Int) {
        guard (1...8).contains(slot) else { return }
        selectedMemorySlot = slot
        UserDefaults.standard.set(slot, forKey: "ElectroPiano_ActiveMemorySlot")
        undoStack.removeAll()
        redoStack.removeAll()
        clearAutosavedWorkingState()

        let p = memorySlots[slot - 1]
        if !p.hasData {
            memoryStatusText = "M\(slot): \(L("Init"))"
            return
        }

        memoryStatusText = "M\(slot): \(p.name)"
        applyProgramSnapshot(p, loadSounds: true)
    }

    func revertToSavedProgram() {
        recallMemory(slot: selectedMemorySlot)
    }

    func copyCurrentProgram(toSlot targetSlot: Int) {
        guard (1...8).contains(targetSlot) else { return }
        var p = captureCurrentProgramSnapshot()
        p.hasData = true
        let curSlotIdx = min(max(selectedMemorySlot - 1, 0), memorySlots.count - 1)
        let curName = memorySlots[curSlotIdx].name
        if !curName.isEmpty {
            p.name = curName
        }
        memorySlots[targetSlot - 1] = p
        persistMemories()
    }

    func exportCurrentProgram() {
        let panel = NSSavePanel()
        panel.title = L("Export Program…")
        let slotIdx = min(max(selectedMemorySlot - 1, 0), memorySlots.count - 1)
        let rawName = memorySlots[slotIdx].name.isEmpty ? "Program \(selectedMemorySlot)" : memorySlots[slotIdx].name
        let safeName = rawName.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safeName).epprog"
        if let ut = UTType(filenameExtension: "epprog") {
            panel.allowedContentTypes = [ut, .json]
        } else {
            panel.allowedContentTypes = [.json]
        }
        if panel.runModal() == .OK, let url = panel.url {
            var snapshot = captureCurrentProgramSnapshot()
            snapshot.version = 1
            snapshot.hasData = true
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func importProgram() {
        let panel = NSOpenPanel()
        panel.title = L("Import Program…")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let ut = UTType(filenameExtension: "epprog") {
            panel.allowedContentTypes = [ut, .json]
        } else {
            panel.allowedContentTypes = [.json]
        }
        if panel.runModal() == .OK, let url = panel.url {
            guard let data = try? Data(contentsOf: url),
                  var preset = try? JSONDecoder().decode(ProgramMemoryPreset.self, from: data) else {
                errorMessage = L("Could not import .epprog file. The file may be corrupted or incompatible.")
                return
            }
            preset.hasData = true
            if preset.name.isEmpty {
                preset.name = (url.deletingPathExtension().lastPathComponent)
            }
            memorySlots[selectedMemorySlot - 1] = preset
            persistMemories()
            clearAutosavedWorkingState()
            applyProgramSnapshot(preset, loadSounds: true)
            memoryStatusText = "M\(selectedMemorySlot): \(preset.name)"
        }
    }

    private func persistMemories() {
        UserDefaults.standard.set(selectedMemorySlot, forKey: "ElectroPiano_ActiveMemorySlot")
        if let encoded = try? JSONEncoder().encode(memorySlots) {
            UserDefaults.standard.set(encoded, forKey: "ElectroPiano_Memories_JSON")
        }
    }

    // UI scale (zoom via View menu: Cmd+, Cmd-, Cmd 0).
    @Published var uiScale: Double = PianoViewModel.initialUIScale() {
        didSet {
            UserDefaults.standard.set(uiScale, forKey: "ElectroPiano_UIScale")
        }
    }

    // 4 independent layers (A, B, C, D)
    @Published var layers: [LayerSlotState] = {
        var arr = Array(repeating: LayerSlotState(), count: 4)
        arr[0].params.enabled = true
        return arr
    }()

    // Real-time telemetry
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
    @Published var midiSources: String = L("No MIDI controller connected")
    @Published var midiSourceCount: Int = 0

    // Audio and MIDI devices
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

    // Global Master Controls
    @Published var fineTuneCents: Double = 0.0 {
        didSet {
            if let h = host { npno_host_set_fine_tune_cents(h, Float(fineTuneCents)) }
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
    }
    @Published var baseTuningHz: Double = 440.0 {
        didSet {
            if let h = host { npno_host_set_base_tuning_hz(h, Float(baseTuningHz)) }
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
    }
    @Published var masterGainDb: Double = 0.0 {
        didSet {
            let lin = Float(pow(10.0, masterGainDb / 20.0))
            if let h = host { npno_host_set_master_gain(h, lin) }
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
    }
    @Published var masterPan: Double = 0.0 { // -100 .. +100
        didSet {
            if let h = host { npno_host_set_master_pan(h, Float(masterPan / 100.0)) }
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
    }
    @Published var transposeSemitones: Double = 0.0 {
        didSet {
            if let h = host { npno_host_set_transpose(h, Int32(transposeSemitones.rounded())) }
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
    }
    @Published var globalVelocityCurve: Double = 0.0 { // -1 = Light, 0 = Normal, +1 = Heavy
        didSet {
            if let h = host { npno_host_set_velocity_curve(h, Int32(globalVelocityCurve.rounded())) }
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
    }
    @Published var releaseScalePercent: Double = 100.0 {
        didSet {
            if let h = host { npno_host_set_release_scale(h, Float(releaseScalePercent / 100.0)) }
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
    }
    @Published var releaseNoisePercent: Double = 100.0 {
        didSet {
            let gain = Float(releaseNoisePercent / 100.0)
            if let h = host {
                npno_host_set_release_sample_gain(h, gain)
                npno_host_set_release_samples_enabled(h, gain > 0.005)
            }
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
    }

    // EQ | Drive + Mod 1 & Mod 2
    @Published var eqBassDb: Double = 0.0 {
        didSet {
            if let h = host { npno_host_set_eq_bass_db(h, Float(eqBassDb)) }
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
    }
    @Published var eqMidDb: Double = 0.0 {
        didSet {
            if let h = host { npno_host_set_eq_mid_db(h, Float(eqMidDb)) }
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
    }
    @Published var eqMidFreqHz: Double = 1000.0 {
        didSet {
            if let h = host { npno_host_set_eq_mid_freq_hz(h, Float(eqMidFreqHz)) }
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
    }
    @Published var eqTrebleDb: Double = 0.0 {
        didSet {
            if let h = host { npno_host_set_eq_treble_db(h, Float(eqTrebleDb)) }
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
    }
    @Published var driveEnabled: Bool = false {
        didSet {
            if let h = host { npno_host_set_drive_enabled(h, driveEnabled) }
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
    }
    @Published var driveAmountPercent: Double = 25.0 {
        didSet {
            if let h = host { npno_host_set_drive_amount(h, Float(driveAmountPercent / 100.0)) }
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
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
        didSet {
            pushModulator(0, mod1)
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
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
        didSet {
            pushModulator(1, mod2)
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
    }

    // Delay & Reverb
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
        didSet {
            pushDelay()
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
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
        didSet {
            pushReverb()
            if dragUndoBaseline == nil { markProgramEditedAndAutosave() }
        }
    }

    // Mac Keyboard (QWERTY) & Demo
    @Published var computerKeyboardEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "ElectroPiano_ComputerKeyboardEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "ElectroPiano_ComputerKeyboardEnabled")
    }() {
        didSet {
            UserDefaults.standard.set(computerKeyboardEnabled, forKey: "ElectroPiano_ComputerKeyboardEnabled")
            if !computerKeyboardEnabled {
                releaseAllComputerNotes()
            }
        }
    }
    @Published var computerBaseOctave: Int = {
        let saved = UserDefaults.standard.integer(forKey: "ElectroPiano_ComputerBaseOctave")
        return (1...6).contains(saved) ? saved : 4
    }() {
        didSet {
            UserDefaults.standard.set(computerBaseOctave, forKey: "ElectroPiano_ComputerBaseOctave")
        }
    }
    @Published var computerVelocity: Int = {
        let saved = UserDefaults.standard.integer(forKey: "ElectroPiano_ComputerVelocity")
        return (16...127).contains(saved) ? saved : 96
    }() {
        didSet {
            UserDefaults.standard.set(computerVelocity, forKey: "ElectroPiano_ComputerVelocity")
        }
    }
    @Published var isPlayingDemo: Bool = false
    private var demoTask: Task<Void, Never>?

    // Audio Buffer Size, Latency & CPU, and MIDI Program Change
    @Published var bufferSize: Int = {
        let saved = UserDefaults.standard.integer(forKey: "ElectroPiano_BufferSize")
        return [32, 64, 128, 256, 512].contains(saved) ? saved : 128
    }() {
        didSet {
            UserDefaults.standard.set(bufferSize, forKey: "ElectroPiano_BufferSize")
            if let h = host {
                _ = npno_host_set_buffer_size(h, Int32(bufferSize))
            }
        }
    }
    @Published var callbackCpuPercent: Double = 0.0
    @Published var underrunCount: Int = 0
    @Published var hostEstimatedLatencyMs: Double = 0.0
    @Published var hostBufferSize: Int = 128
    @Published var hostActiveDeviceName: String = ""
    @Published var audioRouteChangeBanner: String? = nil
    @Published var showAudioHealthPopover: Bool = false
    @Published var isRunningStressTest: Bool = false
    @Published var stressTestStatus: String? = nil
    private var lastRouteChangeSeq: UInt32 = 0
    private var routeBannerTask: Task<Void, Never>?
    private var stressTestTask: Task<Void, Never>?
    nonisolated(unsafe) private var sleepObserver: NSObjectProtocol?
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?

    var estimatedLatencyMs: Double {
        if hostEstimatedLatencyMs > 0.01 { return hostEstimatedLatencyMs }
        let bufMs = (Double(bufferSize) / max(8000.0, sampleRate)) * 1000.0
        return bufMs + 2.6
    }
    var activeAudioDeviceName: String {
        if !hostActiveDeviceName.isEmpty { return hostActiveDeviceName }
        if let match = audioOutputDevices.first(where: { $0.id == selectedAudioDeviceID }) {
            return match.name
        }
        return L("System Default")
    }
    @Published var respondToProgramChange: Bool = {
        if UserDefaults.standard.object(forKey: "ElectroPiano_RespondToProgramChange") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "ElectroPiano_RespondToProgramChange")
    }() {
        didSet {
            UserDefaults.standard.set(respondToProgramChange, forKey: "ElectroPiano_RespondToProgramChange")
        }
    }

    // First-Run & Library Folder Management
    @Published var firstRunCompleted: Bool = UserDefaults.standard.bool(forKey: "ElectroPiano_FirstRunCompleted") {
        didSet {
            UserDefaults.standard.set(firstRunCompleted, forKey: "ElectroPiano_FirstRunCompleted")
        }
    }
    @Published var showFirstRunScreen: Bool = false
    @Published var libraryFolderPath: String = UserDefaults.standard.string(forKey: "ElectroPiano_LibraryFolderPath") ?? "" {
        didSet {
            UserDefaults.standard.set(libraryFolderPath, forKey: "ElectroPiano_LibraryFolderPath")
        }
    }
    @Published var libraryFolderMissing: Bool = false
    @Published var isScanningLibrary: Bool = false
    @Published var scannedFileCount: Int = 0
    @Published var hasCompletedScanInFirstRun: Bool = false
    @Published var purgeOnDemandEnabled: Bool = UserDefaults.standard.bool(forKey: "ElectroPiano_PurgeOnDemand") {
        didSet {
            UserDefaults.standard.set(purgeOnDemandEnabled, forKey: "ElectroPiano_PurgeOnDemand")
            if purgeOnDemandEnabled {
                purgeUnusedMemory()
            }
        }
    }
    private var scanTask: Task<Void, Never>?
    private var securityScopedURL: URL?

    // Sound Browser State (Favorites, Recent, Category & Search)
    @Published var soundBrowserFilter: SoundBrowserFilter = .all
    @Published var soundBrowserSearchText: String = ""
    @Published var favoriteSoundPaths: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ElectroPiano_FavoriteSoundPaths") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(favoriteSoundPaths).sorted(), forKey: "ElectroPiano_FavoriteSoundPaths")
        }
    }
    @Published var recentSoundPaths: [String] = UserDefaults.standard.stringArray(forKey: "ElectroPiano_RecentSoundPaths") ?? [] {
        didSet {
            UserDefaults.standard.set(recentSoundPaths, forKey: "ElectroPiano_RecentSoundPaths")
        }
    }

    func isFavoriteSound(path: String) -> Bool {
        favoriteSoundPaths.contains(path)
    }

    func toggleFavoriteSound(path: String) {
        if favoriteSoundPaths.contains(path) {
            favoriteSoundPaths.remove(path)
        } else {
            favoriteSoundPaths.insert(path)
        }
    }

    func recordRecentSound(path: String) {
        guard !path.isEmpty else { return }
        var updated = recentSoundPaths.filter { $0 != path }
        updated.insert(path, at: 0)
        if updated.count > 15 {
            updated = Array(updated.prefix(15))
        }
        recentSoundPaths = updated
    }

    func filteredBrowserBanks() -> [EmbeddedBankItem] {
        var base: [EmbeddedBankItem]
        switch soundBrowserFilter {
        case .all:
            base = embeddedBanks
        case .favorites:
            base = embeddedBanks.filter { favoriteSoundPaths.contains($0.path) }
        case .recent:
            let map = Dictionary(uniqueKeysWithValues: embeddedBanks.map { ($0.path, $0) })
            base = recentSoundPaths.compactMap { map[$0] }
        case .category(let cat):
            base = embeddedBanks.filter { $0.category == cat }
        }
        let query = soundBrowserSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.category.localizedTitle.localizedCaseInsensitiveContains(query) ||
            $0.formatExtension.localizedCaseInsensitiveContains(query)
        }
    }

    var discoveredCategoryCount: Int {
        Set(embeddedBanks.map(\.category)).count
    }

    var firstGrandBank: EmbeddedBankItem? {
        embeddedBanks.first(where: { $0.category == .grand }) ?? embeddedBanks.first
    }

    private static let keyCodeToSemitone: [UInt16: Int] = [
        0: 0, 13: 1, 1: 2, 14: 3, 2: 4, 3: 5, 17: 6, 5: 7, 16: 8,
        4: 9, 32: 10, 38: 11, 40: 12, 31: 13, 37: 14, 35: 15, 41: 16, 39: 17
    ]

    init() {
        Self.shared = self
        restoreGlobalMidiMappings()
        host = npno_host_create()
        if let h = host {
            _ = npno_host_set_buffer_size(h, Int32(bufferSize))
            _ = npno_host_start_audio(h)
            for l in 0..<4 {
                var lp = NPNOLayerParams()
                npno_host_get_layer_params(h, Int32(l), &lp)
                layers[l].params = lp
            }
            npno_host_set_midi_cc_callback(h, kMidiCCBridgeCallback, nil)
            npno_host_set_midi_event_callback(h, kMidiEventBridgeCallback, nil)
        }
        let wsCenter = NSWorkspace.shared.notificationCenter
        sleepObserver = wsCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handleSystemWillSleep()
            }
        }
        wakeObserver = wsCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handleSystemDidWake()
            }
        }
        restoreSavedLibraryBookmarkIfNeeded()
        if !firstRunCompleted && libraryFolderPath.isEmpty {
            showFirstRunScreen = true
        }
        refreshAudioAndMidiDevices()
        startTelemetryTimer()
        installKeyboardMonitors()
        autoLoadDefaultBank()
    }

    deinit {
        if let down = keyMonitorDown { NSEvent.removeMonitor(down) }
        if let up = keyMonitorUp { NSEvent.removeMonitor(up) }
        let wsCenter = NSWorkspace.shared.notificationCenter
        if let s = sleepObserver { wsCenter.removeObserver(s) }
        if let w = wakeObserver { wsCenter.removeObserver(w) }
        if let h = host {
            npno_host_set_midi_cc_callback(h, nil, nil)
            npno_host_set_midi_event_callback(h, nil, nil)
            npno_host_destroy(h)
        }
    }

    private func handleSystemWillSleep() {
        guard let h = host else { return }
        npno_host_panic(h)
        npno_host_stop_audio(h)
    }

    private func handleSystemDidWake() {
        guard let h = host else { return }
        _ = npno_host_start_audio(h)
        refreshAudioAndMidiDevices()
    }

    func resetClipIndicator() {
        if let h = host { npno_host_reset_clip_indicator(h) }
        telemetry.clipped = false
    }

    func resetUnderrunCount() {
        if let h = host { npno_host_reset_underrun_count(h) }
        underrunCount = 0
    }

    func toggleStressTest() {
        if isRunningStressTest {
            stressTestTask?.cancel()
            stressTestTask = nil
            isRunningStressTest = false
            if let h = host { npno_host_panic(h) }
            stressTestStatus = L("Stress test cancelled.")
            return
        }
        guard let h = host else { return }
        npno_host_reset_underrun_count(h)
        underrunCount = 0
        isRunningStressTest = true
        stressTestStatus = L("Running 60s stress test…")

        stressTestTask = Task { [weak self] in
            guard let self else { return }
            let start = Date()
            var notesLaunched = 0
            while !Task.isCancelled && Date().timeIntervalSince(start) < 60.0 {
                npno_host_sustain(h, true)
                for _ in 0..<8 {
                    let note = Int32.random(in: 28...96)
                    let vel = Float.random(in: 0.35...0.98)
                    npno_host_note_on(h, note, vel)
                    notesLaunched += 1
                    try? await Task.sleep(nanoseconds: 25_000_000)
                    if Task.isCancelled { break }
                    npno_host_note_off(h, note)
                }
                if notesLaunched % 40 == 0 {
                    // Toggle sustain periodically to exercise voice release + pedal dump
                    npno_host_sustain(h, false)
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                let elapsed = Int(Date().timeIntervalSince(start))
                self.stressTestStatus = String(localized: "Stress test: \(elapsed)s / 60s · \(notesLaunched) notes · \(self.underrunCount) underruns", bundle: .module)
            }
            npno_host_sustain(h, false)
            npno_host_panic(h)
            let finalUnderruns = self.underrunCount
            self.isRunningStressTest = false
            self.stressTestStatus = String(localized: "Stress test complete: \(notesLaunched) notes, \(finalUnderruns) underruns.", bundle: .module)
        }
    }

    // MARK: - Parameter Synchronization

    func updateLayerParams(_ layer: Int, _ mutate: (inout NPNOLayerParams) -> Void) {
        guard (0..<4).contains(layer), let h = host else { return }
        if !isApplyingSnapshot && dragUndoBaseline == nil {
            recordDiscreteUndoStep()
        }
        var p = layers[layer].params
        mutate(&p)
        layers[layer].params = p
        npno_host_set_layer_params(h, Int32(layer), &p)
        if !isApplyingSnapshot && dragUndoBaseline == nil {
            markProgramEditedAndAutosave()
        }
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

    // MARK: - Audio and MIDI

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

    // MARK: - Loading .npno / .nsmp4 Sound Banks on Layers A/B/C/D

    @Published var embeddedBanks: [EmbeddedBankItem] = []

    var detectedCategoryCount: Int {
        Set(embeddedBanks.map { $0.category }).count
    }

    var firstGrandSound: EmbeddedBankItem? {
        embeddedBanks.first(where: { $0.category == .grand }) ?? embeddedBanks.first
    }

    var totalLibraryDiskBytes: UInt64 {
        embeddedBanks.reduce(0) { $0 + $1.fileSizeBytes }
    }

    func formatBytes(_ bytes: UInt64) -> String {
        let mib = Double(bytes) / 1048576.0
        if mib >= 1024.0 {
            return String(format: "%.1f GB", mib / 1024.0)
        }
        return String(format: "%.0f MB", mib)
    }

    private func restoreSavedLibraryBookmarkIfNeeded() {
        if let bookmarkData = UserDefaults.standard.data(forKey: "ElectroPiano_LibraryFolderBookmark") {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                libraryFolderPath = resolvedURL.path
                UserDefaults.standard.set(resolvedURL.path, forKey: "ElectroPiano_LibraryFolderPath")
                if isStale, let refreshed = try? resolvedURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(refreshed, forKey: "ElectroPiano_LibraryFolderBookmark")
                }
            }
        }
        if !libraryFolderPath.isEmpty {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: libraryFolderPath, isDirectory: &isDir) && isDir.boolValue
            libraryFolderMissing = !exists
        } else {
            libraryFolderMissing = false
        }
    }

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.title = L("Choose Folder…")
        panel.message = L("Choose the folder that contains your Nord sound libraries (.npno, .nsmp4).")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !libraryFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: libraryFolderPath, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            setLibraryFolder(url: url)
        }
    }

    func setLibraryFolder(url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        libraryFolderPath = url.path
        libraryFolderMissing = false
        UserDefaults.standard.set(url.path, forKey: "ElectroPiano_LibraryFolderPath")
        if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "ElectroPiano_LibraryFolderBookmark")
        }
        rescanLibraryFolder()
    }

    func cancelLibraryScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanningLibrary = false
    }

    func rescanLibraryFolder(autoLoadAfterScan: Bool = false) {
        cancelLibraryScan()
        if !libraryFolderPath.isEmpty {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: libraryFolderPath, isDirectory: &isDir) && isDir.boolValue
            libraryFolderMissing = !exists
            if !exists {
                embeddedBanks = []
                return
            }
        }
        isScanningLibrary = true
        scannedFileCount = 0
        hasCompletedScanInFirstRun = false

        let targetFolder = libraryFolderPath
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            var searchRoots: [String] = []
            if !targetFolder.isEmpty {
                searchRoots = [targetFolder]
            } else {
                let cwd = fm.currentDirectoryPath
                let bundleParent = (Bundle.main.bundlePath as NSString).deletingLastPathComponent
                let resPath = Bundle.main.resourcePath ?? ""
                let homeLib = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Nord Electro Piano/Sounds")
                searchRoots = [
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
            }

            var discoveredPaths: [String] = []
            var seenNames = Set<String>()
            var count = 0

            for root in searchRoots where !root.isEmpty {
                if Task.isCancelled { return }
                let rootURL = URL(fileURLWithPath: root, isDirectory: true)
                if !targetFolder.isEmpty {
                    // Recursive enumerator for configured library folder
                    if let enumerator = fm.enumerator(
                        at: rootURL,
                        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    ) {
                        while let fileURL = enumerator.nextObject() as? URL {
                            if Task.isCancelled { return }
                            let fileName = fileURL.lastPathComponent
                            let lower = fileName.lowercased()
                            if lower.hasSuffix(".npno") || lower.hasSuffix(".nsmp4") {
                                if !seenNames.contains(fileName) {
                                    seenNames.insert(fileName)
                                    discoveredPaths.append(fileURL.path)
                                    count += 1
                                    let currentCount = count
                                    await MainActor.run { [weak self] in
                                        self?.scannedFileCount = currentCount
                                    }
                                }
                            }
                        }
                    }
                } else {
                    guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
                    for itemName in items.sorted() {
                        if Task.isCancelled { return }
                        let fullPath = (root as NSString).appendingPathComponent(itemName)
                        var isDir: ObjCBool = false
                        if fm.fileExists(atPath: fullPath, isDirectory: &isDir) {
                            if isDir.boolValue {
                                if let subItems = try? fm.contentsOfDirectory(atPath: fullPath) {
                                    for sub in subItems.sorted() {
                                        let lower = sub.lowercased()
                                        if (lower.hasSuffix(".npno") || lower.hasSuffix(".nsmp4")) && !seenNames.contains(sub) {
                                            seenNames.insert(sub)
                                            discoveredPaths.append((fullPath as NSString).appendingPathComponent(sub))
                                            count += 1
                                        }
                                    }
                                }
                            } else {
                                let lower = itemName.lowercased()
                                if (lower.hasSuffix(".npno") || lower.hasSuffix(".nsmp4")) && !seenNames.contains(itemName) {
                                    seenNames.insert(itemName)
                                    discoveredPaths.append(fullPath)
                                    count += 1
                                }
                            }
                        }
                    }
                }
            }

            if Task.isCancelled { return }
            let sortedPaths = discoveredPaths.sorted {
                (($0 as NSString).lastPathComponent).localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending
            }
            var finalItems: [EmbeddedBankItem] = []
            for (idx, fullPath) in sortedPaths.enumerated() {
                let fileName = (fullPath as NSString).lastPathComponent
                let display = (fileName as NSString).deletingPathExtension
                let ext = ((fileName as NSString).pathExtension).lowercased()
                let attrs = try? fm.attributesOfItem(atPath: fullPath)
                let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
                finalItems.append(
                    EmbeddedBankItem(
                        index: idx + 1,
                        name: display,
                        path: fullPath,
                        formatExtension: ext.isEmpty ? ".npno" : ".\(ext)",
                        fileSizeBytes: size,
                        category: SoundCategory.infer(fileName: fileName, fullPath: fullPath)
                    )
                )
            }

            let itemsToPublish = finalItems
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.embeddedBanks = itemsToPublish
                self.scannedFileCount = itemsToPublish.count
                self.isScanningLibrary = false
                self.hasCompletedScanInFirstRun = true

                if autoLoadAfterScan && !self.showFirstRunScreen {
                    self.performInitialSoundLoadIfNeeded()
                }
            }
        }
    }

    func skipFirstRun() {
        cancelLibraryScan()
        firstRunCompleted = true
        showFirstRunScreen = false
    }

    func finishFirstRun(loadFirstGrand: Bool) {
        firstRunCompleted = true
        showFirstRunScreen = false
        if loadFirstGrand, let sound = firstGrandSound {
            loadLayerInstrument(layer: 0, from: sound.path)
        }
    }

    func showLibraryInFinder() {
        guard !libraryFolderPath.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: libraryFolderPath)
    }

    private func autoLoadDefaultBank() {
        rescanLibraryFolder(autoLoadAfterScan: true)
    }

    private func performInitialSoundLoadIfNeeded() {
        if UserDefaults.standard.bool(forKey: "ElectroPiano_IsProgramEdited"),
           let data = UserDefaults.standard.data(forKey: "ElectroPiano_UnsavedWorkingProgram_JSON"),
           let working = try? JSONDecoder().decode(ProgramMemoryPreset.self, from: data) {
            applyProgramSnapshot(working, loadSounds: true)
            isProgramEdited = true
            return
        }

        if memorySlots[selectedMemorySlot - 1].hasData {
            recallMemory(slot: selectedMemorySlot)
            return
        }
        if layers[0].loaded || layers[0].isLoading { return }

        if let astoria = embeddedBanks.first(where: { $0.name.lowercased().contains("astoria") }) {
            loadLayerInstrument(layer: 0, from: astoria.path)
            return
        }
        if let first = firstGrandSound {
            loadLayerInstrument(layer: 0, from: first.path)
            return
        }
    }

    func openFilePicker(forLayer layer: Int) {
        let panel = NSOpenPanel()
        let layerNames = ["A", "B", "C", "D"]
        let lName = (0..<4).contains(layer) ? layerNames[layer] : "A"
        panel.title = String(localized: "Select .npno / .nsmp4 sound for Layer \(lName)", bundle: .module)
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

    func cancelLayerLoad(layer: Int) {
        guard (0..<4).contains(layer) else { return }
        layers[layer].loadGeneration &+= 1
        layers[layer].isLoading = false
        layers[layer].loadProgress = 0.0
    }

    func dismissLayerLoadError(layer: Int) {
        guard (0..<4).contains(layer) else { return }
        layers[layer].loadError = nil
    }

    func locateMissingSound(forLayer layer: Int) {
        openFilePicker(forLayer: layer)
    }

    private func availableSystemMemoryMB() -> Int {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        }
        let pageSize = UInt64(getpagesize())
        let freeOrPurgeable = UInt64(vmStats.free_count + vmStats.inactive_count + vmStats.purgeable_count) * pageSize
        return max(128, Int(freeOrPurgeable / 1_048_576))
    }

    func loadLayerInstrument(layer: Int, from path: String) {
        guard (0..<4).contains(layer), let h = host else { return }
        let fileName = (path as NSString).lastPathComponent
        let fm = FileManager.default

        // 1. Check if file exists
        guard fm.fileExists(atPath: path) else {
            layers[layer].isLoading = false
            layers[layer].loadError = .missingFile(fileName: fileName.isEmpty ? path : fileName, originalPath: path)
            return
        }

        // 2. Check supported format (.npno / .nsmp4)
        let lower = fileName.lowercased()
        guard lower.hasSuffix(".npno") || lower.hasSuffix(".nsmp4") else {
            layers[layer].isLoading = false
            layers[layer].loadError = .unsupportedFormat
            return
        }

        // 3. Check available RAM when Purge on Demand is off
        if !purgeOnDemandEnabled,
           let attrs = try? fm.attributesOfItem(atPath: path),
           let fileSize = (attrs[.size] as? NSNumber)?.uint64Value {
            let neededMB = max(1, Int((fileSize * 3) / 1_048_576))
            let availMB = availableSystemMemoryMB()
            if neededMB > availMB {
                layers[layer].isLoading = false
                layers[layer].loadError = .insufficientRAM(fileName: fileName, neededMB: neededMB, availableMB: availMB)
                return
            }
        }

        layers[layer].loadGeneration &+= 1
        let gen = layers[layer].loadGeneration
        activeLoadingLayer = layer
        layers[layer].isLoading = true
        layers[layer].loadProgress = 0.0
        layers[layer].loadError = nil
        errorMessage = nil

        let hAddr = Int(bitPattern: h)
        Self.performBackgroundLoad(viewModel: self, hostAddress: hAddr, layer: layer, path: path, generation: gen)
    }

    nonisolated private static func performBackgroundLoad(
        viewModel: PianoViewModel,
        hostAddress: Int,
        layer: Int,
        path: String,
        generation: Int
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak viewModel] in
            guard let hostPtr = OpaquePointer(bitPattern: hostAddress) else { return }
            var errBuf = [CChar](repeating: 0, count: 512)
            let progressCB = loadProgressCallback(forLayer: layer)
            let ok = npno_host_load_layer_instrument(
                hostPtr,
                Int32(layer),
                path,
                progressCB,
                nil,
                &errBuf,
                Int32(errBuf.count)
            )
            let errText = decodeNullTerminatedCString(errBuf)
            let fileName = (path as NSString).lastPathComponent
            Task { @MainActor [weak viewModel] in
                guard let vm = viewModel else { return }
                guard vm.layers[layer].loadGeneration == generation else { return }
                vm.layers[layer].isLoading = false
                if ok {
                    vm.layers[layer].loadError = nil
                    vm.refreshLayerInfo(layer)
                    vm.recordRecentSound(path: path)
                    if vm.purgeOnDemandEnabled {
                        vm.purgeUnusedMemory()
                    }
                } else {
                    if errText.lowercased().contains("unsupported") || errText.lowercased().contains("header") {
                        vm.layers[layer].loadError = .corrupted(fileName: fileName)
                    } else {
                        vm.layers[layer].loadError = .corrupted(fileName: fileName)
                    }
                }
            }
        }
    }

    func stepLayerInstrument(layer: Int, delta: Int) {
        guard (0..<4).contains(layer), let h = host, !layers[layer].isLoading else { return }
        let candidateBanks = filteredBrowserBanks().isEmpty ? embeddedBanks : filteredBrowserBanks()
        if !candidateBanks.isEmpty {
            let currentPath = layers[layer].path
            if let curIdx = candidateBanks.firstIndex(where: { $0.path == currentPath }) {
                let nextIdx = ((curIdx + delta) % candidateBanks.count + candidateBanks.count) % candidateBanks.count
                loadLayerInstrument(layer: layer, from: candidateBanks[nextIdx].path)
            } else {
                let idx = ((layer + max(0, delta)) % candidateBanks.count + candidateBanks.count) % candidateBanks.count
                loadLayerInstrument(layer: layer, from: candidateBanks[idx].path)
            }
            return
        }
        if !layers[layer].loaded && !layers[0].loaded {
            openFilePicker(forLayer: layer)
            return
        }
        layers[layer].loadGeneration &+= 1
        let gen = layers[layer].loadGeneration
        activeLoadingLayer = layer
        layers[layer].isLoading = true
        layers[layer].loadProgress = 0.0
        layers[layer].loadError = nil

        let hAddr = Int(bitPattern: h)
        Self.performBackgroundStep(viewModel: self, hostAddress: hAddr, layer: layer, delta: delta, generation: gen)
    }

    nonisolated private static func performBackgroundStep(
        viewModel: PianoViewModel,
        hostAddress: Int,
        layer: Int,
        delta: Int,
        generation: Int
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak viewModel] in
            guard let hostPtr = OpaquePointer(bitPattern: hostAddress) else { return }
            var errBuf = [CChar](repeating: 0, count: 512)
            let progressCB = loadProgressCallback(forLayer: layer)
            let ok = npno_host_step_layer_instrument(
                hostPtr,
                Int32(layer),
                Int32(delta),
                progressCB,
                nil,
                &errBuf,
                Int32(errBuf.count)
            )
            Task { @MainActor [weak viewModel] in
                guard let vm = viewModel else { return }
                guard vm.layers[layer].loadGeneration == generation else { return }
                vm.layers[layer].isLoading = false
                if ok {
                    vm.layers[layer].loadError = nil
                    vm.refreshLayerInfo(layer)
                    vm.recordRecentSound(path: vm.layers[layer].path)
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
        guard info.loaded else {
            layers[layer].name = L("No Sound")
            return
        }

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

    // UI polling timer at ~60 Hz on MainActor (drains CCs and telemetry without creating Tasks per MIDI event)
    private func showAudioRouteBanner(deviceName: String) {
        routeBannerTask?.cancel()
        audioRouteChangeBanner = String(localized: "Output changed to \(deviceName)", bundle: .module)
        routeBannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.audioRouteChangeBanner = nil
        }
    }

    private func startTelemetryTimer() {
        telemetryTimer = Self.makeTelemetryTimer(for: self)
    }

    nonisolated private static func makeTelemetryTimer(for viewModel: PianoViewModel) -> Timer {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak viewModel] _ in
            MainActor.assumeIsolated {
                viewModel?.pollTelemetry()
            }
        }
    }

    private static func formatMidiTimestamp(_ cfaTime: TimeInterval) -> String {
        let date = Date(timeIntervalSinceReferenceDate: cfaTime)
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let h = comps.hour ?? 0
        let m = comps.minute ?? 0
        let s = comps.second ?? 0
        let ms = (comps.nanosecond ?? 0) / 1_000_000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    private static func ccDescription(_ cc: Int) -> String {
        switch cc {
        case 1: return L("Mod Wheel")
        case 7: return L("Channel Volume")
        case 10: return L("Pan")
        case 11: return L("Expression")
        case 64: return L("Sustain Pedal")
        case 66: return L("Sostenuto Pedal")
        case 67: return L("Soft / Una Corda")
        case 71: return L("Resonance")
        case 74: return L("Cutoff")
        default: return ""
        }
    }

    private func pollTelemetry() {
        guard let h = host else { return }

        var hadCCTraffic = false
        telemetryTickCounter &+= 1

        // 1. Drain continuous MIDI CC stream, Program Change, and load progress from lock-free/unfair_lock bridge
        if let snap = RealtimeMIDIBridge.shared.drain() {
            if snap.loadMask != 0 {
                let progresses = [snap.loadProgress.0, snap.loadProgress.1, snap.loadProgress.2, snap.loadProgress.3]
                for l in 0..<4 where (snap.loadMask & (UInt8(1) << UInt8(l))) != 0 {
                    if layers[l].isLoading {
                        layers[l].loadProgress = progresses[l]
                    }
                }
            }

            if snap.latestProgramChange >= 0 {
                handleIncomingProgramChange(
                    program: Int(snap.latestProgramChange),
                    channel: Int(snap.latestProgramChangeChannel)
                )
            }

            if snap.lowMask != 0 || snap.highMask != 0 || snap.latestLearnCC >= 0 {
                hadCCTraffic = true
            }

            if activeMidiLearnKey != nil, snap.latestLearnCC >= 0 {
                let ccIdx = Int(snap.latestLearnCC)
                handleIncomingMidiCC(
                    cc: ccIdx,
                    value: Int(snap.values[ccIdx]),
                    channel: Int(snap.latestLearnChannel)
                )
            } else {
                if snap.lowMask != 0 {
                    for cc in 0..<64 where (snap.lowMask & (UInt64(1) << UInt64(cc))) != 0 {
                        handleIncomingMidiCC(cc: cc, value: Int(snap.values[cc]), channel: Int(snap.channels[cc]))
                    }
                }
                if snap.highMask != 0 {
                    for bit in 0..<64 where (snap.highMask & (UInt64(1) << UInt64(bit))) != 0 {
                        let cc = bit + 64
                        handleIncomingMidiCC(cc: cc, value: Int(snap.values[cc]), channel: Int(snap.channels[cc]))
                    }
                }
            }
        }

        // 1b. Drain lock-free MIDI Monitor ring buffer at 30 Hz (every 2nd 60 Hz tick)
        if (telemetryTickCounter & 1) == 0 {
            let rawEvents = RealtimeMIDIBridge.shared.drainEvents()
            if !rawEvents.isEmpty && !midiMonitorPaused {
                for ev in rawEvents {
                    let timeStr = Self.formatMidiTimestamp(ev.timestamp)
                    let chStr = String(localized: "Ch \(ev.channel)", bundle: .module)
                    let typeStr: String
                    let dataStr: String

                    switch ev.statusType {
                    case 0x90:
                        typeStr = L("Note On")
                        dataStr = "\(midiNoteName(Int(ev.data1)))  •  Vel \(ev.data2)"
                    case 0x80:
                        typeStr = L("Note Off")
                        dataStr = "\(midiNoteName(Int(ev.data1)))  •  Vel 0"
                    case 0xB0:
                        typeStr = L("Control Change")
                        let desc = Self.ccDescription(Int(ev.data1))
                        if desc.isEmpty {
                            dataStr = "CC \(ev.data1)  •  Val \(ev.data2)"
                        } else {
                            dataStr = "CC \(ev.data1) (\(desc))  •  Val \(ev.data2)"
                        }
                    case 0xC0:
                        typeStr = L("Program Change")
                        let pc = Int(ev.data1)
                        if (0...7).contains(pc) {
                            dataStr = String(localized: "PC \(pc) → Program \(pc + 1)", bundle: .module)
                        } else {
                            dataStr = "PC \(pc)"
                        }
                    case 0xE0:
                        typeStr = L("Pitch Bend")
                        let raw14 = (Int(ev.data2) << 7) | Int(ev.data1)
                        let centered = raw14 - 8192
                        dataStr = String(format: "%+d", centered)
                    default:
                        typeStr = String(format: "0x%02X", ev.statusType)
                        dataStr = "\(ev.data1), \(ev.data2)"
                    }

                    let msg = MidiMonitorMessage(
                        id: midiMonitorNextID,
                        timeString: timeStr,
                        typeString: typeStr,
                        channelString: chStr,
                        dataString: dataStr
                    )
                    midiMonitorNextID &+= 1
                    midiMonitorMessages.insert(msg, at: 0)
                }
                if midiMonitorMessages.count > 100 {
                    midiMonitorMessages.removeLast(midiMonitorMessages.count - 100)
                }
            }
        }

        // 2. C++ engine telemetry (L/R meter, voices, sustain, active keys) -> updates ONLY `telemetry`
        var tel = NPNOTelemetry()
        npno_host_get_telemetry(h, &tel)

        let newActiveVoices = Int(tel.activeVoices)
        if telemetry.activeVoices != newActiveVoices { telemetry.activeVoices = newActiveVoices }
        if telemetry.sustainDown != tel.sustainDown { telemetry.sustainDown = tel.sustainDown }
        if abs(telemetry.peakL - tel.peakL) > 0.001 || (tel.peakL == 0 && telemetry.peakL != 0) {
            telemetry.peakL = tel.peakL
        }
        if abs(telemetry.peakR - tel.peakR) > 0.001 || (tel.peakR == 0 && telemetry.peakR != 0) {
            telemetry.peakR = tel.peakR
        }

        withUnsafePointer(to: &tel.keyVelocities) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 128) { buf in
                var changed = false
                for i in 0..<128 where telemetry.keyVelocities[i] != buf[i] {
                    changed = true
                    break
                }
                if changed {
                    var copy = [UInt8](repeating: 0, count: 128)
                    for i in 0..<128 { copy[i] = buf[i] }
                    telemetry.keyVelocities = copy
                }
            }
        }

        // 3. Low-frequency events in PianoViewModel (RAM, Layer MIDI Learn, MIDI devices)
        if totalMemoryBytes != tel.totalMemoryBytes { totalMemoryBytes = tel.totalMemoryBytes }
        if totalUnpurgedBytes != tel.totalUnpurgedBytes { totalUnpurgedBytes = tel.totalUnpurgedBytes }

        let newLearnLayer = Int(tel.midiLearnLayer)
        let newLearnSlot = Int(tel.midiLearnSlot)
        let learnChanged = (midiLearnLayer != newLearnLayer) || (midiLearnSlot != newLearnSlot)
        if midiLearnLayer != newLearnLayer { midiLearnLayer = newLearnLayer }
        if midiLearnSlot != newLearnSlot { midiLearnSlot = newLearnSlot }

        if abs(sampleRate - tel.sampleRate) > 0.1 { sampleRate = tel.sampleRate }
        if telemetry.clipped != tel.clipped { telemetry.clipped = tel.clipped }
        if abs(callbackCpuPercent - Double(tel.callbackCpuPercent)) > 0.1 {
            callbackCpuPercent = Double(tel.callbackCpuPercent)
        }
        let newUnderruns = Int(tel.underrunCount)
        if underrunCount != newUnderruns { underrunCount = newUnderruns }
        if tel.bufferSize > 0 && hostBufferSize != Int(tel.bufferSize) {
            hostBufferSize = Int(tel.bufferSize)
        }
        if tel.estimatedLatencyMs > 0.01 && abs(hostEstimatedLatencyMs - Double(tel.estimatedLatencyMs)) > 0.05 {
            hostEstimatedLatencyMs = Double(tel.estimatedLatencyMs)
        }
        let rawDevName = withUnsafePointer(to: &tel.activeAudioDeviceName) {
            $0.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
        }
        if !rawDevName.isEmpty && hostActiveDeviceName != rawDevName {
            hostActiveDeviceName = rawDevName
        }
        if tel.audioRouteChangeSeq != lastRouteChangeSeq {
            let hadPrevious = lastRouteChangeSeq != 0 || !hostActiveDeviceName.isEmpty
            lastRouteChangeSeq = tel.audioRouteChangeSeq
            if hadPrevious && !rawDevName.isEmpty {
                refreshAudioAndMidiDevices()
                showAudioRouteBanner(deviceName: rawDevName)
            }
        }

        let newMidiCount = Int(tel.midiSourceCount)
        if midiSourceCount != newMidiCount { midiSourceCount = newMidiCount }
        let rawSources = withUnsafePointer(to: &tel.midiSources) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
        }
        let cleanSources = (newMidiCount == 0 || rawSources.contains("Nenhum") || rawSources.contains("No MIDI"))
            ? L("No MIDI controller connected")
            : rawSources
        if midiSources != cleanSources { midiSources = cleanSources }

        // Synchronize layer parameters with C++ ONLY when there was CC traffic or MIDI Learn finished
        if hadCCTraffic || learnChanged {
            for l in 0..<4 {
                var lp = NPNOLayerParams()
                npno_host_get_layer_params(h, Int32(l), &lp)
                let cur = layers[l].params
                if abs(cur.volume - lp.volume) > 0.0005 ||
                   abs(cur.filter - lp.filter) > 0.0005 ||
                   abs(cur.fxaAmount - lp.fxaAmount) > 0.0005 ||
                   abs(cur.fxaRelease - lp.fxaRelease) > 0.0005 ||
                   cur.ccVolume != lp.ccVolume ||
                   cur.ccFilter != lp.ccFilter ||
                   cur.ccFxaAmount != lp.ccFxaAmount ||
                   cur.ccFxaRelease != lp.ccFxaRelease {
                    layers[l].params = lp
                }
            }
        }
    }

    // MARK: - Note Triggering and Controls

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

    // MARK: - Mac Keyboard (QWERTY)

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
        guard computerKeyboardEnabled else { return false }
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
        guard computerKeyboardEnabled else { return false }
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

// MARK: - Native Settings Scene (Cmd+,)

struct ElectroProSettingsView: View {
    @ObservedObject var vm: PianoViewModel

    var body: some View {
        TabView {
            Tab(L("Audio"), systemImage: "speaker.wave.3.fill") {
                audioSettingsTab
            }

            Tab(L("MIDI"), systemImage: "pianokeys") {
                midiSettingsTab
            }

            Tab(L("Keyboard"), systemImage: "keyboard") {
                keyboardSettingsTab
            }

            Tab(L("Library"), systemImage: "folder.fill") {
                librarySettingsTab
            }

            Tab(L("Appearance"), systemImage: "paintpalette.fill") {
                appearanceSettingsTab
            }
        }
        .frame(width: 580, height: 420)
        .preferredColorScheme(.dark)
        .onAppear {
            vm.refreshAudioAndMidiDevices()
        }
    }

    // Tab 1: Audio
    private var audioSettingsTab: some View {
        Form {
            Section(L("Audio Output (Core Audio)")) {
                Picker(L("Output Device"), selection: $vm.selectedAudioDeviceID) {
                    ForEach(vm.audioOutputDevices) { dev in
                        Text(verbatim: dev.name).tag(dev.id)
                    }
                }

                LabeledContent(L("Sample Rate")) {
                    Text(String(localized: "\(String(format: "%.1f", vm.sampleRate / 1000.0)) kHz • 32-bit Float Stereo", bundle: .module))
                        .font(StudioTokens.fontValue)
                        .foregroundStyle(StudioTokens.textSecondary)
                }

                Picker(L("Buffer Size"), selection: $vm.bufferSize) {
                    Text(verbatim: "64 samples").tag(64)
                    Text(verbatim: "128 samples").tag(128)
                    Text(verbatim: "256 samples").tag(256)
                    Text(verbatim: "512 samples").tag(512)
                    Text(verbatim: "1024 samples").tag(1024)
                }

                LabeledContent(L("Estimated Latency")) {
                    Text(verbatim: String(format: "%.1f ms", vm.estimatedLatencyMs))
                        .font(StudioTokens.fontValue)
                        .foregroundStyle(StudioTokens.textSecondary)
                }

                Picker(L("Maximum Polyphony"), selection: $vm.maxVoices) {
                    Text(L("64 Voices")).tag(64)
                    Text(L("128 Voices")).tag(128)
                    Text(L("256 Voices (Default)")).tag(256)
                    Text(L("512 Voices")).tag(512)
                }

                LabeledContent(L("Callback CPU")) {
                    Text(verbatim: String(format: "%.1f%%", vm.callbackCpuPercent))
                        .font(StudioTokens.fontValue)
                        .foregroundStyle(StudioTokens.textSecondary)
                }

                HStack {
                    Button {
                        vm.refreshAudioAndMidiDevices()
                    } label: {
                        Label(L("Refresh Devices"), systemImage: "arrow.clockwise")
                    }

                    Spacer()

                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
                    } label: {
                        Label(L("Open Audio MIDI Setup…"), systemImage: "slider.horizontal.below.rectangle")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // Tab 2: MIDI
    private var midiSettingsTab: some View {
        Form {
            Section(L("Global MIDI Receive")) {
                Picker(L("Receive Channel"), selection: $vm.midiChannel) {
                    Text(L("Omni (All Channels 1–16)")).tag(0)
                    Divider()
                    ForEach(1...16, id: \.self) { ch in
                        Text(String(localized: "Channel \(ch)", bundle: .module)).tag(ch)
                    }
                }

                Toggle(L("Respond to Program Change"), isOn: $vm.respondToProgramChange)
            }

            Section {
                if vm.midiInputDevices.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "pianokeys")
                            .font(.system(size: 18))
                            .foregroundStyle(StudioTokens.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("No MIDI controller connected"))
                                .font(StudioTokens.fontBodyMedium)
                                .foregroundStyle(StudioTokens.textPrimary)
                            Text(L("Connect a USB or DIN MIDI controller and click Rescan."))
                                .font(StudioTokens.fontLabel)
                                .foregroundStyle(StudioTokens.textSecondary)
                        }
                        Spacer()
                        Button {
                            vm.refreshAudioAndMidiDevices()
                        } label: {
                            Label(L("Rescan"), systemImage: "arrow.clockwise")
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
                            Label(L("Rescan"), systemImage: "arrow.clockwise")
                        }
                    }
                }
            } header: {
                Text(L("MIDI Controllers"))
            }
        }
        .formStyle(.grouped)
    }

    // Tab 3: Keyboard (QWERTY)
    private var keyboardSettingsTab: some View {
        Form {
            Section(L("Mac Keyboard (QWERTY)")) {
                Toggle(L("Enable Mac Keyboard Input"), isOn: $vm.computerKeyboardEnabled)

                Stepper(
                    String(localized: "Base Octave: C\(vm.computerBaseOctave)", bundle: .module),
                    value: $vm.computerBaseOctave,
                    in: 1...6
                )
                .disabled(!vm.computerKeyboardEnabled)

                Stepper(
                    String(localized: "Velocity: \(vm.computerVelocity)", bundle: .module),
                    value: $vm.computerVelocity,
                    in: 16...127,
                    step: 8
                )
                .disabled(!vm.computerKeyboardEnabled)

                Toggle(L("Show 61-Key On-Screen Keyboard (⌘K)"), isOn: $vm.showVirtualKeyboard)
            }

            Section(L("Quick Playing Shortcuts")) {
                LabeledContent(L("White Keys")) {
                    Text(verbatim: "A S D F G H J K L ;")
                        .font(StudioTokens.fontValue)
                }
                LabeledContent(L("Black Keys")) {
                    Text(verbatim: "W E   T Y U   O P")
                        .font(StudioTokens.fontValue)
                }
                LabeledContent(L("Octave − / + & Velocity − / +")) {
                    Text(verbatim: "Z / X  •  C / V")
                        .font(StudioTokens.fontValue)
                }
                LabeledContent(L("Sustain Pedal")) {
                    Text(L("Spacebar"))
                        .font(StudioTokens.fontValue)
                }
            }
        }
        .formStyle(.grouped)
    }

    // Tab 4: Library
    private var librarySettingsTab: some View {
        Form {
            Section(L("Library")) {
                LabeledContent(L("Library Folder")) {
                    Text(verbatim: vm.libraryFolderPath.isEmpty ? L("Default Bundle / Application Support") : vm.libraryFolderPath)
                        .font(StudioTokens.fontLabel)
                        .foregroundStyle(vm.libraryFolderMissing ? StudioTokens.meterRed : StudioTokens.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if vm.libraryFolderMissing {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(StudioTokens.meterRed)
                        Text(L("Library folder not found"))
                            .font(StudioTokens.fontLabel)
                            .foregroundStyle(StudioTokens.meterRed)
                        Spacer()
                        Button(L("Locate…")) {
                            vm.chooseLibraryFolder()
                        }
                    }
                }

                LabeledContent(L("Sounds Found")) {
                    if vm.isScanningLibrary {
                        Text(String(localized: "Scanning… \(vm.scannedFileCount) files", bundle: .module))
                            .font(StudioTokens.fontValue)
                            .foregroundStyle(StudioTokens.textSecondary)
                    } else {
                        Text(String(localized: "\(vm.embeddedBanks.count) sounds • \(vm.formatBytes(vm.totalLibraryDiskBytes))", bundle: .module))
                            .font(StudioTokens.fontValue)
                            .foregroundStyle(StudioTokens.textSecondary)
                    }
                }

                Toggle(L("Purge on Demand"), isOn: $vm.purgeOnDemandEnabled)

                HStack(spacing: 10) {
                    Button {
                        vm.chooseLibraryFolder()
                    } label: {
                        Label(L("Choose Folder…"), systemImage: "folder.badge.gearshape")
                    }

                    Button {
                        vm.rescanLibraryFolder()
                    } label: {
                        Label(L("Rescan"), systemImage: "arrow.clockwise")
                    }
                    .disabled(vm.isScanningLibrary)

                    Spacer()

                    Button {
                        vm.showLibraryInFinder()
                    } label: {
                        Label(L("Show in Finder"), systemImage: "finder")
                    }
                    .disabled(vm.libraryFolderPath.isEmpty || vm.libraryFolderMissing)
                }

                HStack {
                    Button {
                        vm.firstRunCompleted = false
                        vm.showFirstRunScreen = true
                    } label: {
                        Text(L("Show Welcome Setup Screen…"))
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    // Tab 5: Appearance
    private var appearanceSettingsTab: some View {
        Form {
            Section(L("Accent Color")) {
                Picker(L("Interface Accent Color"), selection: $vm.accentOption) {
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

                Text(L("The accent color highlights only knob value arcs, the selected layer, and the meter peak."))
                    .font(StudioTokens.fontLabel)
                    .foregroundStyle(StudioTokens.textSecondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - App Entry Point (macOS 26 Tahoe)

@main
struct ElectroPianoApp: App {
    @StateObject private var viewModel = PianoViewModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup(L("Electro Pro")) {
            ContentView(vm: viewModel)
        }
        .defaultSize(width: 1200, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            // File Menu
            CommandGroup(replacing: .newItem) {
                Button(L("Load Sound into Selected Layer…")) {
                    viewModel.openFilePicker(forLayer: viewModel.selectedLayer)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button(L("Load Sound into Layer A…")) {
                    viewModel.openFilePicker(forLayer: 0)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button(L("Load Sound into Layer B…")) {
                    viewModel.openFilePicker(forLayer: 1)
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button(L("Load Sound into Layer C…")) {
                    viewModel.openFilePicker(forLayer: 2)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button(L("Load Sound into Layer D…")) {
                    viewModel.openFilePicker(forLayer: 3)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button(String(localized: "Save to Current Program (M\(viewModel.selectedMemorySlot))", bundle: .module)) {
                    viewModel.storeCurrentToMemory(slot: viewModel.selectedMemorySlot)
                }
                .keyboardShortcut("s", modifiers: [.command])

                Button(L("Revert to Saved")) {
                    viewModel.revertToSavedProgram()
                }
                .disabled(!viewModel.isProgramEdited)

                Button(L("Rename Program…")) {
                    viewModel.beginRenameCurrentProgram()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Menu(L("Copy Program To…")) {
                    ForEach(1...8, id: \.self) { slot in
                        let slotName = viewModel.memorySlots[slot - 1].name
                        Button(String(localized: "Program \(slot) — \(slotName)", bundle: .module)) {
                            viewModel.copyCurrentProgram(toSlot: slot)
                        }
                        .disabled(slot == viewModel.selectedMemorySlot)
                    }
                }

                Divider()

                Button(L("Export Program…")) {
                    viewModel.exportCurrentProgram()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button(L("Import Program…")) {
                    viewModel.importProgram()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Divider()

                Button(L("Purge Unused Samples from RAM")) {
                    viewModel.purgeUnusedMemory()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button(L("Reload Purged Samples")) {
                    viewModel.reloadPurgedMemory()
                }
            }

            // Edit Menu (Undo / Redo + Reset + Panic)
            CommandGroup(replacing: .undoRedo) {
                Button(L("Undo")) {
                    viewModel.performUndo()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!viewModel.canUndo)

                Button(L("Redo")) {
                    viewModel.performRedo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!viewModel.canRedo)
            }

            CommandGroup(after: .pasteboard) {
                Divider()
                Button(L("Reset Equalizer (Flat 0 dB)")) {
                    viewModel.resetEq()
                }
                if viewModel.activeMidiLearnKey != nil || viewModel.midiLearnLayer >= 0 {
                    Button(L("Cancel MIDI Learn")) {
                        viewModel.activeMidiLearnKey = nil
                        viewModel.toggleMidiLearn(layer: viewModel.midiLearnLayer, slot: viewModel.midiLearnSlot)
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
                Button(L("Panic — All Notes Off")) {
                    viewModel.panic()
                }
                .keyboardShortcut(".", modifiers: [.command])
            }

            // View Menu (Tabs, Layers, On-Screen Keyboard, and Zoom on Cmd +/−)
            CommandGroup(after: .toolbar) {
                Button(viewModel.showVirtualKeyboard ? L("Hide On-Screen Keyboard (61 Keys)") : L("Show On-Screen Keyboard (61 Keys)")) {
                    viewModel.showVirtualKeyboard.toggle()
                }
                .keyboardShortcut("k", modifiers: [.command])

                Divider()

                ForEach(WorkstationTab.allCases) { tab in
                    Button(String(localized: "Tab: \(tab.title)", bundle: .module)) {
                        viewModel.selectedTab = tab
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(tab.rawValue + 1)")), modifiers: [.command])
                }

                Divider()

                ForEach(0..<4, id: \.self) { layer in
                    Button(String(localized: "Select Layer \(kLayerLetters[layer])", bundle: .module)) {
                        viewModel.selectedLayer = layer
                        if !viewModel.selectedTab.isPerLayer {
                            viewModel.selectedTab = viewModel.lastLayerTab
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(layer + 1)")), modifiers: [.option])
                }

                Divider()

                Button(L("Zoom In")) {
                    viewModel.zoomIn()
                }
                .keyboardShortcut("=", modifiers: [.command])

                Button(L("Zoom Out")) {
                    viewModel.zoomOut()
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button(L("Actual Size (100%)")) {
                    viewModel.zoomToFitScreen()
                }
                .keyboardShortcut("0", modifiers: [.command])
            }

            #if DEBUG
            CommandMenu(L("Debug")) {
                Button(L("Manual CC Sender…")) {
                    viewModel.showDebugManualCCSheet = true
                }
                Button(viewModel.isRunningStressTest ? L("Stop Stress Test") : L("Stress Test (60s)…")) {
                    viewModel.toggleStressTest()
                }
            }
            #endif
        }

        // Native Settings Window (Cmd+,)
        Settings {
            ElectroProSettingsView(vm: viewModel)
        }
    }
}
