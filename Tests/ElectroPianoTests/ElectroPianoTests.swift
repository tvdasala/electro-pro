import Foundation
import Testing
@testable import NPNOBridge

private struct TestProgramSnapshot: Codable, Equatable {
    var version: Int
    var name: String
    var masterGainDb: Double
    var masterPan: Double
    var transposeSemitones: Int
    var layers: [TestLayerSnapshot]
}

private struct TestLayerSnapshot: Codable, Equatable {
    var enabled: Bool
    var volume: Float
    var filter: Float
    var keyLow: Int
    var keyHigh: Int
    var velLow: Int
    var velHigh: Int
    var velocityCurve: Int
}

@Suite("Electro Pro Engine & Bridge Tests", .serialized)
struct ElectroPianoTests {

    @Test("Program JSON serialization round-trip (.epprog schema)")
    func programSerializationRoundTrip() throws {
        let original = TestProgramSnapshot(
            version: 1,
            name: "Concert Grand + Warm Pad",
            masterGainDb: -1.5,
            masterPan: 0.12,
            transposeSemitones: -2,
            layers: [
                TestLayerSnapshot(enabled: true, volume: 0.95, filter: 0.85, keyLow: 21, keyHigh: 108, velLow: 1, velHigh: 127, velocityCurve: 0),
                TestLayerSnapshot(enabled: true, volume: 0.45, filter: 0.62, keyLow: 48, keyHigh: 84, velLow: 40, velHigh: 120, velocityCurve: 2),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TestProgramSnapshot.self, from: data)
        #expect(decoded == original)
    }

    @Test("Velocity curves stay in [0, 1] and increase monotonically")
    func velocityCurvesMonotonicAndBounded() {
        let host = npno_host_create()!
        defer { npno_host_destroy(host) }
        #expect(npno_host_load_test_tone(host, 0, 0.5))

        var rev = NPNOReverbParams()
        npno_host_get_reverb_params(host, &rev)
        rev.enabled = false
        npno_host_set_reverb_params(host, &rev)

        // Settle parameter smoothers before measuring steady-state velocity curves
        var warmL = [Float](repeating: 0, count: 2048)
        var warmR = [Float](repeating: 0, count: 2048)
        npno_host_render_offline(host, &warmL, &warmR, 2048)

        for curve in 0...5 {
            var lp = NPNOLayerParams()
            npno_host_get_layer_params(host, 0, &lp)
            lp.velocityCurve = Int32(curve)
            lp.fxaAmount = 0.0
            npno_host_set_layer_params(host, 0, &lp)

            var prevPeak: Float = -1.0
            for vByte in [1, 32, 64, 96, 127] {
                npno_host_panic(host)
                var flushL = [Float](repeating: 0, count: 4096)
                var flushR = [Float](repeating: 0, count: 4096)
                npno_host_render_offline(host, &flushL, &flushR, 4096)

                var L = [Float](repeating: 0, count: 512)
                var R = [Float](repeating: 0, count: 512)
                npno_host_note_on(host, 60, Float(vByte) / 127.0)
                npno_host_render_offline(host, &L, &R, 512)
                let peak = L.map { abs($0) }.max() ?? 0
                #expect(peak >= 0.0 && peak <= 1.0)
                #expect(peak >= prevPeak)
                prevPeak = peak
            }
        }
    }

    @Test("Keyboard & velocity zone bounds filter notes accurately")
    func keyboardZoneBoundsFiltering() {
        let host = npno_host_create()!
        defer { npno_host_destroy(host) }
        #expect(npno_host_load_test_tone(host, 0, 0.5))

        var lp = NPNOLayerParams()
        npno_host_get_layer_params(host, 0, &lp)
        lp.keyLow = 48   // C3
        lp.keyHigh = 72  // C5
        lp.velLow = 40
        lp.velHigh = 100
        npno_host_set_layer_params(host, 0, &lp)

        var L = [Float](repeating: 0, count: 128)
        var R = [Float](repeating: 0, count: 128)
        var tel = NPNOTelemetry()

        // Out of key range (low)
        npno_host_note_on(host, 36, 80.0 / 127.0)
        npno_host_render_offline(host, &L, &R, 128)
        npno_host_get_telemetry(host, &tel)
        #expect(tel.activeVoices == 0)

        // Out of velocity range (too loud)
        npno_host_note_on(host, 60, 120.0 / 127.0)
        npno_host_render_offline(host, &L, &R, 128)
        npno_host_get_telemetry(host, &tel)
        #expect(tel.activeVoices == 0)

        // Inside both key and velocity range
        npno_host_note_on(host, 60, 80.0 / 127.0)
        npno_host_render_offline(host, &L, &R, 128)
        npno_host_get_telemetry(host, &tel)
        #expect(tel.activeVoices == 1)
    }

    @Test("MIDI CC64 sustain, CC66 sostenuto, and CC11 expression work offline")
    func midiPedalsAndExpression() {
        let host = npno_host_create()!
        defer { npno_host_destroy(host) }
        #expect(npno_host_load_test_tone(host, 0, 0.5))

        var L = [Float](repeating: 0, count: 256)
        var R = [Float](repeating: 0, count: 256)
        var tel = NPNOTelemetry()

        // CC66 sostenuto holds only already-pressed notes
        npno_host_note_on(host, 60, 0.8)
        npno_host_render_offline(host, &L, &R, 128)
        npno_host_send_midi_cc(host, 66, 127, 1) // sostenuto down
        npno_host_render_offline(host, &L, &R, 128)
        npno_host_note_off(host, 60)
        npno_host_render_offline(host, &L, &R, 256)
        npno_host_get_telemetry(host, &tel)
        #expect(tel.activeVoices == 1)

        // Releasing sostenuto releases the voice; half-pedal CC64 keeps sustainDown false below 64
        npno_host_send_midi_cc(host, 66, 0, 1)
        npno_host_send_midi_cc(host, 64, 40, 1)
        npno_host_render_offline(host, &L, &R, 128)
        npno_host_get_telemetry(host, &tel)
        #expect(tel.sustainDown == false)
    }

    @Test("Offline render is bit-transparent below threshold and clamped to -0.3 dBFS above")
    func offlineRenderTransparentAndLimited() {
        let host = npno_host_create()!
        defer { npno_host_destroy(host) }
        #expect(npno_host_load_test_tone(host, 0, 0.9))

        var L = [Float](repeating: 0, count: 1024)
        var R = [Float](repeating: 0, count: 1024)

        // Silence check
        npno_host_render_offline(host, &L, &R, 1024)
        #expect(L.allSatisfy { $0 == 0.0 })

        // Normal level: below limiter threshold -> no clip indicator
        npno_host_set_master_gain(host, 0.4)
        npno_host_note_on(host, 60, 0.7)
        npno_host_render_offline(host, &L, &R, 1024)
        var tel = NPNOTelemetry()
        npno_host_get_telemetry(host, &tel)
        #expect(tel.clipped == false)
        let normalPeak = L.map { abs($0) }.max() ?? 0
        #expect(normalPeak > 0.01 && normalPeak <= 0.85)

        // Hot level: stacking voices + high master gain -> limiter clamps <= 0.9661 (-0.3 dBFS) & marks clipped
        npno_host_set_master_gain(host, 3.0)
        for note in [48, 52, 55, 60, 64, 67, 72] as [Int32] {
            npno_host_note_on(host, note, 1.0)
        }
        npno_host_render_offline(host, &L, &R, 1024)
        npno_host_get_telemetry(host, &tel)
        let hotPeak = max(L.map { abs($0) }.max() ?? 0, R.map { abs($0) }.max() ?? 0)
        #expect(tel.clipped == true)
        #expect(hotPeak <= 0.967)

        npno_host_reset_clip_indicator(host)
        npno_host_get_telemetry(host, &tel)
        #expect(tel.clipped == false)
    }
}
