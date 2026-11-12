// Instrumento tocável construído a partir de um Document .npno.
//
// A lógica de camadas de velocidade, ganhos e decaimento segue o comportamento
// observado no reprodutor de referência (sharp::piano::Instrument), ver docs/NPNO_FORMAT.md.
#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "npno/Document.hpp"

namespace npno {

struct Sample {
    uint32_t sampleIndex = 0;   // índice em Instrument::samples
    uint32_t recordIndex = 0;   // índice original em Document::records
    uint8_t root = 0;
    uint8_t velParam = 0;       // 0 = camada mais forte
    uint32_t boundary = 0;      // limite inferior na curva de seleção (resolveLayerBoundaries)
    bool release = false;
    uint16_t channels = 2;
    double rate = kNativeSampleRate;
    uint32_t frames = 0;        // frames reproduzíveis
    uint32_t loopStart = 0;
    uint32_t loopLength = 0;    // 0 = sem loop
    float gain = 1.0f;          // inclui a conversão PCM16 -> float
    double loopDecayDb = 6.0;   // dB/s aplicado a partir do início do loop
    bool decayRealtime = false; // true: dB/s em tempo real; false: em tempo da amostra
    double envDecayDb = 0.0;    // segunda taxa (metadado +0x3A), informativa
    float releaseMs = 500.0f;   // tempo de abafamento
    float fineTuneCents = 0.0f; // ajuste fino por amostra (.nsmp4)
    uint8_t keyLow = 0;         // limite inferior da zona (.nsmp4)
    uint8_t keyHigh = 127;      // limite superior da zona (.nsmp4)
    uint8_t velLow = 0;         // velocidade mínima da zona (.nsmp4)
    uint8_t velHigh = 127;      // velocidade máxima da zona (.nsmp4)
    int peak = 1;
    std::vector<int16_t> pcm;   // intercalado, com frames extras no fim para interpolação
};

class Instrument {
public:
    using Progress = std::function<void(float)>;

    /// Carrega e decodifica um .npno ou .nsmp4. `cancel` (opcional) interrompe o carregamento.
    static std::unique_ptr<Instrument> load(const std::string& path, const Progress& progress,
                                            const std::atomic<bool>* cancel);

    std::string name;
    std::string model;
    std::string path;
    uint32_t fileVersion = 0;
    uint16_t channels = 2;
    uint32_t recordCount = 0;
    bool isNsmp4 = false;
    size_t decodedBytes = 0;
    size_t totalDecodedBytes = 0;
    int extendedEdgeKeys = 0;
    int damperBoundary = 128;   // notas >= limite não têm abafador
    int lowestNote = -1, highestNote = -1;

    std::vector<Sample> samples;
    mutable std::vector<uint8_t> sampleUsed;
    std::vector<uint8_t> samplePurged;
    std::array<std::vector<uint32_t>, 128> normalByRoot;
    std::array<std::vector<uint32_t>, 128> releaseByRoot;
    std::array<std::vector<uint32_t>, 128> samplesByNote;
    std::array<int, 128> keymap{};      // nota -> raiz (-1 = nenhuma)
    std::array<int, 128> cents{};       // afinação fina por nota
    std::array<int, 128> trim{};        // ganho por nota (x0.1 dB)
    std::array<float, 128> noteGainLinear{};

    /// Seleciona a amostra normal para a nota/velocidade (0..1). nullptr se não houver.
    const Sample* select(int note, float velocity) const;
    /// Seleciona a amostra de soltura (nullptr para notas sem abafador ou sem amostra).
    const Sample* selectRelease(int note) const;
    /// Curva de ganho por velocidade (0..1) -> ganho linear.
    static float velocityGain(float velocity);

    /// Descarrega da RAM todas as amostras que ainda não foram tocadas (Purge).
    /// Retorna a quantidade de bytes liberados.
    size_t purgeUnusedSamples();

    /// Recarrega do disco todas as amostras que foram descarregadas pelo Purge.
    bool reloadPurgedSamples();

    /// Limpa as marcações de amostras usadas.
    void resetUsedMarks() const;

    /// Quantidade de amostras atualmente residentes na RAM.
    size_t residentSampleCount() const;

    std::string summary() const;

private:
    void resolveLayerBoundaries(bool legacyScale);
};

}  // namespace npno
