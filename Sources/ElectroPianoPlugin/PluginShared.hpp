#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "npno/Document.hpp"
#include "npno/Engine.hpp"
#include "npno/Instrument.hpp"

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
#endif

namespace epno {

/// IDs de parâmetros expostos para o host (MainStage / Logic / VST3).
enum ParamID : uint32_t {
    kParamMasterGainDb = 0,   // -36.0 .. +12.0 dB (default 0.0)
    kParamVelocityCurve = 1,  // 0 = Leve, 1 = Normal, 2 = Pesada (default 1)
    kParamTranspose = 2,      // -12 .. +12 semitons (default 0)
    kParamTuningHz = 3,       // 432.0 .. 446.0 Hz (default 440.0)
    kParamReleaseSamples = 4, // 0.0 .. 200.0 % Nível do Ruído de Soltura (default 100.0)
    kParamSustainPedal = 5,   // 0 ou 1 (default 0)
    kParamReleaseTime = 6,    // 20.0 .. 250.0 % Tempo de Release (default 100.0)
    kParamEqBassDb = 7,       // -15.0 .. +15.0 dB (default 0.0)
    kParamEqMidDb = 8,        // -15.0 .. +15.0 dB (default 0.0)
    kParamEqMidFreqHz = 9,    // 200.0 .. 5000.0 Hz (default 1000.0)
    kParamEqTrebleDb = 10,    // -15.0 .. +15.0 dB (default 0.0)
    kNumParams = 11
};

struct ParamSpec {
    uint32_t id;
    const char* name;
    const char* unitLabel;
    float minVal;
    float maxVal;
    float defaultVal;
    bool isStepped;
};

inline constexpr ParamSpec kParamSpecs[kNumParams] = {
    {kParamMasterGainDb, "Volume Master", "dB", -36.0f, 12.0f, 0.0f, false},
    {kParamVelocityCurve, "Curva de Velocidade", "", 0.0f, 2.0f, 1.0f, true},
    {kParamTranspose, "Transposicao", "st", -12.0f, 12.0f, 0.0f, true},
    {kParamTuningHz, "Afinacao A4", "Hz", 432.0f, 446.0f, 440.0f, false},
    {kParamReleaseSamples, "Ruido de Soltura", "%", 0.0f, 200.0f, 100.0f, false},
    {kParamSustainPedal, "Pedal Sustain", "", 0.0f, 1.0f, 0.0f, true},
    {kParamReleaseTime, "Release", "%", 20.0f, 250.0f, 100.0f, false},
    {kParamEqBassDb, "EQ Bass", "dB", -15.0f, 15.0f, 0.0f, false},
    {kParamEqMidDb, "EQ Mid Gain", "dB", -15.0f, 15.0f, 0.0f, false},
    {kParamEqMidFreqHz, "EQ Mid Freq", "Hz", 200.0f, 5000.0f, 1000.0f, false},
    {kParamEqTrebleDb, "EQ Treble", "dB", -15.0f, 15.0f, 0.0f, false},
};

/// Núcleo compartilhado entre AudioUnit (.component) e VST3 (.vst3).
class ElectroPianoCore {
public:
    ElectroPianoCore();
    ~ElectroPianoCore();

    npno::Engine& engine() { return engine_; }
    const npno::Engine& engine() const { return engine_; }

    void setSampleRate(double sr);
    double sampleRate() const { return sampleRate_.load(std::memory_order_relaxed); }

    /// Carrega um arquivo .npno ou .nsmp4 em uma camada (0=A, 1=B, 2=C, 3=D) em background.
    void loadLayerBankAsync(int layer, const std::string& path, bool preserveParams = false);
    void clearLayerBank(int layer);
    void stepLayerBankAsync(int layer, int delta);
    void loadBankAsync(const std::string& path) { loadLayerBankAsync(0, path); }

    /// Serialização completa do estado para DAWs (VST3 / AudioUnit).
    std::vector<uint8_t> serializeState() const;
    bool deserializeState(const uint8_t* data, size_t size);

    /// Callback para notificar o host (VST3 IComponentHandler / AU) quando a UI altera parâmetros.
    void setParamChangeCallback(std::function<void(uint32_t, float)> cb) {
        std::lock_guard<std::mutex> lk(cbMtx_);
        paramChangeCb_ = std::move(cb);
    }
    void notifyStateChanged();

    /// Purge e Reload de samples não usados na RAM.
    uint64_t purgeUnusedSamples();
    bool reloadPurgedSamples();
    uint64_t totalMemoryBytes() const;
    uint64_t totalUnpurgedBytes() const;

    /// Retorna caminhos disponíveis dos bancos .npno (embutidos no bundle, Application Support ou locais).
    static std::vector<std::string> findAllAvailableBankPaths();
    static std::string findDefaultBankPath();
    static void saveLastBankPath(const std::string& path);

    // Parâmetros (valores reais nas unidades de kParamSpecs)
    float getParam(uint32_t id) const;
    void setParam(uint32_t id, float value);
    void resetAllParams();

    // Filtro de canal MIDI (0 = Omni 1..16, 1..16 = canal específico)
    void setMidiChannel(int ch) {
        const int c = std::clamp(ch, 0, 16);
        midiChannel_.store(c, std::memory_order_relaxed);
        engine_.setGlobalMidiChannel(c);
    }
    int midiChannel() const { return midiChannel_.load(std::memory_order_relaxed); }

    // Normalizados [0..1] para VST3
    float getParamNormalized(uint32_t id) const;
    void setParamNormalized(uint32_t id, float norm);
    static float plainToNormalized(uint32_t id, float plain);
    static float normalizedToPlain(uint32_t id, float norm);

    // Eventos MIDI (seguro para chamada na thread de áudio ou UI)
    void handleMidiEvent(uint8_t status, uint8_t data1, uint8_t data2);
    void noteOn(int midiNote, uint8_t velocity);
    void noteOff(int midiNote);
    void setSustain(bool down);
    void setPitchBendSemitones(float semitones);
    void panic();

    // Demo musical integrada
    void toggleDemo();
    bool isDemoPlaying() const { return demoRunning_.load(std::memory_order_relaxed); }

    // Renderização em tempo real (lock-free, allocation-free)
    void render(float* outL, float* outR, int numFrames);

    // Telemetria para a GUI
    bool isLoading(int layer = 0) const {
        if (layer < 0 || layer >= 4) return false;
        return loading_[layer].load(std::memory_order_relaxed);
    }
    float loadProgress(int layer = 0) const {
        if (layer < 0 || layer >= 4) return 0.0f;
        return loadProgress_[layer].load(std::memory_order_relaxed);
    }
    float peakL() const { return peakL_.load(std::memory_order_relaxed); }
    float peakR() const { return peakR_.load(std::memory_order_relaxed); }
    int activeVoices() const { return engine_.activeVoices(); }
    bool sustainDown() const { return engine_.isSustainDown(); }
    uint64_t activeNotesLo() const { return activeNotesLo_.load(std::memory_order_relaxed); }
    uint64_t activeNotesHi() const { return activeNotesHi_.load(std::memory_order_relaxed); }

    struct BankSummary {
        bool loaded = false;
        std::string path;
        std::string title = "Slot Vazio";
        std::string subtitle = "Clique em LOAD";
        std::string version;
        uint32_t normalSamples = 0;
        uint32_t releaseSamples = 0;
        double memoryMB = 0.0;
        uint8_t damperBoundary = 88;
        int bankIndex = 0;
        int bankCount = 0;
        std::string error;
    };
    BankSummary getLayerSummary(int layer) const;
    BankSummary getBankSummary() const { return getLayerSummary(0); }

private:
    void applyPendingInstrumentOnAudioThread();
    void markNoteActive(int note, bool active);

    npno::Engine engine_;
    std::atomic<double> sampleRate_{44100.0};
    std::atomic<int> midiChannel_{0};

    // Instrumentos ativos por camada (A/B/C/D) e fila de troca sem bloqueio
    std::array<std::shared_ptr<npno::Instrument>, 4> audioThreadInst_{};
    std::array<std::shared_ptr<npno::Instrument>, 4> stagedInst_{};
    std::array<std::shared_ptr<npno::Instrument>, 4> retiredInst_{};
    std::array<std::atomic<bool>, 4> hasStagedInst_{};
    std::array<std::atomic<bool>, 4> preserveEnabledOnStage_{};
    std::atomic_flag stageSpin_ = ATOMIC_FLAG_INIT;

    mutable std::mutex cbMtx_;
    std::function<void(uint32_t, float)> paramChangeCb_;

    // Estado de carregamento em background por camada
    std::mutex loadMtx_;
    std::array<std::thread, 4> loadThread_{};
    std::array<std::atomic<uint64_t>, 4> loadGen_{};
    std::array<std::atomic<bool>, 4> loading_{};
    std::array<std::atomic<float>, 4> loadProgress_{};

    mutable std::mutex summaryMtx_;
    std::array<BankSummary, 4> summaries_{};
    std::array<std::vector<std::string>, 4> bankFiles_{};

    // Parâmetros
    std::atomic<float> params_[kNumParams];

    // Medidores
    std::atomic<float> peakL_{0.0f};
    std::atomic<float> peakR_{0.0f};
    std::atomic<uint64_t> activeNotesLo_{0};
    std::atomic<uint64_t> activeNotesHi_{0};

    // Demo thread
    std::atomic<bool> demoRunning_{false};
    std::thread demoThread_;
};

}  // namespace epno

#ifdef __OBJC__
/// Cria a NSView da Workstation Nord completa (1140x650, sem teclado na tela) conectada ao ElectroPianoCore.
NSView* CreateElectroPianoPluginView(epno::ElectroPianoCore* core, NSSize preferredSize);
#endif
