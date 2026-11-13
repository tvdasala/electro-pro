// Ponte C pura entre o núcleo C++20 (NPNOKit + CoreAudio + CoreMIDI) e a interface SwiftUI.
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NPNOHost NPNOHost;

typedef struct NPNOInstrumentInfo {
    char name[64];
    char model[64];
    char path[512];
    char summary[256];
    uint32_t fileVersion;
    uint16_t channels;
    uint32_t recordCount;
    uint32_t normalSampleCount;
    uint32_t releaseSampleCount;
    uint32_t residentSampleCount;
    uint64_t decodedBytes;
    uint64_t totalDecodedBytes;
    int32_t lowestNote;
    int32_t highestNote;
    int32_t damperBoundary;
    int32_t extendedEdgeKeys;
    int32_t bankIndex;
    int32_t bankCount;
    bool loaded;
} NPNOInstrumentInfo;

typedef struct NPNOLayerParams {
    // Seção 2: Camadas A/B/C/D
    bool enabled;
    float volume;      // 0.0 .. 1.5
    float filter;      // 0.0 .. 1.0
    float fxaAmount;   // 0.0 .. 1.0
    float fxaRelease;  // 0.0 .. 1.0

    // Seção 3: Advanced (por camada)
    int32_t ccVolume;      // -1 = OFF, 0..127
    int32_t ccFilter;
    int32_t ccFxaAmount;
    int32_t ccFxaRelease;
    int32_t keyLow;        // 0 .. 127
    int32_t keyHigh;       // 0 .. 127
    int32_t velLow;        // 1 .. 127
    int32_t velHigh;       // 1 .. 127
    int32_t midiChannel;   // 0 = Global/Omni, 1..16
    int32_t velocityCurve; // 0=Main, 1=Soft, 2=Linear, 3=Hard, 4=Exp, 5=Log
    int32_t pitchBendDown; // -24 .. 0
    int32_t pitchBendUp;   // 0 .. +24
    bool portamentoOn;
    float portamentoTimeMs;
    bool fixedVelocity;
    int32_t fixedVelocityValue;
    bool legatoMono;

    // Seção 5: Timbre (por camada)
    int32_t timbreMode;    // 0=Mid, 1=Bright, 2=Soft, 3=Dyno1, 4=Dyno2
    bool sustainPedalOn;
    bool undampedOn;
    bool compOn;
    float compAmount;
    bool compFast;
    int32_t octaveShift;   // -3 .. +3
    bool originalEnvelope;
    float attackMs;
    float releaseMs;
} NPNOLayerParams;

typedef struct NPNOModulatorParams {
    bool enabled;
    int32_t target; // 0=Volume, 1=Filter, 2=Pitch, 3=Pan
    int32_t wave;   // 0=Sine, 1=Triangle, 2=Saw, 3=Square, 4=Envelope
    float rateHz;
    float depth;
} NPNOModulatorParams;

typedef struct NPNODelayParams {
    bool enabled;
    float amount;
    float feedback;
    float timeMs;
    bool syncToHost;
    float hostBpm;
    int32_t syncDivision; // 0=1/4, 1=1/8, 2=1/8D, 3=1/8T, 4=1/16
    bool pingPong;
} NPNODelayParams;

typedef struct NPNOReverbParams {
    bool enabled;
    float amount;
    float size;
    float decay;
    float damping;
    float preDelayMs;
} NPNOReverbParams;

typedef struct NPNOTelemetry {
    int32_t activeVoices;
    int32_t maxVoices;
    int32_t layerActiveVoices[4];
    uint64_t totalMemoryBytes;
    uint64_t totalUnpurgedBytes;
    int32_t midiLearnLayer;
    int32_t midiLearnSlot;
    bool sustainDown;
    float peakL;
    float peakR;
    double sampleRate;
    int32_t midiSourceCount;
    char midiSources[256];
    uint8_t keyVelocities[128];

    // Phase 7: audio reliability telemetry
    bool clipped;                    // persistent clip indicator (cleared by npno_host_reset_clip_indicator)
    float callbackCpuPercent;        // render callback time / buffer duration (EMA, 0..100+)
    uint32_t underrunCount;          // callbacks that overran their deadline + HAL processor overloads
    int32_t bufferSize;              // current I/O buffer size in frames
    float estimatedLatencyMs;        // buffer + device latency + safety offset
    uint32_t audioRouteChangeSeq;    // increments every time the output is rebuilt after a route change
    bool audioRunning;
    char activeAudioDeviceName[128];
} NPNOTelemetry;

NPNOHost* npno_host_create(void);
void npno_host_destroy(NPNOHost* host);

bool npno_host_start_audio(NPNOHost* host);
void npno_host_stop_audio(NPNOHost* host);

/// Clears the persistent clip indicator.
void npno_host_reset_clip_indicator(NPNOHost* host);
/// Requests an I/O buffer size in frames (32..2048). Applied immediately if audio is running.
bool npno_host_set_buffer_size(NPNOHost* host, int32_t buffer_size);
int32_t npno_host_get_buffer_size(NPNOHost* host);
/// Resets the underrun counter (used by the stress test).
void npno_host_reset_underrun_count(NPNOHost* host);

/// Carrega um arquivo .npno na camada `layer` (0=A, 1=B, 2=C, 3=D).
bool npno_host_load_layer_instrument(NPNOHost* host, int32_t layer, const char* path,
                                     void (*progress_cb)(float progress, void* ctx), void* ctx,
                                     char* err_buf, int32_t err_buf_len);

/// Compatibilidade com Camada A (0).
bool npno_host_load_instrument(NPNOHost* host, const char* path,
                               void (*progress_cb)(float progress, void* ctx), void* ctx,
                               char* err_buf, int32_t err_buf_len);

/// Navega PREV (-1) ou NEXT (+1) pelos arquivos .npno disponíveis na pasta da camada.
bool npno_host_step_layer_instrument(NPNOHost* host, int32_t layer, int32_t delta,
                                     void (*progress_cb)(float progress, void* ctx), void* ctx,
                                     char* err_buf, int32_t err_buf_len);

void npno_host_get_layer_instrument_info(NPNOHost* host, int32_t layer, NPNOInstrumentInfo* out_info);
void npno_host_get_instrument_info(NPNOHost* host, NPNOInstrumentInfo* out_info);
void npno_host_get_telemetry(NPNOHost* host, NPNOTelemetry* out_telemetry);

// Parâmetros por Camada (A/B/C/D)
void npno_host_get_layer_params(NPNOHost* host, int32_t layer, NPNOLayerParams* out_params);
void npno_host_set_layer_params(NPNOHost* host, int32_t layer, const NPNOLayerParams* params);

// MIDI Learn
void npno_host_start_midi_learn(NPNOHost* host, int32_t layer, int32_t slot);
void npno_host_cancel_midi_learn(NPNOHost* host);

// Purge de memória RAM
uint64_t npno_host_purge_unused(NPNOHost* host);
bool npno_host_reload_purged(NPNOHost* host);

// Eventos musicais (seguros de qualquer thread)
void npno_host_note_on(NPNOHost* host, int32_t note, float velocity);
void npno_host_note_off(NPNOHost* host, int32_t note);
void npno_host_sustain(NPNOHost* host, bool down);
void npno_host_panic(NPNOHost* host);

// Controles Globais em tempo real
void npno_host_set_master_gain(NPNOHost* host, float gain);
float npno_host_get_master_gain(NPNOHost* host);

void npno_host_set_master_pan(NPNOHost* host, float pan);
float npno_host_get_master_pan(NPNOHost* host);

void npno_host_set_fine_tune_cents(NPNOHost* host, float cents);
float npno_host_get_fine_tune_cents(NPNOHost* host);

void npno_host_set_base_tuning_hz(NPNOHost* host, float hz);
float npno_host_get_base_tuning_hz(NPNOHost* host);

void npno_host_set_max_voices(NPNOHost* host, int32_t max_voices);
int32_t npno_host_get_max_voices(NPNOHost* host);

void npno_host_set_transpose(NPNOHost* host, int32_t semitones);
int32_t npno_host_get_transpose(NPNOHost* host);

void npno_host_set_velocity_curve(NPNOHost* host, int32_t curve);
int32_t npno_host_get_velocity_curve(NPNOHost* host);

void npno_host_set_release_samples_enabled(NPNOHost* host, bool enabled);
bool npno_host_get_release_samples_enabled(NPNOHost* host);

void npno_host_set_release_sample_gain(NPNOHost* host, float gain);
float npno_host_get_release_sample_gain(NPNOHost* host);

void npno_host_set_release_scale(NPNOHost* host, float scale);
float npno_host_get_release_scale(NPNOHost* host);

// Seção 6: Equalizador de 3 bandas + Drive + Mod 1 & Mod 2
void npno_host_set_eq_bass_db(NPNOHost* host, float db);
float npno_host_get_eq_bass_db(NPNOHost* host);

void npno_host_set_eq_mid_db(NPNOHost* host, float db);
float npno_host_get_eq_mid_db(NPNOHost* host);

void npno_host_set_eq_mid_freq_hz(NPNOHost* host, float hz);
float npno_host_get_eq_mid_freq_hz(NPNOHost* host);

void npno_host_set_eq_treble_db(NPNOHost* host, float db);
float npno_host_get_eq_treble_db(NPNOHost* host);

void npno_host_set_drive_enabled(NPNOHost* host, bool enabled);
bool npno_host_get_drive_enabled(NPNOHost* host);

void npno_host_set_drive_amount(NPNOHost* host, float amount);
float npno_host_get_drive_amount(NPNOHost* host);

void npno_host_get_modulator_params(NPNOHost* host, int32_t index, NPNOModulatorParams* out_params);
void npno_host_set_modulator_params(NPNOHost* host, int32_t index, const NPNOModulatorParams* params);

// Seção 7: Delay e Reverb
void npno_host_get_delay_params(NPNOHost* host, NPNODelayParams* out_params);
void npno_host_set_delay_params(NPNOHost* host, const NPNODelayParams* params);
void npno_host_tap_delay(NPNOHost* host);

void npno_host_get_reverb_params(NPNOHost* host, NPNOReverbParams* out_params);
void npno_host_set_reverb_params(NPNOHost* host, const NPNOReverbParams* params);

// Gerenciamento de Dispositivos de Saída de Áudio (CoreAudio HAL)
void npno_host_refresh_audio_devices(NPNOHost* host);
int32_t npno_host_get_audio_output_device_count(NPNOHost* host);
bool npno_host_get_audio_output_device_info(NPNOHost* host, int32_t index,
                                            uint32_t* out_device_id,
                                            char* out_name, int32_t name_len);
bool npno_host_set_audio_output_device(NPNOHost* host, uint32_t device_id);
uint32_t npno_host_get_current_audio_output_device(NPNOHost* host);

// Gerenciamento de Entradas e Canais MIDI (CoreMIDI)
void npno_host_rescan_midi(NPNOHost* host);
int32_t npno_host_get_midi_input_count(NPNOHost* host);
bool npno_host_get_midi_input_info(NPNOHost* host, int32_t index,
                                   char* out_name, int32_t name_len,
                                   bool* out_enabled);
void npno_host_set_midi_input_enabled(NPNOHost* host, int32_t index, bool enabled);
void npno_host_set_midi_channel(NPNOHost* host, int32_t channel); // 0 = Omni, 1..16 = canal específico
int32_t npno_host_get_midi_channel(NPNOHost* host);

// Callback universal de Control Change (MIDI CC) e Eventos MIDI (Monitor + Program Change)
typedef void (*NPNOMidiCCCallback)(int32_t cc, int32_t val, int32_t chan, void* ctx);
void npno_host_set_midi_cc_callback(NPNOHost* host, NPNOMidiCCCallback cb, void* ctx);

typedef void (*NPNOMidiEventCallback)(uint8_t status_type, int32_t data1, int32_t data2, int32_t chan, void* ctx);
void npno_host_set_midi_event_callback(NPNOHost* host, NPNOMidiEventCallback cb, void* ctx);
void npno_host_send_midi_cc(NPNOHost* host, int32_t cc, int32_t value, int32_t channel);

/// Offline render & test helpers (used by unit tests).
void npno_host_render_offline(NPNOHost* host, float* out_l, float* out_r, int32_t num_frames);
bool npno_host_load_test_tone(NPNOHost* host, int32_t layer, float amplitude);

#ifdef __cplusplus
}
#endif
