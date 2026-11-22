// Motor de síntese polifônico multi-camada (A/B/C/D) lock-free em tempo real para bancos .npno.
//
// Regras estritas da thread de áudio (Engine::render):
//   - Zero alocação de memória (new/malloc/vector)
//   - Zero locks/mutexes
//   - Zero I/O ou chamadas de sistema
#pragma once

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <vector>

#include "npno/Instrument.hpp"

namespace npno {

struct LayerParams {
    // --- Seção 2: Camadas A/B/C/D ---
    bool enabled = false;
    float volume = 1.0f;       // 0.0 .. 1.5 (1.0 = 0 dB)
    float filter = 1.0f;       // 0.0 .. 1.0 (cutoff LP: 120 Hz .. 20 kHz)
    float fxaAmount = 0.20f;   // 0.0 .. 1.0 (envio p/ efeito da camada / espacialização)
    float fxaRelease = 0.50f;  // 0.0 .. 1.0 (tempo de cauda/modulação do efeito FXA)

    // --- Seção 3: Advanced (por camada) ---
    int ccVolume = -1;         // -1 = OFF, 0..127 = CC MIDI
    int ccFilter = -1;
    int ccFxaAmount = -1;
    int ccFxaRelease = -1;
    int keyLow = 0;            // 0 .. 127
    int keyHigh = 127;         // 0 .. 127
    int velLow = 1;            // 1 .. 127
    int velHigh = 127;         // 1 .. 127
    int midiChannel = 0;       // 0 = Global/Omni, 1..16 = canal específico
    int velocityCurve = 0;     // 0=Main, 1=Soft, 2=Linear, 3=Hard, 4=Exp, 5=Log
    int pitchBendDown = -2;    // -24 .. 0 semitons
    int pitchBendUp = 2;       // 0 .. +24 semitons
    bool portamentoOn = false;
    float portamentoTimeMs = 120.0f; // 5 .. 2000 ms
    bool fixedVelocity = false;
    int fixedVelocityValue = 100;    // 1 .. 127
    bool legatoMono = false;

    // --- Seção 5: Timbre (por camada) ---
    int timbreMode = 0;        // 0=Mid, 1=Bright, 2=Soft, 3=Dyno1, 4=Dyno2
    bool sustainPedalOn = true;
    bool undampedOn = true;
    bool compOn = false;
    float compAmount = 0.45f;  // 0.0 .. 1.0
    bool compFast = false;
    int octaveShift = 0;       // -3 .. +3 oitavas
    bool originalEnvelope = true;
    float attackMs = 1.0f;     // 0.5 .. 2000 ms (ativo quando originalEnvelope == false)
    float releaseMs = 600.0f;  // 20 .. 5000 ms (ativo quando originalEnvelope == false)
};

struct ModulatorParams {
    bool enabled = false;
    int target = 0;      // 0=Volume (Tremolo), 1=Filter (Auto-Wah), 2=Pitch (Vibrato), 3=Pan (Auto-Pan)
    int wave = 0;        // 0=Sine, 1=Triangle, 2=Saw, 3=Square, 4=Envelope
    float rateHz = 4.5f; // 0.1 .. 20.0 Hz
    float depth = 0.35f; // 0.0 .. 1.0
};

struct DelayParams {
    bool enabled = false;
    float amount = 0.25f;      // 0.0 .. 1.0
    float feedback = 0.35f;    // 0.0 .. 0.92
    float timeMs = 360.0f;     // 20 .. 2000 ms
    bool syncToHost = false;
    float hostBpm = 120.0f;    // 40 .. 240 BPM
    int syncDivision = 1;      // 0=1/4, 1=1/8, 2=1/8D, 3=1/8T, 4=1/16
    bool pingPong = true;
};

struct ReverbParams {
    bool enabled = true;
    float amount = 0.22f;      // 0.0 .. 1.0
    float size = 0.65f;        // 0.1 .. 1.0
    float decay = 0.55f;       // 0.1 .. 1.0
    float damping = 0.45f;     // 0.0 .. 1.0
    float preDelayMs = 18.0f;  // 0.0 .. 120.0 ms
};

class Engine {
public:
    static constexpr int kNumLayers = 4;
    static constexpr int kMaxVoices = 512;
    static constexpr int kAntiClickSamples = 256;   // ~5 ms de rampa de emergência (só em roubo de voz)
    static constexpr float kRetriggerFadeSec = 0.030f; // rampa ao repetir a mesma tecla (30 ms, como abafador real)
    static constexpr float kStealFadeSec = 0.006f;     // rampa ao desligar camada / legato
    static constexpr int kTailFadeFrames = 192;        // rampa no fim de amostras sem loop
    static constexpr size_t kEventQueueSize = 2048;  // potência de 2

    enum class EventType : uint8_t {
        NoteOn = 0,
        NoteOff = 1,
        Sustain = 2,
        Panic = 3,
        PitchBend = 4,
        ControlChange = 5,
        KillLayer = 6,
    };

    struct Event {
        EventType type = EventType::NoteOn;
        uint8_t note = 0;     // note (0..127) ou CC number (0..127)
        uint8_t channel = 1;  // canal MIDI 1..16 (0 = global/UI)
        float value = 0.0f;   // velocity (0..1), sustain (0/1), pitchBend (-1..+1 normalizado ou semitons), CC (0..127)
    };

    Engine();

    /// Configura a taxa de amostragem de saída (ex.: 44100.0 ou 48000.0).
    void prepare(double sampleRate);

    /// Define o instrumento de uma camada (0=A, 1=B, 2=C, 3=D).
    void setLayerInstrument(int layer, const Instrument* inst);
    const Instrument* layerInstrument(int layer) const;

    /// Compatibilidade com slot único (Camada A = 0).
    void setInstrument(const Instrument* inst) { setLayerInstrument(0, inst); }
    const Instrument* instrument() const { return layerInstrument(0); }

    // --- Parâmetros por Camada (A/B/C/D) ---
    void setLayerParams(int layer, const LayerParams& params);
    LayerParams layerParams(int layer) const;

    // --- MIDI Learn para os 4 sliders da camada (0=Volume, 1=Filter, 2=FXA AM, 3=FXA RT) ---
    void startMidiLearn(int layer, int slot);
    void cancelMidiLearn();
    int midiLearnLayer() const { return midiLearnLayer_.load(std::memory_order_relaxed); }
    int midiLearnSlot() const { return midiLearnSlot_.load(std::memory_order_relaxed); }

    // --- Enfileiramento lock-free de eventos (seguro de qualquer thread: MIDI, UI, teclado) ---
    void pushEvent(EventType type, int note, float value = 0.0f, int channel = 0);

    // --- Chamadas diretas (para uso na própria thread de renderização / offline) ---
    void noteOn(int note, float velocity, int channel = 0);
    void noteOff(int note, int channel = 0);
    void sustain(bool down, int channel = 0);
    void controlChange(int cc, int value127, int channel = 0);
    void panic();
    void pitchBend(float normalizedOrSemis, int channel = 0);

    // --- Seção 1 & Global: Controles Gerais ---
    void setMasterGain(float linearGain) { masterGain_.store(linearGain, std::memory_order_relaxed); }
    float masterGain() const { return masterGain_.load(std::memory_order_relaxed); }

    void setMasterPan(float pan) { masterPan_.store(std::clamp(pan, -1.0f, 1.0f), std::memory_order_relaxed); }
    float masterPan() const { return masterPan_.load(std::memory_order_relaxed); }

    void setFineTuneCents(float cents) { fineTuneCents_.store(cents, std::memory_order_relaxed); }
    float fineTuneCents() const { return fineTuneCents_.load(std::memory_order_relaxed); }

    void setBaseTuningHz(float hz) { baseTuningHz_.store(std::clamp(hz, 432.0f, 446.0f), std::memory_order_relaxed); }
    float baseTuningHz() const { return baseTuningHz_.load(std::memory_order_relaxed); }

    void setMaxVoices(int maxV) { maxVoices_.store(std::clamp(maxV, 16, kMaxVoices), std::memory_order_relaxed); }
    int maxVoices() const { return maxVoices_.load(std::memory_order_relaxed); }

    void setGlobalMidiChannel(int ch) { globalMidiChannel_.store(std::clamp(ch, 0, 16), std::memory_order_relaxed); }
    int globalMidiChannel() const { return globalMidiChannel_.load(std::memory_order_relaxed); }

    void setTransposeSemitones(int semi) { transpose_.store(semi, std::memory_order_relaxed); }
    int transposeSemitones() const { return transpose_.load(std::memory_order_relaxed); }

    void setVelocityCurve(int curve) { velCurve_.store(curve, std::memory_order_relaxed); }
    int velocityCurve() const { return velCurve_.load(std::memory_order_relaxed); }

    void setReleaseSamplesEnabled(bool on) { releaseEnabled_.store(on, std::memory_order_relaxed); }
    bool releaseSamplesEnabled() const { return releaseEnabled_.load(std::memory_order_relaxed); }

    void setReleaseSampleGain(float gain) { releaseSampleGain_.store(gain, std::memory_order_relaxed); }
    float releaseSampleGain() const { return releaseSampleGain_.load(std::memory_order_relaxed); }

    void setReleaseScale(float scale) { releaseScale_.store(scale, std::memory_order_relaxed); }
    float releaseScale() const { return releaseScale_.load(std::memory_order_relaxed); }

    // --- Seção 6: Equalizador de 3 bandas + Drive + Mod 1 & Mod 2 ---
    void setEqBassDb(float db) { eqBassDb_.store(db, std::memory_order_relaxed); }
    float eqBassDb() const { return eqBassDb_.load(std::memory_order_relaxed); }

    void setEqMidDb(float db) { eqMidDb_.store(db, std::memory_order_relaxed); }
    float eqMidDb() const { return eqMidDb_.load(std::memory_order_relaxed); }

    void setEqMidFreqHz(float hz) { eqMidFreqHz_.store(hz, std::memory_order_relaxed); }
    float eqMidFreqHz() const { return eqMidFreqHz_.load(std::memory_order_relaxed); }

    void setEqTrebleDb(float db) { eqTrebleDb_.store(db, std::memory_order_relaxed); }
    float eqTrebleDb() const { return eqTrebleDb_.load(std::memory_order_relaxed); }

    void setDriveEnabled(bool on) { driveEnabled_.store(on, std::memory_order_relaxed); }
    bool driveEnabled() const { return driveEnabled_.load(std::memory_order_relaxed); }

    void setDriveAmount(float amt) { driveAmount_.store(std::clamp(amt, 0.0f, 1.0f), std::memory_order_relaxed); }
    float driveAmount() const { return driveAmount_.load(std::memory_order_relaxed); }

    void setModulatorParams(int index, const ModulatorParams& mod);
    ModulatorParams modulatorParams(int index) const;

    // --- Seção 7: Delay e Reverb ---
    void setDelayParams(const DelayParams& d);
    DelayParams delayParams() const;
    void tapDelay(double currentTimestampSec);

    void setReverbParams(const ReverbParams& r);
    ReverbParams reverbParams() const;

    // --- Telemetria lock-free para a UI ---
    int activeVoices() const { return activeVoices_.load(std::memory_order_relaxed); }
    int layerActiveVoices(int layer) const {
        if (layer < 0 || layer >= kNumLayers) return 0;
        return layerActiveVoices_[layer].load(std::memory_order_relaxed);
    }
    bool isSustainDown() const { return sustainState_.load(std::memory_order_relaxed); }
    float peakLeft() const { return peakL_.load(std::memory_order_relaxed); }
    float peakRight() const { return peakR_.load(std::memory_order_relaxed); }
    void decayPeaks(float factor = 0.85f) {
        peakL_.store(peakL_.load(std::memory_order_relaxed) * factor, std::memory_order_relaxed);
        peakR_.store(peakR_.load(std::memory_order_relaxed) * factor, std::memory_order_relaxed);
    }
    bool isClipped() const { return clipped_.load(std::memory_order_relaxed); }
    void resetClipIndicator() { clipped_.store(false, std::memory_order_relaxed); }

    /// Número de ciclos de render concluídos (usado para liberar instrumentos fora da thread de áudio
    /// somente depois que nenhum callback em andamento possa estar lendo o ponteiro antigo).
    uint64_t renderCount() const { return renderCount_.load(std::memory_order_acquire); }

    /// Troca apenas o ponteiro do instrumento da camada (sem alterar params nem enfileirar eventos).
    /// Usado em manutenção (purge/reload) depois que as vozes da camada já foram silenciadas.
    void setLayerInstrumentPointer(int layer, const Instrument* inst) {
        if (layer < 0 || layer >= kNumLayers) return;
        instruments_[layer].store(inst, std::memory_order_release);
    }
    uint8_t keyVelocity(int note) const {
        if (note < 0 || note > 127) return 0;
        return keyState_[note].load(std::memory_order_relaxed);
    }

    /// Renderiza `numFrames` frames estéreo em `outL` e `outR` (tempo real, lock-free).
    void render(float* outL, float* outR, int numFrames) noexcept;

private:
    struct Voice {
        const Sample* sample = nullptr;
        uint8_t layer = 0;       // 0..3 (A..D)
        int note = 0;            // nota MIDI soar
        int triggerKey = 0;      // tecla original antes da transposição
        bool active = false;
        bool isReleaseVoice = false;
        bool keyHeld = false;
        bool sustained = false;
        bool sostenutoHeld = false;
        bool releasing = false;
        bool undamped = false;
        uint64_t age = 0;

        double pos = 0.0;
        double baseStep = 1.0;
        double currentGlideSemis = 0.0; // deslocamento atual de portamento em semitons
        double glideDecayMul = 0.999;   // fator exponencial por amostra para portamento
        float baseGain = 0.0f;
        float velNorm = 1.0f;           // velocidade efetiva (0..1) com que a tecla foi tocada
        double loopEnv = 1.0;
        double envDecayMul = 1.0;
        double loopDecayMul = 1.0;
        double relEnv = 1.0;
        double relDecayMul = 0.999;

        // Envelope de ataque configurável
        float attackEnv = 0.0f;
        float attackStep = 1.0f;

        // Fade-out real da voz (renderiza a onda enquanto abaixa o ganho — sem descontinuidade)
        bool killing = false;
        float killGain = 1.0f;
        float killStep = 0.0f;

        // Micro-rampa anti-click de emergência (apenas quando todas as vozes estão ocupadas)
        float fadeOutL = 0.0f;
        float fadeOutR = 0.0f;
        int fadeOutRemaining = 0;
        uint8_t fadeOutLayer = 0;
        float lastL = 0.0f;
        float lastR = 0.0f;
    };

    struct LayerRuntimeState {
        // Filtro passa-baixas + presença (Timbre/Filter da camada)
        float lpZ1L = 0.0f;
        float lpZ1R = 0.0f;
        float hpZ1L = 0.0f;
        float hpZ1R = 0.0f;
        // One-pole parameter smoothing (~10 ms) for zero zipper noise
        float smoothVol = 1.0f;
        float smoothLpAlpha = 1.0f;
        bool smoothInitialized = false;
        // Compressor e limitador por camada
        float compEnv = 0.0f;
        float layerLimiterGain = 1.0f;
        // Efeito FXA por camada (Ensemble/Chorus/Ambience stereo)
        float fxaPhase = 0.0f;
        float fxaEnvL = 0.0f;
        float fxaEnvR = 0.0f;
        // Última nota tocada para Portamento / Legato
        int lastNote = -1;
    };

    Voice& allocateVoice(int layer, int note, bool isReleaseVoice, bool legatoMono) noexcept;
    void beginKill(Voice& v, float seconds) noexcept;
    void hardStealVoice(Voice& v) noexcept;
    void killLayerVoices(int layer) noexcept;
    void syncAudioParamsIfUnlocked() noexcept;
    const std::array<LayerParams, kNumLayers>& audioLayerParams() noexcept;
    void startReleaseOnVoice(Voice& v, const Instrument* inst, const LayerParams& lp, bool triggerRelSample) noexcept;
    void spawnReleaseVoice(int layer, int note, float envLevel, const Instrument* inst, const LayerParams& lp) noexcept;
    float effectiveSustainLevel(const LayerParams& lp) const noexcept;
    void applySustainLevelChange(int channel, float newLevel) noexcept;
    void handleAllNotesOff(int channel) noexcept;
    void handleAllSoundOff(int channel) noexcept;
    void drainEvents() noexcept;

    double sampleRate_ = 48000.0;
    uint64_t voiceCounter_ = 0;
    bool sustainPedal_ = false;
    float sustainPedalLevel_ = 0.0f; // 0.0 .. 1.0 (continuous half-pedaling on CC64)
    std::array<float, 17> sustainLevelByCh_{}; // 0 = global/UI, 1..16 = MIDI channels 1..16
    bool sostenutoPedal_ = false;    // CC66
    bool softPedal_ = false;         // CC67 (una corda)
    float expressionGain_ = 1.0f;    // CC11 (0.0 .. 1.0)
    float channelVolumeGain_ = 1.0f; // CC7 (0.0 .. 1.0)
    float pitchBendNorm_ = 0.0f; // -1.0 .. +1.0

    std::array<Voice, kMaxVoices> voices_{};
    std::array<LayerRuntimeState, kNumLayers> layerState_{};

    // Instrumentos e parâmetros das 4 camadas
    std::array<std::atomic<const Instrument*>, kNumLayers> instruments_{};
    std::array<LayerParams, kNumLayers> layerParams_{};
    mutable std::atomic<uint32_t> paramLock_{0}; // spinlock ultraleve apenas para cópia de structs pequenas
    // Cópia usada pela thread de áudio: atualizada com try-lock (nunca bloqueia/espera a UI).
    std::array<LayerParams, kNumLayers> audioLps_{};
    std::array<ModulatorParams, 2> audioMods_{};
    DelayParams audioDelay_{};
    ReverbParams audioReverb_{};

    // One-pole master parameter smoothing (~10 ms)
    bool masterSmoothInit_ = false;
    float smoothMasterGain_ = 1.0f;
    float smoothPanL_ = 1.0f;
    float smoothPanR_ = 1.0f;
    float smoothDriveAmt_ = 0.25f;
    float smoothDelayMix_ = 0.25f;
    float smoothReverbMix_ = 0.22f;
    float smoothBassDb_ = 0.0f;
    float smoothMidDb_ = 0.0f;
    float smoothTrebleDb_ = 0.0f;

    // MIDI Learn
    std::atomic<int> midiLearnLayer_{-1};
    std::atomic<int> midiLearnSlot_{-1};

    // Fila lock-free MPSC baseada em sequência por slot
    struct QueueSlot {
        std::atomic<uint32_t> sequence{0};
        Event event{};
    };
    std::array<QueueSlot, kEventQueueSize> queue_{};
    std::atomic<uint32_t> writePos_{0};
    uint32_t readPos_ = 0;

    // Parâmetros globais
    std::atomic<float> masterGain_{1.0f};
    std::atomic<float> masterPan_{0.0f};
    std::atomic<float> fineTuneCents_{0.0f};
    std::atomic<float> baseTuningHz_{440.0f};
    std::atomic<int> maxVoices_{256};
    std::atomic<int> globalMidiChannel_{0}; // 0 = Omni, 1..16
    std::atomic<int> transpose_{0};
    std::atomic<int> velCurve_{0};
    std::atomic<bool> releaseEnabled_{true};
    std::atomic<float> releaseSampleGain_{1.0f};
    std::atomic<float> releaseScale_{1.0f};

    // Seção 6: EQ | Drive + Mod 1/2
    std::atomic<float> eqBassDb_{0.0f};
    std::atomic<float> eqMidDb_{0.0f};
    std::atomic<float> eqMidFreqHz_{1000.0f};
    std::atomic<float> eqTrebleDb_{0.0f};
    std::atomic<bool> driveEnabled_{false};
    std::atomic<float> driveAmount_{0.25f};

    std::array<ModulatorParams, 2> modParams_{};
    std::array<double, 2> modPhase_{0.0, 0.0};
    float modEnvFollower_ = 0.0f;
    float masterLimiterGain_ = 1.0f;

    // Seção 7: Delay e Reverb
    DelayParams delayParams_{};
    ReverbParams reverbParams_{};
    double lastTapTimeSec_ = -1.0;

    // Buffers de Delay Estéreo / Ping-Pong pré-alocados em prepare()
    std::vector<float> delayBufL_;
    std::vector<float> delayBufR_;
    size_t delayWriteIdx_ = 0;
    float delayLpL_ = 0.0f;
    float delayLpR_ = 0.0f;

    // Buffers de Reverb Estéreo Studio (Schroeder/Freeverb 4-comb + 2-allpass + pre-delay) pré-alocados em prepare()
    std::vector<float> revPreDelayBuf_;
    size_t revPreWriteIdx_ = 0;
    struct CombFilter {
        std::vector<float> buf;
        size_t idx = 0;
        float filterStore = 0.0f;
        void init(size_t size) {
            buf.assign(std::max<size_t>(16, size), 0.0f);
            idx = 0;
            filterStore = 0.0f;
        }
        inline float process(float input, float feedback, float damp) noexcept {
            const float output = buf[idx];
            filterStore = output * (1.0f - damp) + filterStore * damp;
            buf[idx] = input + filterStore * feedback;
            if (++idx >= buf.size()) idx = 0;
            return output;
        }
    };
    struct AllpassFilter {
        std::vector<float> buf;
        size_t idx = 0;
        void init(size_t size) {
            buf.assign(std::max<size_t>(16, size), 0.0f);
            idx = 0;
        }
        inline float process(float input) noexcept {
            const float bufOut = buf[idx];
            const float output = -input + bufOut;
            buf[idx] = input + bufOut * 0.5f;
            if (++idx >= buf.size()) idx = 0;
            return output;
        }
    };
    std::array<CombFilter, 4> combL_{};
    std::array<CombFilter, 4> combR_{};
    std::array<AllpassFilter, 2> allpassL_{};
    std::array<AllpassFilter, 2> allpassR_{};

    struct Biquad {
        float b0 = 1.0f, b1 = 0.0f, b2 = 0.0f, a1 = 0.0f, a2 = 0.0f;
        float z1L = 0.0f, z2L = 0.0f, z1R = 0.0f, z2R = 0.0f;
        void resetState() noexcept { z1L = z2L = z1R = z2R = 0.0f; }
        inline void processStereo(float& l, float& r) noexcept {
            const float outL = b0 * l + z1L;
            z1L = b1 * l - a1 * outL + z2L;
            z2L = b2 * l - a2 * outL;
            l = outL;

            const float outR = b0 * r + z1R;
            z1R = b1 * r - a1 * outR + z2R;
            z2R = b2 * r - a2 * outR;
            r = outR;
        }
    };
    Biquad eqLow_{};
    Biquad eqMid_{};
    Biquad eqHigh_{};
    float lastBassDb_ = 999.0f;
    float lastMidDb_ = 999.0f;
    float lastMidFreq_ = -1.0f;
    float lastTrebleDb_ = 999.0f;
    double lastEqSampleRate_ = 0.0;
    void updateEqCoefficientsIfNeeded() noexcept;

    std::atomic<int> activeVoices_{0};
    std::array<std::atomic<int>, kNumLayers> layerActiveVoices_{};
    std::atomic<bool> sustainState_{false};
    std::atomic<float> peakL_{0.0f};
    std::atomic<float> peakR_{0.0f};
    std::atomic<bool> clipped_{false};
    std::atomic<uint64_t> renderCount_{0};
    std::array<std::atomic<uint8_t>, 128> keyState_{};
};

}  // namespace npno
