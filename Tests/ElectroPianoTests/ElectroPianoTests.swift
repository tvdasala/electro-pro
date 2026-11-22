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

    @Test("CC64 full sustain (64 and 127) holds voices without premature damping")
    func cc64FullSustainHoldsSteady() {
        let host = npno_host_create()!
        defer { npno_host_destroy(host) }
        #expect(npno_host_load_test_tone(host, 0, 0.5))

        var rev = NPNOReverbParams()
        npno_host_get_reverb_params(host, &rev)
        rev.enabled = false
        npno_host_set_reverb_params(host, &rev)

        var lp = NPNOLayerParams()
        npno_host_get_layer_params(host, 0, &lp)
        lp.fxaAmount = 0.0
        npno_host_set_layer_params(host, 0, &lp)

        var L = [Float](repeating: 0, count: 48000)
        var R = [Float](repeating: 0, count: 48000)
        var tel = NPNOTelemetry()

        // Settle initial parameter smoothers before measuring steady-state sustain amplitude
        npno_host_render_offline(host, &L, &R, 4096)

        for ccVal in [64, 127] as [Int32] {
            npno_host_panic(host)
            npno_host_render_offline(host, &L, &R, 512)

            npno_host_send_midi_cc(host, 64, ccVal, 1)
            npno_host_note_on(host, 60, 0.85)
            npno_host_render_offline(host, &L, &R, 1024)
            let initialPeak = L[512..<1024].map { abs($0) }.max() ?? 0
            #expect(initialPeak > 0.05)

            npno_host_note_off(host, 60)

            // Render 2 seconds (96000 frames @ 48 kHz) while CC64 is held
            npno_host_render_offline(host, &L, &R, 48000)
            npno_host_render_offline(host, &L, &R, 48000)
            let heldPeak = L[47000..<48000].map { abs($0) }.max() ?? 0
            npno_host_get_telemetry(host, &tel)

            #expect(tel.sustainDown == true)
            #expect(tel.activeVoices == 1)
            #expect(heldPeak > initialPeak * 0.95)

            // Releasing sustain pedal decays and finishes the voice cleanly
            npno_host_send_midi_cc(host, 64, 0, 1)
            npno_host_render_offline(host, &L, &R, 48000)
            npno_host_get_telemetry(host, &tel)
            let tailPeak = L[47000..<48000].map { abs($0) }.max() ?? 0
            #expect(tel.sustainDown == false)
            #expect(tel.activeVoices == 0)
            #expect(tailPeak < 1.0e-4)
        }
    }

    @Test("CC123 All Notes Off respects CC64 sustain; CC120 All Sound Off silences")
    func cc123RespectsSustainAndCC120Silences() {
        let host = npno_host_create()!
        defer { npno_host_destroy(host) }
        #expect(npno_host_load_test_tone(host, 0, 0.5))

        var rev = NPNOReverbParams()
        npno_host_get_reverb_params(host, &rev)
        rev.enabled = false
        npno_host_set_reverb_params(host, &rev)

        var lp = NPNOLayerParams()
        npno_host_get_layer_params(host, 0, &lp)
        lp.fxaAmount = 0.0
        npno_host_set_layer_params(host, 0, &lp)

        var L = [Float](repeating: 0, count: 48000)
        var R = [Float](repeating: 0, count: 48000)
        var tel = NPNOTelemetry()

        npno_host_send_midi_cc(host, 64, 127, 1)
        npno_host_note_on(host, 60, 0.8)
        npno_host_render_offline(host, &L, &R, 1024)

        // CC123 releases held keys into sustain without killing sustained voices
        npno_host_send_midi_cc(host, 123, 0, 1)
        npno_host_render_offline(host, &L, &R, 24000)
        npno_host_get_telemetry(host, &tel)
        let peakAfterCC123 = L[23000..<24000].map { abs($0) }.max() ?? 0
        #expect(tel.sustainDown == true)
        #expect(tel.activeVoices == 1)
        #expect(peakAfterCC123 > 0.05)

        // Releasing CC64 now lets the voice decay to silence
        npno_host_send_midi_cc(host, 64, 0, 1)
        npno_host_render_offline(host, &L, &R, 48000)
        npno_host_get_telemetry(host, &tel)
        #expect(tel.activeVoices == 0)

        // CC120 All Sound Off silences even with sustain held
        npno_host_send_midi_cc(host, 64, 127, 1)
        npno_host_note_on(host, 60, 0.8)
        npno_host_render_offline(host, &L, &R, 1024)
        npno_host_send_midi_cc(host, 120, 0, 1)
        npno_host_render_offline(host, &L, &R, 2048)
        npno_host_get_telemetry(host, &tel)
        let peakAfterCC120 = L[1500..<2048].map { abs($0) }.max() ?? 0
        #expect(tel.activeVoices == 0)
        #expect(peakAfterCC120 < 1.0e-4)
    }

    @Test("Syncopated re-pedaling catches releasing voices")
    func syncopatedRepedalCatchesReleasingVoice() {
        let host = npno_host_create()!
        defer { npno_host_destroy(host) }
        #expect(npno_host_load_test_tone(host, 0, 0.5))

        var rev = NPNOReverbParams()
        npno_host_get_reverb_params(host, &rev)
        rev.enabled = false
        npno_host_set_reverb_params(host, &rev)

        var L = [Float](repeating: 0, count: 48000)
        var R = [Float](repeating: 0, count: 48000)
        var tel = NPNOTelemetry()

        npno_host_note_on(host, 60, 0.85)
        npno_host_render_offline(host, &L, &R, 512)
        npno_host_note_off(host, 60)
        // Render 30 ms (~1440 frames) so voice is actively releasing
        npno_host_render_offline(host, &L, &R, 1440)

        // Depress sustain pedal to catch the releasing voice
        npno_host_send_midi_cc(host, 64, 127, 1)
        npno_host_render_offline(host, &L, &R, 48000)
        npno_host_render_offline(host, &L, &R, 48000)
        npno_host_get_telemetry(host, &tel)

        let heldPeak = L[47000..<48000].map { abs($0) }.max() ?? 0
        #expect(tel.activeVoices == 1)
        #expect(heldPeak > 0.01)
    }

    @Test("Cross-channel CC64 isolation preserves Layer A sustain")
    func crossChannelCC64Isolation() {
        let host = npno_host_create()!
        defer { npno_host_destroy(host) }
        #expect(npno_host_load_test_tone(host, 0, 0.5))

        var lp = NPNOLayerParams()
        npno_host_get_layer_params(host, 0, &lp)
        lp.midiChannel = 1
        npno_host_set_layer_params(host, 0, &lp)

        var L = [Float](repeating: 0, count: 48000)
        var R = [Float](repeating: 0, count: 48000)
        var tel = NPNOTelemetry()

        npno_host_send_midi_cc(host, 64, 127, 1)
        npno_host_note_on(host, 60, 0.8)
        npno_host_render_offline(host, &L, &R, 512)
        npno_host_note_off(host, 60)

        // Releasing CC64 on channel 2 must not drop Layer A (channel 1) sustain
        npno_host_send_midi_cc(host, 64, 0, 2)
        npno_host_render_offline(host, &L, &R, 48000)
        npno_host_get_telemetry(host, &tel)
        let ch1Peak = L[47000..<48000].map { abs($0) }.max() ?? 0
        #expect(tel.activeVoices == 1)
        #expect(ch1Peak > 0.05)

        // Releasing CC64 on channel 1 releases Layer A
        npno_host_send_midi_cc(host, 64, 0, 1)
        npno_host_render_offline(host, &L, &R, 48000)
        npno_host_get_telemetry(host, &tel)
        #expect(tel.activeVoices == 0)
    }

    @Test("Voice stealing preserves held keys under sustain pressure")
    func voiceStealingPreservesHeldKeys() {
        let host = npno_host_create()!
        defer { npno_host_destroy(host) }
        #expect(npno_host_load_test_tone(host, 0, 0.4))

        var rev = NPNOReverbParams()
        npno_host_get_reverb_params(host, &rev)
        rev.enabled = false
        npno_host_set_reverb_params(host, &rev)

        npno_host_set_max_voices(host, 16)
        var L = [Float](repeating: 0, count: 2048)
        var R = [Float](repeating: 0, count: 2048)
        var tel = NPNOTelemetry()

        // Hold key 60 physically while pressing & releasing 24 other notes under sustain
        npno_host_send_midi_cc(host, 64, 127, 1)
        npno_host_note_on(host, 60, 0.8)
        npno_host_render_offline(host, &L, &R, 512)
        #expect(L[0..<512].allSatisfy { $0.isFinite })

        for n in 40...64 where n != 60 {
            npno_host_note_on(host, Int32(n), 0.7)
            npno_host_render_offline(host, &L, &R, 256)
            #expect(L[0..<256].allSatisfy { $0.isFinite })
            #expect(R[0..<256].allSatisfy { $0.isFinite })
            npno_host_note_off(host, Int32(n))
        }

        npno_host_get_telemetry(host, &tel)
        #expect(tel.activeVoices == 16)

        // Release sustain pedal and wait for sustained notes to finish; held key 60 must survive!
        npno_host_send_midi_cc(host, 64, 0, 1)
        var longL = [Float](repeating: 0, count: 48000)
        var longR = [Float](repeating: 0, count: 48000)
        npno_host_render_offline(host, &longL, &longR, 48000)
        npno_host_get_telemetry(host, &tel)
        let heldPeak = longL[47000..<48000].map { abs($0) }.max() ?? 0
        #expect(longL.allSatisfy { $0.isFinite } && longR.allSatisfy { $0.isFinite })
        #expect(tel.activeVoices == 1)
        #expect(heldPeak > 0.03)
    }
}
