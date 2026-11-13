#include "npno/Engine.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace npno {

namespace {

constexpr double kLn10Over20 = 0.11512925464970229;     // ln(10) / 20
constexpr double kReleaseTargetLn = 6.907755278982137;  // -60 dB = ln(1000)
constexpr double kTwoPi = 6.28318530717958647692;

// Spinlock ultraleve para leitura/escrita de structs de configuração
struct ScopedSpinLock {
    std::atomic<uint32_t>& flag;
    explicit ScopedSpinLock(std::atomic<uint32_t>& f) noexcept : flag(f) {
        while (flag.exchange(1, std::memory_order_acquire) != 0) {
            // spin curto
        }
    }
    ~ScopedSpinLock() noexcept { flag.store(0, std::memory_order_release); }
};

// Interpolação cúbica Hermite de 4 pontos para evitar aliasing na transposição e conversão 34990 Hz -> 48000 Hz.
inline void sampleHermiteStereo(const Sample& s, uint32_t idx, float frac, float& outL, float& outR) noexcept {
    if (s.pcm.empty()) {
        outL = outR = 0.0f;
        return;
    }
    const int16_t* p = s.pcm.data();
    const uint32_t maxIdx = uint32_t(s.pcm.size() / std::max<uint16_t>(1, s.channels));
    if (idx + 3 >= maxIdx) {
        outL = outR = 0.0f;
        return;
    }
    const uint32_t i0 = (idx > 0) ? (idx - 1) : 0;
    const uint32_t i1 = idx;
    const uint32_t i2 = idx + 1;
    const uint32_t i3 = idx + 2;

    auto hermite = [](float ym1, float y0, float y1, float y2, float t) noexcept -> float {
        const float c0 = y0;
        const float c1 = 0.5f * (y1 - ym1);
        const float c2 = ym1 - 2.5f * y0 + 2.0f * y1 - 0.5f * y2;
        const float c3 = 0.5f * (y2 - ym1) + 1.5f * (y0 - y1);
        return ((c3 * t + c2) * t + c1) * t + c0;
    };

    if (s.channels == 2) {
        outL = hermite(p[i0 * 2], p[i1 * 2], p[i2 * 2], p[i3 * 2], frac);
        outR = hermite(p[i0 * 2 + 1], p[i1 * 2 + 1], p[i2 * 2 + 1], p[i3 * 2 + 1], frac);
    } else {
        outL = outR = hermite(p[i0], p[i1], p[i2], p[i3], frac);
    }
}

inline float applyGlobalVelocityCurve(float v, int curve) noexcept {
    v = std::clamp(v, 0.0f, 1.0f);
    if (curve < 0) return std::pow(v, 0.72f);  // Soft / Light
    if (curve > 0) return std::pow(v, 1.38f);  // Heavy
    return v;
}

inline float applyLayerVelocityCurve(float v, int curve) noexcept {
    v = std::clamp(v, 0.0f, 1.0f);
    switch (curve) {
        case 1: return std::pow(v, 0.68f);        // Soft
        case 2: return v;                         // Linear
        case 3: return std::pow(v, 1.45f);        // Hard
        case 4: return v * v;                     // Exp
        case 5: return std::sqrt(v);              // Log
        default: return v;                        // Main (0)
    }
}

inline float evalLfoWave(int wave, double phase01, float envFollower) noexcept {
    switch (wave) {
        case 0:  // Sine (-1..+1)
            return float(std::sin(phase01 * kTwoPi));
        case 1:  // Triangle (-1..+1)
            return float(1.0 - 4.0 * std::fabs(std::round(phase01 - 0.25) - (phase01 - 0.25)));
        case 2:  // Saw (-1..+1)
            return float(2.0 * phase01 - 1.0);
        case 3:  // Square (-1..+1)
            return (phase01 < 0.5) ? 1.0f : -1.0f;
        case 4:  // Envelope Follower (-1..+1)
            return std::clamp(envFollower * 4.0f - 1.0f, -1.0f, 1.0f);
        default:
            return float(std::sin(phase01 * kTwoPi));
    }
}

}  // namespace

Engine::Engine() {
    for (uint32_t i = 0; i < kEventQueueSize; ++i) {
        queue_[i].sequence.store(i, std::memory_order_relaxed);
    }
    for (auto& k : keyState_) k.store(0, std::memory_order_relaxed);
    for (auto& inst : instruments_) inst.store(nullptr, std::memory_order_relaxed);
    for (auto& lav : layerActiveVoices_) lav.store(0, std::memory_order_relaxed);

    // Camada A (0) habilitada por padrão; B/C/D prontas para ativar ao carregar ou clicar ON
    layerParams_[0].enabled = true;
    layerParams_[1].enabled = false;
    layerParams_[2].enabled = false;
    layerParams_[3].enabled = false;

    modParams_[0].enabled = false;
    modParams_[0].target = 0; // Volume (Tremolo)
    modParams_[0].wave = 0;
    modParams_[0].rateHz = 4.5f;
    modParams_[0].depth = 0.35f;

    modParams_[1].enabled = false;
    modParams_[1].target = 2; // Pitch (Vibrato)
    modParams_[1].wave = 0;
    modParams_[1].rateHz = 5.5f;
    modParams_[1].depth = 0.20f;

    audioLps_ = layerParams_;
    prepare(48000.0);
}

void Engine::prepare(double sampleRate) {
    if (sampleRate > 8000.0) sampleRate_ = sampleRate;
    eqLow_.resetState();
    eqMid_.resetState();
    eqHigh_.resetState();
    lastEqSampleRate_ = 0.0;

    // Pré-aloca buffer de Delay para até 2.5 segundos
    const size_t maxDelaySamples = std::max<size_t>(4096, size_t(sampleRate_ * 2.5) + 16);
    delayBufL_.assign(maxDelaySamples, 0.0f);
    delayBufR_.assign(maxDelaySamples, 0.0f);
    delayWriteIdx_ = 0;
    delayLpL_ = 0.0f;
    delayLpR_ = 0.0f;

    // Pré-aloca buffers de Reverb Estéreo (Freeverb tunings escalados pela sampleRate)
    const double srScale = sampleRate_ / 44100.0;
    const size_t maxPreDelay = std::max<size_t>(256, size_t(sampleRate_ * 0.20) + 8);
    revPreDelayBuf_.assign(maxPreDelay, 0.0f);
    revPreWriteIdx_ = 0;

    constexpr int kCombLengths[4] = {1116, 1188, 1277, 1356};
    constexpr int kAllpassLengths[2] = {556, 441};
    constexpr int kStereoSpread = 23;
    for (int i = 0; i < 4; ++i) {
        combL_[i].init(size_t(kCombLengths[i] * srScale));
        combR_[i].init(size_t((kCombLengths[i] + kStereoSpread) * srScale));
    }
    for (int i = 0; i < 2; ++i) {
        allpassL_[i].init(size_t(kAllpassLengths[i] * srScale));
        allpassR_[i].init(size_t((kAllpassLengths[i] + kStereoSpread) * srScale));
    }

    for (auto& st : layerState_) {
        st = LayerRuntimeState{};
    }

    panic();
}

void Engine::setLayerInstrument(int layer, const Instrument* inst) {
    if (layer < 0 || layer >= kNumLayers) return;
    const Instrument* prev = instruments_[layer].exchange(inst, std::memory_order_acq_rel);
    if (inst != nullptr) {
        ScopedSpinLock lock(paramLock_);
        layerParams_[layer].enabled = true;
    }
    if (prev && prev != inst) {
        pushEvent(EventType::Panic, 0, 0.0f, 0);
    }
}

const Instrument* Engine::layerInstrument(int layer) const {
    if (layer < 0 || layer >= kNumLayers) return nullptr;
    return instruments_[layer].load(std::memory_order_acquire);
}

void Engine::setLayerParams(int layer, const LayerParams& params) {
    if (layer < 0 || layer >= kNumLayers) return;
    ScopedSpinLock lock(paramLock_);
    layerParams_[layer] = params;
}

LayerParams Engine::layerParams(int layer) const {
    if (layer < 0 || layer >= kNumLayers) return LayerParams{};
    ScopedSpinLock lock(paramLock_);
    return layerParams_[layer];
}

void Engine::startMidiLearn(int layer, int slot) {
    if (layer < 0 || layer >= kNumLayers || slot < 0 || slot > 3) {
        cancelMidiLearn();
        return;
    }
    midiLearnLayer_.store(layer, std::memory_order_relaxed);
    midiLearnSlot_.store(slot, std::memory_order_relaxed);
}

void Engine::cancelMidiLearn() {
    midiLearnLayer_.store(-1, std::memory_order_relaxed);
    midiLearnSlot_.store(-1, std::memory_order_relaxed);
}

void Engine::setModulatorParams(int index, const ModulatorParams& mod) {
    if (index < 0 || index > 1) return;
    ScopedSpinLock lock(paramLock_);
    modParams_[index] = mod;
}

ModulatorParams Engine::modulatorParams(int index) const {
    if (index < 0 || index > 1) return ModulatorParams{};
    ScopedSpinLock lock(paramLock_);
    return modParams_[index];
}

void Engine::setDelayParams(const DelayParams& d) {
    ScopedSpinLock lock(paramLock_);
    delayParams_ = d;
}

DelayParams Engine::delayParams() const {
    ScopedSpinLock lock(paramLock_);
    return delayParams_;
}

void Engine::tapDelay(double currentTimestampSec) {
    ScopedSpinLock lock(paramLock_);
    if (lastTapTimeSec_ > 0.0) {
        const double dt = currentTimestampSec - lastTapTimeSec_;
        if (dt >= 0.06 && dt <= 2.0) {
            delayParams_.timeMs = float(std::clamp(dt * 1000.0, 20.0, 2000.0));
            delayParams_.syncToHost = false;
            delayParams_.enabled = true;
        }
    }
    lastTapTimeSec_ = currentTimestampSec;
}

void Engine::setReverbParams(const ReverbParams& r) {
    ScopedSpinLock lock(paramLock_);
    reverbParams_ = r;
}

ReverbParams Engine::reverbParams() const {
    ScopedSpinLock lock(paramLock_);
    return reverbParams_;
}

void Engine::updateEqCoefficientsIfNeeded() noexcept {
    const float bassDb = std::clamp(eqBassDb_.load(std::memory_order_relaxed), -18.0f, 18.0f);
    const float midDb = std::clamp(eqMidDb_.load(std::memory_order_relaxed), -18.0f, 18.0f);
    const float midFreq = std::clamp(eqMidFreqHz_.load(std::memory_order_relaxed), 150.0f, 8000.0f);
    const float trebleDb = std::clamp(eqTrebleDb_.load(std::memory_order_relaxed), -18.0f, 18.0f);

    if (bassDb == lastBassDb_ && midDb == lastMidDb_ && midFreq == lastMidFreq_ &&
        trebleDb == lastTrebleDb_ && sampleRate_ == lastEqSampleRate_) {
        return;
    }
    lastBassDb_ = bassDb;
    lastMidDb_ = midDb;
    lastMidFreq_ = midFreq;
    lastTrebleDb_ = trebleDb;
    lastEqSampleRate_ = sampleRate_;

    constexpr double kPi = 3.14159265358979323846;
    const double sr = std::max(8000.0, sampleRate_);

    // 1. Low Shelf @ 110 Hz
    {
        const double A = std::pow(10.0, double(bassDb) / 40.0);
        const double w0 = 2.0 * kPi * 110.0 / sr;
        const double cosw = std::cos(w0);
        const double sinw = std::sin(w0);
        const double alpha = sinw * 0.5 * std::sqrt(2.0);
        const double twoSqrtAAlpha = 2.0 * std::sqrt(A) * alpha;

        const double b0 = A * ((A + 1.0) - (A - 1.0) * cosw + twoSqrtAAlpha);
        const double b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosw);
        const double b2 = A * ((A + 1.0) - (A - 1.0) * cosw - twoSqrtAAlpha);
        const double a0 = (A + 1.0) + (A - 1.0) * cosw + twoSqrtAAlpha;
        const double a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosw);
        const double a2 = (A + 1.0) + (A - 1.0) * cosw - twoSqrtAAlpha;
        const double invA0 = 1.0 / a0;
        eqLow_.b0 = float(b0 * invA0);
        eqLow_.b1 = float(b1 * invA0);
        eqLow_.b2 = float(b2 * invA0);
        eqLow_.a1 = float(a1 * invA0);
        eqLow_.a2 = float(a2 * invA0);
    }

    // 2. Peaking EQ @ midFreq (Q = 1.0)
    {
        const double A = std::pow(10.0, double(midDb) / 40.0);
        const double w0 = 2.0 * kPi * std::min(double(midFreq), sr * 0.45) / sr;
        const double cosw = std::cos(w0);
        const double sinw = std::sin(w0);
        const double Q = 1.0;
        const double alpha = sinw / (2.0 * Q);

        const double b0 = 1.0 + alpha * A;
        const double b1 = -2.0 * cosw;
        const double b2 = 1.0 - alpha * A;
        const double a0 = 1.0 + alpha / A;
        const double a1 = -2.0 * cosw;
        const double a2 = 1.0 - alpha / A;
        const double invA0 = 1.0 / a0;
        eqMid_.b0 = float(b0 * invA0);
        eqMid_.b1 = float(b1 * invA0);
        eqMid_.b2 = float(b2 * invA0);
        eqMid_.a1 = float(a1 * invA0);
        eqMid_.a2 = float(a2 * invA0);
    }

    // 3. High Shelf @ 4000 Hz
    {
        const double A = std::pow(10.0, double(trebleDb) / 40.0);
        const double w0 = 2.0 * kPi * std::min(4000.0, sr * 0.45) / sr;
        const double cosw = std::cos(w0);
        const double sinw = std::sin(w0);
        const double alpha = sinw * 0.5 * std::sqrt(2.0);
        const double twoSqrtAAlpha = 2.0 * std::sqrt(A) * alpha;

        const double b0 = A * ((A + 1.0) + (A - 1.0) * cosw + twoSqrtAAlpha);
        const double b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosw);
        const double b2 = A * ((A + 1.0) + (A - 1.0) * cosw - twoSqrtAAlpha);
        const double a0 = (A + 1.0) - (A - 1.0) * cosw + twoSqrtAAlpha;
        const double a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosw);
        const double a2 = (A + 1.0) - (A - 1.0) * cosw - twoSqrtAAlpha;
        const double invA0 = 1.0 / a0;
        eqHigh_.b0 = float(b0 * invA0);
        eqHigh_.b1 = float(b1 * invA0);
        eqHigh_.b2 = float(b2 * invA0);
        eqHigh_.a1 = float(a1 * invA0);
        eqHigh_.a2 = float(a2 * invA0);
    }
}

void Engine::pushEvent(EventType type, int note, float value, int channel) {
    uint32_t pos = writePos_.load(std::memory_order_relaxed);
    for (;;) {
        QueueSlot& slot = queue_[pos & (kEventQueueSize - 1)];
        uint32_t seq = slot.sequence.load(std::memory_order_acquire);
        intptr_t diff = intptr_t(seq) - intptr_t(pos);
        if (diff == 0) {
            if (writePos_.compare_exchange_weak(pos, pos + 1, std::memory_order_relaxed)) {
                slot.event.type = type;
                slot.event.note = uint8_t(std::clamp(note, 0, 127));
                slot.event.channel = uint8_t(std::clamp(channel, 0, 16));
                slot.event.value = value;
                slot.sequence.store(pos + 1, std::memory_order_release);
                return;
            }
        } else if (diff < 0) {
            return;
        } else {
            pos = writePos_.load(std::memory_order_relaxed);
        }
    }
}

void Engine::drainEvents() noexcept {
    for (;;) {
        QueueSlot& slot = queue_[readPos_ & (kEventQueueSize - 1)];
        uint32_t seq = slot.sequence.load(std::memory_order_acquire);
        intptr_t diff = intptr_t(seq) - intptr_t(readPos_ + 1);
        if (diff == 0) {
            Event ev = slot.event;
            slot.sequence.store(readPos_ + uint32_t(kEventQueueSize), std::memory_order_release);
            ++readPos_;
            switch (ev.type) {
                case EventType::NoteOn: noteOn(ev.note, ev.value, ev.channel); break;
                case EventType::NoteOff: noteOff(ev.note, ev.channel); break;
                case EventType::Sustain: sustain(ev.value >= 0.5f, ev.channel); break;
                case EventType::Panic: panic(); break;
                case EventType::PitchBend: pitchBend(ev.value, ev.channel); break;
                case EventType::ControlChange: controlChange(ev.note, int(std::lround(ev.value)), ev.channel); break;
            }
        } else {
            break;
        }
    }
}

const std::array<LayerParams, Engine::kNumLayers>& Engine::audioLayerParams() noexcept {
    // Try-lock: se a UI estiver segurando o lock neste exato instante, usamos a cópia anterior.
    // Assim a thread de áudio NUNCA fica girando esperando outra thread (evita dropouts/estalos).
    uint32_t expected = 0;
    if (paramLock_.compare_exchange_strong(expected, 1, std::memory_order_acquire)) {
        audioLps_ = layerParams_;
        paramLock_.store(0, std::memory_order_release);
    }
    return audioLps_;
}

void Engine::beginKill(Voice& v, float seconds) noexcept {
    if (!v.active) return;
    const float samples = std::max(16.0f, seconds * float(sampleRate_));
    const float step = 1.0f / samples;
    if (v.killing) {
        v.killStep = std::max(v.killStep, step);  // só acelera, nunca reinicia a rampa
    } else {
        v.killing = true;
        v.killGain = 1.0f;
        v.killStep = step;
    }
    v.keyHeld = false;
    v.sustained = false;
}

void Engine::hardStealVoice(Voice& v) noexcept {
    v.active = false;
    v.killing = false;
    v.fadeOutRemaining = 0;
    v.fadeOutL = 0.0f;
    v.fadeOutR = 0.0f;
    v.lastL = 0.0f;
    v.lastR = 0.0f;
}

Engine::Voice& Engine::allocateVoice(int /*layer*/, int /*note*/, bool /*isReleaseVoice*/, bool /*legatoMono*/) noexcept {
    const int maxV = std::clamp(maxVoices_.load(std::memory_order_relaxed), 16, kMaxVoices);

    // 1. Slot totalmente livre
    for (int i = 0; i < maxV; ++i) {
        auto& v = voices_[i];
        if (!v.active && v.fadeOutRemaining == 0) return v;
    }
    // 2. Slot inativo
    for (int i = 0; i < maxV; ++i) {
        auto& v = voices_[i];
        if (!v.active) return v;
    }
    // 3. Rouba a voz MAIS SILENCIOSA (priorizando vozes que já estão morrendo em killing ou release)
    Voice* candidate = nullptr;
    float candidateLevel = 1.0e30f;
    for (int i = 0; i < maxV; ++i) {
        auto& v = voices_[i];
        float level = float(v.loopEnv * v.relEnv) * v.baseGain * (v.killing ? v.killGain : 1.0f);
        if (!(v.killing || v.releasing || v.isReleaseVoice)) level += 10.0f;
        if (level < candidateLevel) {
            candidateLevel = level;
            candidate = &v;
        }
    }
    if (!candidate) candidate = &voices_[0];
    hardStealVoice(*candidate);
    return *candidate;
}

void Engine::noteOn(int triggerKey, float rawVelocity, int channel) {
    if (triggerKey < 0 || triggerKey > 127) return;
    if (rawVelocity <= 0.0f) {
        noteOff(triggerKey, channel);
        return;
    }

    const int globalCh = globalMidiChannel_.load(std::memory_order_relaxed);
    if (channel > 0 && globalCh > 0 && channel != globalCh) return;

    std::array<LayerParams, kNumLayers> lps;
    {
        ScopedSpinLock lock(paramLock_);
        lps = layerParams_;
    }

    const int globalTranspose = transpose_.load(std::memory_order_relaxed);
    const int globalCurve = velCurve_.load(std::memory_order_relaxed);
    const float baseHz = baseTuningHz_.load(std::memory_order_relaxed);
    const float a4OffsetCents = float(1200.0 * std::log2(std::max(400.0, double(baseHz)) / 440.0));
    const float globalFineCents = fineTuneCents_.load(std::memory_order_relaxed) + a4OffsetCents;
    const double globalRelScale = std::clamp(double(releaseScale_.load(std::memory_order_relaxed)), 0.15, 3.0);

    bool anyTriggered = false;
    uint8_t displayVelByte = uint8_t(std::clamp(int(std::lround(rawVelocity * 127.0f)), 1, 127));

    for (int layer = 0; layer < kNumLayers; ++layer) {
        const Instrument* inst = instruments_[layer].load(std::memory_order_acquire);
        const LayerParams& lp = lps[layer];
        if (!inst || !lp.enabled) continue;

        // Filtro de canal da camada
        if (channel > 0 && lp.midiChannel > 0 && lp.midiChannel != channel) continue;

        // Faixa de teclas da camada (K. LOW / K. HIGH)
        const int kLo = std::min(lp.keyLow, lp.keyHigh);
        const int kHi = std::max(lp.keyLow, lp.keyHigh);
        if (triggerKey < kLo || triggerKey > kHi) continue;

        // Faixa de velocity da camada (V. LOW / V. HIGH)
        const int vel127 = int(std::lround(rawVelocity * 127.0f));
        const int vLo = std::min(lp.velLow, lp.velHigh);
        const int vHi = std::max(lp.velLow, lp.velHigh);
        if (vel127 < vLo || vel127 > vHi) continue;

        float effVel = rawVelocity;
        if (lp.fixedVelocity) {
            effVel = std::clamp(float(lp.fixedVelocityValue) / 127.0f, 0.01f, 1.0f);
        } else {
            effVel = applyGlobalVelocityCurve(effVel, globalCurve);
            effVel = applyLayerVelocityCurve(effVel, lp.velocityCurve);
        }
        if (softPedal_) {
            effVel = std::max(0.02f, effVel * 0.80f);
        }

        // Perfil de Timbre (Seção 5: Bright / Mid / Soft / Dyno1 / Dyno2)
        float sampleSelectVel = effVel;
        float timbreGainTrim = 1.0f;
        switch (lp.timbreMode) {
            case 1: // Bright
                sampleSelectVel = std::min(1.0f, effVel * 1.18f + 0.06f);
                timbreGainTrim = 1.05f;
                break;
            case 2: // Soft
                sampleSelectVel = std::max(0.02f, effVel * 0.76f);
                timbreGainTrim = 0.92f;
                break;
            case 3: // Dyno1
                sampleSelectVel = std::pow(effVel, 0.78f);
                timbreGainTrim = 1.12f;
                break;
            case 4: // Dyno2
                sampleSelectVel = std::pow(effVel, 0.62f);
                timbreGainTrim = 1.18f;
                break;
            default: // Mid (0)
                break;
        }

        // Suaviza qualquer nota anterior nesta mesma tecla/camada (elimina estalo ao repetir notas rapidamente)
        for (auto& oldV : voices_) {
            if (oldV.active && oldV.layer == layer) {
                if (lp.legatoMono || oldV.triggerKey == triggerKey) {
                    beginKill(oldV, lp.legatoMono ? 0.015f : 0.025f);
                }
            }
        }

        const int note = std::clamp(triggerKey + globalTranspose + lp.octaveShift * 12, 0, 127);
        const Sample* s = inst->select(note, sampleSelectVel);
        if (!s || s->frames == 0 || s->pcm.empty()) continue;

        Voice& v = allocateVoice(layer, note, false, lp.legatoMono);

        const int prevNote = layerState_[layer].lastNote;
        layerState_[layer].lastNote = note;

        const float fineCents = globalFineCents + float(inst->cents[note]) + s->fineTuneCents;
        const double semitoneOffset = double(note - int(s->root)) + double(fineCents) / 100.0;
        const double pitchRatio = std::exp2(semitoneOffset / 12.0);
        const double baseStep = (s->rate / sampleRate_) * pitchRatio;

        v.sample = s;
        v.layer = uint8_t(layer);
        v.note = note;
        v.triggerKey = triggerKey;
        v.active = true;
        v.isReleaseVoice = false;
        v.keyHeld = true;
        v.sustained = false;
        v.releasing = false;
        v.killing = false;
        v.killGain = 1.0f;
        v.killStep = 0.0f;
        v.fadeOutRemaining = 0;
        v.fadeOutL = 0.0f;
        v.fadeOutR = 0.0f;
        v.lastL = 0.0f;
        v.lastR = 0.0f;
        v.undamped = lp.undampedOn && (note >= inst->damperBoundary);
        v.age = ++voiceCounter_;
        v.pos = 0.0;
        v.baseStep = baseStep;

        if ((lp.portamentoOn || lp.legatoMono) && prevNote >= 0 && prevNote != note) {
            v.currentGlideSemis = double(prevNote - note);
            const double portSec = std::max(0.005, double(lp.portamentoTimeMs) * 0.001);
            v.glideDecayMul = std::exp(-5.0 / (portSec * sampleRate_));
        } else {
            v.currentGlideSemis = 0.0;
            v.glideDecayMul = 0.0;
        }

        v.baseGain = s->gain * Instrument::velocityGain(effVel) * inst->noteGainLinear[note] * timbreGainTrim;
        v.velNorm = std::clamp(effVel, 0.01f, 1.0f);
        v.loopEnv = 1.0;

        const double dt = s->decayRealtime ? (1.0 / sampleRate_) : (baseStep / s->rate);
        v.loopDecayMul = std::exp(-s->loopDecayDb * kLn10Over20 * dt);

        v.relEnv = 1.0;
        const double baseRelMs = lp.originalEnvelope ? double(s->releaseMs) : double(lp.releaseMs);
        const double relSec = std::max(0.015, baseRelMs * 0.001 * globalRelScale);
        v.relDecayMul = std::exp(-kReleaseTargetLn / (relSec * sampleRate_));

        v.attackEnv = 0.0f;
        if (lp.originalEnvelope || lp.attackMs <= 1.0f) {
            v.attackStep = 1.0f / 64.0f;
        } else {
            const double attSamples = std::max(64.0, double(lp.attackMs) * 0.001 * sampleRate_);
            v.attackStep = float(1.0 / attSamples);
        }

        anyTriggered = true;
    }

    if (anyTriggered) {
        keyState_[triggerKey].store(displayVelByte, std::memory_order_relaxed);
    }
}

void Engine::spawnReleaseVoice(int layer, int note, float envLevel, const Instrument* inst,
                               const LayerParams& lp) noexcept {
    if (!releaseEnabled_.load(std::memory_order_relaxed) || !lp.undampedOn) return;
    const float relGain = releaseSampleGain_.load(std::memory_order_relaxed);
    if (relGain <= 0.001f) return;
    if (!inst || envLevel <= 1.0e-5f) return;
    if (!lp.enabled || lp.volume <= 0.001f) return;  // Camada desligada ou muda nunca dispara release
    const Sample* relSample = inst->selectRelease(note);
    if (!relSample || relSample->frames == 0 || relSample->pcm.empty()) return;

    // Suaviza release sample anterior nesta mesma nota/camada
    for (auto& oldV : voices_) {
        if (oldV.active && oldV.layer == layer && oldV.triggerKey == note && oldV.isReleaseVoice) {
            beginKill(oldV, 0.015f);
        }
    }

    Voice& rv = allocateVoice(layer, note, true, false);

    const float baseHz = baseTuningHz_.load(std::memory_order_relaxed);
    const float a4OffsetCents = float(1200.0 * std::log2(std::max(400.0, double(baseHz)) / 440.0));
    const float fineCents = fineTuneCents_.load(std::memory_order_relaxed) + a4OffsetCents + float(inst->cents[note]);
    const double semitoneOffset = double(note - int(relSample->root)) + double(fineCents) / 100.0;
    const double step = (relSample->rate / sampleRate_) * std::exp2(semitoneOffset / 12.0);

    rv.sample = relSample;
    rv.layer = uint8_t(layer);
    rv.note = note;
    rv.triggerKey = note;
    rv.active = true;
    rv.isReleaseVoice = true;
    rv.keyHeld = false;
    rv.sustained = false;
    rv.releasing = false;
    rv.killing = false;
    rv.killGain = 1.0f;
    rv.killStep = 0.0f;
    rv.fadeOutRemaining = 0;
    rv.fadeOutL = 0.0f;
    rv.fadeOutR = 0.0f;
    rv.lastL = 0.0f;
    rv.lastR = 0.0f;
    rv.undamped = true;
    rv.age = ++voiceCounter_;
    rv.pos = 0.0;
    rv.baseStep = step;
    rv.currentGlideSemis = 0.0;
    rv.glideDecayMul = 0.0;
    // envLevel já traz o pico real atual da nota (escalado pela velocity da tecla e decaimento natural).
    // Normalizamos pelo pico do sample de soltura para que o ruído de abafador nunca ultrapasse ~16% da nota tocada.
    const float relPeak = float(std::max(256, relSample->peak));
    rv.baseGain = (envLevel / relPeak) * relGain;
    rv.velNorm = 1.0f;
    rv.loopEnv = 1.0;
    rv.loopDecayMul = 1.0;
    rv.relEnv = 1.0;
    rv.relDecayMul = std::exp(-kReleaseTargetLn / (0.25 * sampleRate_));
    rv.attackEnv = 0.0f;
    rv.attackStep = 1.0f / 64.0f;
}

void Engine::startReleaseOnVoice(Voice& v, const Instrument* inst, const LayerParams& lp,
                                 bool triggerRelSample) noexcept {
    if (v.releasing) return;
    if (v.undamped) return;
    if (v.sample) {
        const double relScale = std::clamp(double(releaseScale_.load(std::memory_order_relaxed)), 0.15, 3.0);
        const double baseRelMs = lp.originalEnvelope ? double(v.sample->releaseMs) : double(lp.releaseMs);
        const double relSec = std::max(0.015, baseRelMs * 0.001 * relScale);
        v.relDecayMul = std::exp(-kReleaseTargetLn / (relSec * sampleRate_));
    }
    v.releasing = true;
    if (triggerRelSample && !v.isReleaseVoice && !v.killing && v.sample) {
        // Calcula a energia acústica real da corda no momento da soltura:
        // - v.baseGain * v.sample->peak reflete exatamente a força (velocity) com que a tecla foi tocada;
        // - preLoopDecay modela a queda natural da nota enquanto a tecla ficou pressionada antes do loop;
        // - velWeight (0.08 .. 0.18) garante que notas tocadas fraco tenham ruído de soltura suave e proporcional.
        const double elapsedSec = v.pos / std::max(1.0, double(v.sample->rate));
        const double decayDbPerSec = std::max(1.5, v.sample->loopDecayDb);
        const float heldDecay = float(std::exp(-decayDbPerSec * kLn10Over20 * elapsedSec));
        const float stringEnergy = std::min(float(v.loopEnv), heldDecay) * float(v.relEnv) * std::max(0.15f, v.attackEnv);
        const float currentNotePeak = v.baseGain * float(std::max(1, v.sample->peak)) * stringEnergy;
        const float velWeight = 0.08f + 0.10f * v.velNorm; // ~8% em notas suaves (pp), ~18% em notas fortes (ff)
        const float targetRelPeak = currentNotePeak * velWeight;
        spawnReleaseVoice(v.layer, v.note, targetRelPeak, inst, lp);
    }
}

void Engine::noteOff(int triggerKey, int channel) {
    if (triggerKey < 0 || triggerKey > 127) return;
    const int globalCh = globalMidiChannel_.load(std::memory_order_relaxed);
    if (channel > 0 && globalCh > 0 && channel != globalCh) return;

    keyState_[triggerKey].store(0, std::memory_order_relaxed);

    std::array<LayerParams, kNumLayers> lps;
    {
        ScopedSpinLock lock(paramLock_);
        lps = layerParams_;
    }

    for (auto& v : voices_) {
        if (!v.active || v.isReleaseVoice || v.killing) continue;
        const int layer = v.layer;
        const LayerParams& lp = lps[layer];
        if (channel > 0 && lp.midiChannel > 0 && lp.midiChannel != channel) continue;

        if (v.triggerKey == triggerKey && v.keyHeld) {
            v.keyHeld = false;
            if (sustainPedal_ && lp.sustainPedalOn && !v.undamped) {
                v.sustained = true;
            } else if (v.sostenutoHeld) {
                // Held by sostenuto pedal (CC66)
            } else {
                const Instrument* inst = instruments_[layer].load(std::memory_order_acquire);
                startReleaseOnVoice(v, inst, lp, true);
            }
        }
    }
}

void Engine::sustain(bool down, int channel) {
    const int globalCh = globalMidiChannel_.load(std::memory_order_relaxed);
    if (channel > 0 && globalCh > 0 && channel != globalCh) return;

    sustainPedalLevel_ = down ? 1.0f : 0.0f;
    if (sustainPedal_ == down) return;
    sustainPedal_ = down;
    sustainState_.store(down, std::memory_order_relaxed);

    if (!down) {
        std::array<LayerParams, kNumLayers> lps;
        {
            ScopedSpinLock lock(paramLock_);
            lps = layerParams_;
        }
        for (auto& v : voices_) {
            if (v.active && !v.isReleaseVoice && !v.keyHeld && v.sustained) {
                v.sustained = false;
                if (!v.sostenutoHeld) {
                    const int layer = v.layer;
                    const Instrument* inst = instruments_[layer].load(std::memory_order_acquire);
                    startReleaseOnVoice(v, inst, lps[layer], false);
                }
            }
        }
    }
}

void Engine::controlChange(int cc, int value127, int channel) {
    cc = std::clamp(cc, 0, 127);
    value127 = std::clamp(value127, 0, 127);
    const float norm = float(value127) / 127.0f;

    // 1. Pedals & standard performance CCs: CC64 (continuous half-pedaling), CC66 (sostenuto), CC67 (una corda), CC11 (expression), CC7 (volume)
    if (cc == 64) {
        sustainPedalLevel_ = norm;
        const bool down = (value127 >= 20);
        sustainState_.store(value127 >= 64, std::memory_order_relaxed);
        if (sustainPedal_ && !down) {
            sustainPedal_ = false;
            std::array<LayerParams, kNumLayers> lps;
            {
                ScopedSpinLock lock(paramLock_);
                lps = layerParams_;
            }
            for (auto& v : voices_) {
                if (v.active && !v.isReleaseVoice && !v.keyHeld && v.sustained) {
                    v.sustained = false;
                    if (!v.sostenutoHeld) {
                        const int layer = v.layer;
                        const Instrument* inst = instruments_[layer].load(std::memory_order_acquire);
                        startReleaseOnVoice(v, inst, lps[layer], false);
                    }
                }
            }
        } else {
            sustainPedal_ = down;
        }
        return;
    }

    if (cc == 66) {
        const bool down = (value127 >= 64);
        if (!sostenutoPedal_ && down) {
            sostenutoPedal_ = true;
            for (auto& v : voices_) {
                if (v.active && !v.isReleaseVoice && !v.killing && v.keyHeld) {
                    v.sostenutoHeld = true;
                }
            }
        } else if (sostenutoPedal_ && !down) {
            sostenutoPedal_ = false;
            std::array<LayerParams, kNumLayers> lps;
            {
                ScopedSpinLock lock(paramLock_);
                lps = layerParams_;
            }
            for (auto& v : voices_) {
                if (v.active && !v.isReleaseVoice && v.sostenutoHeld) {
                    v.sostenutoHeld = false;
                    if (!v.keyHeld && !v.sustained) {
                        const int layer = v.layer;
                        const Instrument* inst = instruments_[layer].load(std::memory_order_acquire);
                        startReleaseOnVoice(v, inst, lps[layer], false);
                    }
                }
            }
        }
        return;
    }

    if (cc == 67) {
        softPedal_ = (value127 >= 64);
    } else if (cc == 11) {
        expressionGain_ = std::clamp(norm, 0.0f, 1.0f);
    }

    // 2. Verifica MIDI Learn ativo
    const int learnLayer = midiLearnLayer_.load(std::memory_order_relaxed);
    const int learnSlot = midiLearnSlot_.load(std::memory_order_relaxed);
    if (learnLayer >= 0 && learnLayer < kNumLayers && learnSlot >= 0 && learnSlot <= 3 && cc != 64 && cc != 120 &&
        cc != 123) {
        ScopedSpinLock lock(paramLock_);
        LayerParams& lp = layerParams_[learnLayer];
        if (learnSlot == 0) lp.ccVolume = cc;
        else if (learnSlot == 1) lp.ccFilter = cc;
        else if (learnSlot == 2) lp.ccFxaAmount = cc;
        else if (learnSlot == 3) lp.ccFxaRelease = cc;
        midiLearnLayer_.store(-1, std::memory_order_relaxed);
        midiLearnSlot_.store(-1, std::memory_order_relaxed);
    }

    // 3. Aplica o CC aos sliders mapeados em cada camada
    bool mappedCC7 = false;
    {
        ScopedSpinLock lock(paramLock_);
        for (int layer = 0; layer < kNumLayers; ++layer) {
            LayerParams& lp = layerParams_[layer];
            if (channel > 0 && lp.midiChannel > 0 && lp.midiChannel != channel) continue;
            if (lp.ccVolume == cc) {
                lp.volume = norm * 1.25f;
                if (cc == 7) mappedCC7 = true;
            }
            if (lp.ccFilter == cc) lp.filter = norm;
            if (lp.ccFxaAmount == cc) lp.fxaAmount = norm;
            if (lp.ccFxaRelease == cc) lp.fxaRelease = norm;
        }
    }
    if (cc == 7 && !mappedCC7) {
        channelVolumeGain_ = std::clamp(norm, 0.0f, 1.0f);
    }
}

void Engine::pitchBend(float normalizedOrSemis, int /*channel*/) {
    // Se vier em semitons (-2..+2), normaliza para -1..+1
    if (std::fabs(normalizedOrSemis) > 1.001f) {
        pitchBendNorm_ = std::clamp(normalizedOrSemis * 0.5f, -1.0f, 1.0f);
    } else {
        pitchBendNorm_ = std::clamp(normalizedOrSemis, -1.0f, 1.0f);
    }
}

void Engine::panic() {
    sustainPedal_ = false;
    sustainPedalLevel_ = 0.0f;
    sostenutoPedal_ = false;
    softPedal_ = false;
    sustainState_.store(false, std::memory_order_relaxed);
    for (auto& k : keyState_) k.store(0, std::memory_order_relaxed);
    for (auto& st : layerState_) st.lastNote = -1;
    for (auto& v : voices_) {
        v.active = false;
        v.killing = false;
        v.keyHeld = false;
        v.sustained = false;
        v.sostenutoHeld = false;
        v.releasing = false;
        v.fadeOutRemaining = 0;
        v.fadeOutL = 0.0f;
        v.fadeOutR = 0.0f;
        v.lastL = 0.0f;
        v.lastR = 0.0f;
    }
}

void Engine::render(float* outL, float* outR, int numFrames) noexcept {
    if (numFrames <= 0) return;
    drainEvents();

    std::memset(outL, 0, size_t(numFrames) * sizeof(float));
    std::memset(outR, 0, size_t(numFrames) * sizeof(float));

    std::array<const Instrument*, kNumLayers> insts{};
    for (int l = 0; l < kNumLayers; ++l) {
        insts[l] = instruments_[l].load(std::memory_order_acquire);
    }

    std::array<LayerParams, kNumLayers> lps;
    std::array<ModulatorParams, 2> mods;
    DelayParams dly;
    ReverbParams rev;
    {
        ScopedSpinLock lock(paramLock_);
        lps = layerParams_;
        mods = modParams_;
        dly = delayParams_;
        rev = reverbParams_;
    }

    // Calcula pitch bend em semitons por camada + Mod 1/2 de Pitch
    float modPitchSemis = 0.0f;
    for (int m = 0; m < 2; ++m) {
        if (mods[m].enabled && mods[m].target == 2) {
            const float lfo = evalLfoWave(mods[m].wave, modPhase_[m], modEnvFollower_);
            modPitchSemis += lfo * mods[m].depth * 0.75f; // até +-0.75 semitom de vibrato
        }
    }

    std::array<double, kNumLayers> layerPitchFactor{};
    for (int l = 0; l < kNumLayers; ++l) {
        const float pbSemis = (pitchBendNorm_ >= 0.0f)
                                  ? (pitchBendNorm_ * float(lps[l].pitchBendUp))
                                  : (-pitchBendNorm_ * float(lps[l].pitchBendDown));
        layerPitchFactor[l] = std::exp2(double(pbSemis + modPitchSemis) / 12.0);
    }

    const int maxV = std::clamp(maxVoices_.load(std::memory_order_relaxed), 16, kMaxVoices);
    int activeCount = 0;
    std::array<int, kNumLayers> layerCounts{0, 0, 0, 0};

    // Coeficientes de filtro e compressor por camada
    std::array<float, kNumLayers> layerLpAlpha{};
    std::array<float, kNumLayers> layerPresenceGain{};
    for (int l = 0; l < kNumLayers; ++l) {
        float cutoffNorm = std::clamp(lps[l].filter, 0.0f, 1.0f);
        if (lps[l].timbreMode == 2) cutoffNorm *= 0.68f;       // Soft
        else if (lps[l].timbreMode == 1) cutoffNorm = std::min(1.0f, cutoffNorm * 1.15f); // Bright

        // Frequência exponencial de 140 Hz a 20000 Hz
        const double fc = 140.0 * std::pow(142.857, double(cutoffNorm));
        const double x = std::exp(-kTwoPi * std::min(fc, sampleRate_ * 0.48) / sampleRate_);
        layerLpAlpha[l] = float(1.0 - x);

        if (lps[l].timbreMode == 1) layerPresenceGain[l] = 0.35f;      // Bright
        else if (lps[l].timbreMode == 3) layerPresenceGain[l] = 0.55f; // Dyno1
        else if (lps[l].timbreMode == 4) layerPresenceGain[l] = 0.85f; // Dyno2
        else layerPresenceGain[l] = 0.0f;
    }

    // Renderização das vozes por camada (em blocos pequenos de 64 amostras para manter L1 cache sem alocar)
    constexpr int kChunk = 64;
    int offset = 0;
    while (offset < numFrames) {
        const int chunk = std::min(kChunk, numFrames - offset);
        float layerBufL[kNumLayers][kChunk] = {};
        float layerBufR[kNumLayers][kChunk] = {};

        for (int vi = 0; vi < maxV; ++vi) {
            auto& v = voices_[vi];
            if (!v.active || !v.sample) continue;
            const int l = v.layer;
            if (!insts[l] || !lps[l].enabled || lps[l].volume <= 0.0001f) {
                v.active = false;
                v.killing = false;
                v.lastL = v.lastR = 0.0f;
                continue;
            }

            const Sample& s = *v.sample;
            const uint32_t loopEnd = (s.loopLength > 0) ? (s.loopStart + s.loopLength) : 0;
            const double loopLenD = double(s.loopLength);
            const double framesD = double(s.frames);
            const double pbFactor = layerPitchFactor[l];

            for (int i = 0; i < chunk; ++i) {
                if (s.loopLength > 0) {
                    while (v.pos >= double(loopEnd)) {
                        v.pos -= loopLenD;
                    }
                } else if (v.pos >= framesD) {
                    v.active = false;
                    v.killing = false;
                    v.lastL = v.lastR = 0.0f;
                    break;
                }

                const uint32_t idx = uint32_t(v.pos);
                const float frac = float(v.pos - double(idx));
                float rawL = 0.0f, rawR = 0.0f;
                sampleHermiteStereo(s, idx, frac, rawL, rawR);

                if (s.loopLength > 0 && v.pos >= double(s.loopStart) * 0.25) {
                    v.loopEnv *= v.loopDecayMul;
                }
                if (v.sustained && !v.keyHeld && !v.sostenutoHeld && sustainPedalLevel_ < 0.85f) {
                    const double dampFactor = std::clamp(1.0 - double(sustainPedalLevel_) / 0.85, 0.0, 1.0);
                    const double halfPedalDecayMul = std::exp(-(dampFactor * 18.0) * kLn10Over20 / sampleRate_);
                    v.loopEnv *= halfPedalDecayMul;
                }
                if (v.releasing) {
                    v.relEnv *= v.relDecayMul;
                }

                float env = float(v.loopEnv * v.relEnv);
                if (env < 1.0e-5f) {
                    v.active = false;
                    v.killing = false;
                    v.lastL = v.lastR = 0.0f;
                    break;
                }

                if (v.killing) {
                    v.killGain -= v.killStep;
                    if (v.killGain <= 0.0f) {
                        v.active = false;
                        v.killing = false;
                        v.lastL = v.lastR = 0.0f;
                        break;
                    }
                    env *= v.killGain;
                }

                if (s.loopLength == 0 && (framesD - v.pos) < 128.0) {
                    env *= float(std::max(0.0, (framesD - v.pos) / 128.0));
                }

                if (v.attackEnv < 1.0f) {
                    env *= v.attackEnv;
                    v.attackEnv = std::min(1.0f, v.attackEnv + v.attackStep);
                }

                const float gain = v.baseGain * env;
                const float sL = rawL * gain;
                const float sR = rawR * gain;
                v.lastL = sL;
                v.lastR = sR;
                layerBufL[l][i] += sL;
                layerBufR[l][i] += sR;

                double step = v.baseStep * pbFactor;
                if (std::fabs(v.currentGlideSemis) > 1.0e-3) {
                    step *= std::exp2(v.currentGlideSemis / 12.0);
                    v.currentGlideSemis *= v.glideDecayMul;
                }
                v.pos += step;
            }
        }

        // Processa filtro de cada camada, presença Dyno/Bright, Compressor e FXA (Chorus/Ambience da camada)
        for (int l = 0; l < kNumLayers; ++l) {
            if (!lps[l].enabled || !insts[l] || lps[l].volume <= 0.0001f) continue;
            auto& st = layerState_[l];
            const float vol = lps[l].volume * expressionGain_ * channelVolumeGain_;
            const float alpha = layerLpAlpha[l];
            const float pres = layerPresenceGain[l];
            const bool compOn = lps[l].compOn && (lps[l].compAmount > 0.01f);
            const float compAmt = lps[l].compAmount;
            const float compAtt = lps[l].compFast ? 0.015f : 0.002f;
            const float compRel = 0.0004f;
            const float fxaAmt = lps[l].fxaAmount;
            const float fxaRate = (0.35f + 1.8f * (1.0f - lps[l].fxaRelease)) / float(sampleRate_);
            const float fxaTailDecay = float(std::exp(-1.0 / (std::max(0.08, double(lps[l].fxaRelease) * 1.8) * sampleRate_)));

            for (int i = 0; i < chunk; ++i) {
                float xL = layerBufL[l][i];
                float xR = layerBufR[l][i];

                // Filtro Passa-Baixas da camada
                st.lpZ1L += alpha * (xL - st.lpZ1L);
                st.lpZ1R += alpha * (xR - st.lpZ1R);
                xL = st.lpZ1L;
                xR = st.lpZ1R;

                // Presença harmônica (Bright / Dyno1 / Dyno2)
                if (pres > 0.0f) {
                    st.hpZ1L += 0.18f * (xL - st.hpZ1L);
                    st.hpZ1R += 0.18f * (xR - st.hpZ1R);
                    const float hiL = xL - st.hpZ1L;
                    const float hiR = xR - st.hpZ1R;
                    xL += hiL * pres;
                    xR += hiR * pres;
                }

                // Compressor da camada (COMP + AMOUNT + FAST)
                if (compOn) {
                    const float absMax = std::max(std::fabs(xL), std::fabs(xR));
                    const float coeff = (absMax > st.compEnv) ? compAtt : compRel;
                    st.compEnv += coeff * (absMax - st.compEnv);
                    const float thresh = 0.18f;
                    if (st.compEnv > thresh) {
                        const float over = st.compEnv / thresh;
                        const float gr = std::pow(over, -0.65f * compAmt);
                        xL *= gr;
                        xR *= gr;
                    }
                    const float makeup = 1.0f + 0.55f * compAmt;
                    xL *= makeup;
                    xR *= makeup;
                }

                // Efeito FXA da camada (FXA AM + FXA RT: Chorus Estéreo + Cauda de Ambiência)
                if (fxaAmt > 0.005f) {
                    st.fxaPhase += fxaRate;
                    if (st.fxaPhase >= 1.0f) st.fxaPhase -= 1.0f;
                    const float mod = float(std::sin(st.fxaPhase * kTwoPi));
                    st.fxaEnvL = st.fxaEnvL * fxaTailDecay + xL * (1.0f - fxaTailDecay) * (1.0f + 0.25f * mod);
                    st.fxaEnvR = st.fxaEnvR * fxaTailDecay + xR * (1.0f - fxaTailDecay) * (1.0f - 0.25f * mod);
                    xL = xL * (1.0f - 0.35f * fxaAmt) + (st.fxaEnvR * 0.8f) * fxaAmt;
                    xR = xR * (1.0f - 0.35f * fxaAmt) + (st.fxaEnvL * 0.8f) * fxaAmt;
                }

                // Limitador de headroom polifônico por camada (especialmente para acordes sustentados em .nsmp4)
                const float layerPeak = std::max(std::fabs(xL), std::fabs(xR));
                const float layerCeil = insts[l]->isNsmp4 ? 0.48f : 0.72f;
                const float targetLim = (layerPeak > layerCeil) ? (layerCeil / layerPeak) : 1.0f;
                if (targetLim < st.layerLimiterGain) {
                    st.layerLimiterGain += 0.25f * (targetLim - st.layerLimiterGain); // ataque rápido (~0.1 ms)
                } else {
                    st.layerLimiterGain += 0.0005f * (1.0f - st.layerLimiterGain);    // release suave (~40 ms)
                }
                xL *= st.layerLimiterGain;
                xR *= st.layerLimiterGain;

                outL[offset + i] += xL * vol;
                outR[offset + i] += xR * vol;
            }
        }

        offset += chunk;
    }

    // Conta vozes ativas totais e por camada
    for (int vi = 0; vi < maxV; ++vi) {
        if (voices_[vi].active) {
            ++activeCount;
            if (voices_[vi].layer < kNumLayers) ++layerCounts[voices_[vi].layer];
        }
    }

    // Seção 6 & 7: Mod 1/2 (Volume/Filter/Pan), Equalizador 3 Bandas, Drive, Delay (Ping-Pong) e Reverb Estéreo
    updateEqCoefficientsIfNeeded();
    const bool eqActive = (std::fabs(lastBassDb_) > 0.01f ||
                           std::fabs(lastMidDb_) > 0.01f ||
                           std::fabs(lastTrebleDb_) > 0.01f);
    const bool drvOn = driveEnabled_.load(std::memory_order_relaxed);
    const float drvAmt = driveAmount_.load(std::memory_order_relaxed);
    const float master = masterGain_.load(std::memory_order_relaxed);
    const float pan = masterPan_.load(std::memory_order_relaxed);
    const float panGainL = std::min(1.0f, 1.0f - pan);
    const float panGainR = std::min(1.0f, 1.0f + pan);

    // Tempo de Delay efetivo (livre ou sincronizado ao BPM)
    float effDelayMs = dly.timeMs;
    if (dly.syncToHost && dly.hostBpm > 20.0f) {
        const float quarterMs = 60000.0f / dly.hostBpm;
        switch (dly.syncDivision) {
            case 0: effDelayMs = quarterMs; break;         // 1/4
            case 1: effDelayMs = quarterMs * 0.5f; break;  // 1/8
            case 2: effDelayMs = quarterMs * 0.75f; break; // 1/8 Dotted
            case 3: effDelayMs = quarterMs * 0.3333f; break; // 1/8 Triplet
            case 4: effDelayMs = quarterMs * 0.25f; break; // 1/16
            default: effDelayMs = quarterMs * 0.5f; break;
        }
    }
    const size_t delaySamples = std::clamp<size_t>(
        size_t(effDelayMs * 0.001f * float(sampleRate_)), 16,
        delayBufL_.empty() ? 16 : (delayBufL_.size() - 1));
    const float dlyFb = std::clamp(dly.feedback, 0.0f, 0.92f);
    const float dlyMix = std::clamp(dly.amount, 0.0f, 1.0f);

    // Parâmetros de Reverb
    const size_t preDelaySamples = std::clamp<size_t>(
        size_t(rev.preDelayMs * 0.001f * float(sampleRate_)), 1,
        revPreDelayBuf_.empty() ? 1 : (revPreDelayBuf_.size() - 1));
    const float revFeedback = std::clamp(0.70f + 0.26f * (0.5f * rev.size + 0.5f * rev.decay), 0.70f, 0.965f);
    const float revDamp = std::clamp(rev.damping * 0.65f, 0.05f, 0.75f);
    const float revMix = std::clamp(rev.amount, 0.0f, 1.0f);

    float maxL = 0.0f, maxR = 0.0f;
    for (int i = 0; i < numFrames; ++i) {
        float l = outL[i];
        float r = outR[i];

        // Seguidor de envelope para Mod Wave = Envelope
        const float inAbs = 0.5f * (std::fabs(l) + std::fabs(r));
        modEnvFollower_ = modEnvFollower_ * 0.998f + inAbs * 0.002f;

        // Mod 1 & Mod 2
        float modGainL = 1.0f, modGainR = 1.0f;
        for (int m = 0; m < 2; ++m) {
            if (!mods[m].enabled || mods[m].depth <= 0.001f) continue;
            modPhase_[m] += double(mods[m].rateHz) / sampleRate_;
            if (modPhase_[m] >= 1.0) modPhase_[m] -= 1.0;
            const float lfo = evalLfoWave(mods[m].wave, modPhase_[m], modEnvFollower_);
            const float d = mods[m].depth;
            if (mods[m].target == 0) {
                // Volume (Tremolo)
                const float g = 1.0f - d * 0.45f * (1.0f - lfo);
                modGainL *= g;
                modGainR *= g;
            } else if (mods[m].target == 1) {
                // Filter / Wah dinâmico
                const float bright = 1.0f + d * 0.55f * lfo;
                l *= bright;
                r *= bright;
            } else if (mods[m].target == 3) {
                // Auto-Pan Estéreo
                modGainL *= (1.0f - d * 0.5f * std::max(0.0f, lfo));
                modGainR *= (1.0f - d * 0.5f * std::max(0.0f, -lfo));
            }
        }
        l *= modGainL;
        r *= modGainR;

        // Equalizador de 3 bandas
        if (eqActive) {
            eqLow_.processStereo(l, r);
            eqMid_.processStereo(l, r);
            eqHigh_.processStereo(l, r);
        }

        // Drive / Saturação harmônica estilo válvula/fita Nord (zero DC offset)
        if (drvOn && drvAmt > 0.005f) {
            const float driveGain = 1.0f + drvAmt * 5.0f;
            const float comp = 1.0f / (1.0f + drvAmt * 1.35f);
            auto tubeSat = [driveGain, comp](float x) noexcept -> float {
                float in = x * driveGain;
                float sat = (in >= 0.0f) ? std::tanh(in * 1.15f) : (std::tanh(in * 0.90f) * 1.10f);
                return sat * comp;
            };
            l = tubeSat(l);
            r = tubeSat(r);
        }

        // Delay Estéreo / Ping-Pong
        if (dly.enabled && dlyMix > 0.001f && !delayBufL_.empty()) {
            const size_t bufSize = delayBufL_.size();
            const size_t readIdx = (delayWriteIdx_ + bufSize - delaySamples) % bufSize;
            const float dL = delayBufL_[readIdx];
            const float dR = delayBufR_[readIdx];

            delayLpL_ = 0.65f * dL + 0.35f * delayLpL_;
            delayLpR_ = 0.65f * dR + 0.35f * delayLpR_;

            if (dly.pingPong) {
                delayBufL_[delayWriteIdx_] = l * 0.75f + delayLpR_ * dlyFb;
                delayBufR_[delayWriteIdx_] = r * 0.75f + delayLpL_ * dlyFb;
            } else {
                delayBufL_[delayWriteIdx_] = l + delayLpL_ * dlyFb;
                delayBufR_[delayWriteIdx_] = r + delayLpR_ * dlyFb;
            }
            if (++delayWriteIdx_ >= bufSize) delayWriteIdx_ = 0;

            l += dL * dlyMix * 0.75f;
            r += dR * dlyMix * 0.75f;
        }

        // Reverb Estéreo Studio (Pre-Delay + 4 Combs Paralelos + 2 Allpasses em Série)
        if (rev.enabled && revMix > 0.001f && !revPreDelayBuf_.empty()) {
            const size_t pdSize = revPreDelayBuf_.size();
            const size_t pdRead = (revPreWriteIdx_ + pdSize - preDelaySamples) % pdSize;
            const float monoIn = (l + r) * 0.25f;
            const float pdOut = revPreDelayBuf_[pdRead];
            revPreDelayBuf_[revPreWriteIdx_] = monoIn;
            if (++revPreWriteIdx_ >= pdSize) revPreWriteIdx_ = 0;

            float wetL = 0.0f, wetR = 0.0f;
            for (int c = 0; c < 4; ++c) {
                wetL += combL_[c].process(pdOut, revFeedback, revDamp);
                wetR += combR_[c].process(pdOut, revFeedback, revDamp);
            }
            for (int a = 0; a < 2; ++a) {
                wetL = allpassL_[a].process(wetL);
                wetR = allpassR_[a].process(wetR);
            }
            l = l * (1.0f - revMix * 0.30f) + wetL * revMix * 0.28f;
            r = r * (1.0f - revMix * 0.30f) + wetR * revMix * 0.28f;
        }

        // Master Volume + Master Pan + Limitador Brickwall Transparente + Soft-Knee Contínuo (C¹)
        l *= master * panGainL;
        r *= master * panGainR;

        const float stereoPeak = std::max(std::fabs(l), std::fabs(r));
        constexpr float kLimThresh = 0.84f;
        const float desiredGain = (stereoPeak > kLimThresh) ? (kLimThresh / stereoPeak) : 1.0f;
        if (desiredGain < masterLimiterGain_) {
            masterLimiterGain_ += 0.35f * (desiredGain - masterLimiterGain_);
        } else {
            masterLimiterGain_ += 0.0003f * (1.0f - masterLimiterGain_);
        }
        l *= masterLimiterGain_;
        r *= masterLimiterGain_;

        auto softKnee = [](float x) noexcept -> float {
            const float ax = std::fabs(x);
            constexpr float kKnee = 0.85f;
            constexpr float kHead = 0.13f; // teto assintótico em 0.98 (-0.17 dBFS)
            if (ax <= kKnee) return x;
            const float y = kKnee + kHead * std::tanh((ax - kKnee) / kHead);
            return (x >= 0.0f) ? y : -y;
        };
        l = softKnee(l);
        r = softKnee(r);

        outL[i] = l;
        outR[i] = r;
        maxL = std::max(maxL, std::fabs(l));
        maxR = std::max(maxR, std::fabs(r));
    }

    activeVoices_.store(activeCount, std::memory_order_relaxed);
    for (int l = 0; l < kNumLayers; ++l) {
        layerActiveVoices_[l].store(layerCounts[l], std::memory_order_relaxed);
    }
    if (maxL > peakL_.load(std::memory_order_relaxed)) peakL_.store(maxL, std::memory_order_relaxed);
    if (maxR > peakR_.load(std::memory_order_relaxed)) peakR_.store(maxR, std::memory_order_relaxed);
}

}  // namespace npno
