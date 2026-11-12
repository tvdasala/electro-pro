// NPNOKit — leitura e decodificação de arquivos Nord Piano Library (.npno).
//
// Especificação reconstruída por análise estática (ver docs/NPNO_FORMAT.md).
// O arquivo de origem é SEMPRE aberto em modo somente leitura (mmap PROT_READ).
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace npno {

/// Erro de formato/integridade ao ler um .npno.
struct FormatError : std::runtime_error {
    using std::runtime_error::runtime_error;
};

/// Taxa de amostragem nativa de todas as amostras .npno (confirmada no binário de referência).
constexpr double kNativeSampleRate = 34990.0;

constexpr size_t kCnspSize = 0x732;      // 1842 bytes
constexpr size_t kRecordSize = 0x76;     // 118 bytes
constexpr uint32_t kBlockOverlap = 64;   // frames repetidos entre blocos consecutivos
constexpr uint32_t kMaxDecodedFrames = 0x01000000;

/// Tipo do registro (byte alto do campo +0x04).
enum class RecordKind : uint8_t {
    Normal = 0x00,   // amostra de ataque (key-on)
    Release = 0x02,  // ruído de soltura da tecla (key-off)
};

/// Registro de amostra (118 bytes em .npno, ou chunk \0stk em .nsmp4).
struct Record {
    uint32_t index = 0;          // posição na tabela
    uint8_t rootKey = 0;         // tecla MIDI que detém a amostra
    uint8_t kind = 0;            // +0x04 (byte alto)
    uint8_t velParam = 0;        // +0x05 (0 = camada mais forte)
    uint64_t absOffset = 0;      // offset absoluto dos blocos de áudio
    uint32_t decodedFrames = 0;  // +0x06
    uint16_t blockCount = 0;     // +0x0A
    int16_t initHist[2][4] = {}; // +0x0C..+0x13 (canal 0) e +0x14..+0x1B (canal 1): histórico inicial LPC
    int16_t initL = 0;           // +0x12 (hist[0][3], última semente do canal 0)
    int16_t initR = 0;           // +0x1A (hist[1][3], última semente do canal 1)
    uint32_t loopStart = 0;      // +0x1C (em frames)
    uint32_t loopLength = 0;     // +0x20 (em frames; 0 = sem loop)
    uint32_t loopDecayRaw = 0;   // +0x2E (UQ9.23)
    int16_t gainRef = 0;         // +0x32
    int16_t attenuation = 0;     // +0x34 (décimos de dB)
    uint32_t envDecayRaw = 0;    // +0x3A (UQ9.23)
    uint8_t releaseParam = 0;    // +0x72
    uint8_t layerMin = 0;        // +0x74 (limite de camada explícito; 0 = automático)
    std::array<uint8_t, kRecordSize> raw{};

    // --- Campos específicos de .nsmp4 (Nord Sample Library 4) ---
    bool isNsmp4 = false;
    uint32_t sampleId = 0;
    uint16_t channels = 2;
    uint32_t nsmpWordOffset = 0;
    uint32_t nsmpLoopStartWord = 0;
    uint32_t nsmpLoopEndWord = 0;
    uint32_t nsmpEndWord = 0;
    uint8_t keyLow = 0;
    uint8_t keyHigh = 127;
    uint8_t velLow = 0;
    uint8_t velHigh = 127;
    float fineTuneCents = 0.0f;
    float linearGain = 1.0f;

    bool isNormal() const { return kind == uint8_t(RecordKind::Normal); }
    bool isRelease() const { return kind == uint8_t(RecordKind::Release); }
};

/// Estatísticas devolvidas pela decodificação de um registro.
struct DecodeStats {
    uint32_t overlapMismatches = 0;   // frames de sobreposição divergentes entre blocos
    uint32_t loopCheckedSamples = 0;  // amostras verificadas na emenda do loop
    uint32_t loopMismatches = 0;      // divergências na emenda do loop
    uint32_t orderHistogram[5] = {};  // blocos por ordem do preditor
};

/// Documento .npno mapeado em memória (somente leitura).
class Document {
public:
    static std::unique_ptr<Document> open(const std::string& path);
    ~Document();

    Document(const Document&) = delete;
    Document& operator=(const Document&) = delete;

    // --- Container CBIN ---
    uint32_t containerVersion = 0;
    uint32_t fileVersion = 0;
    size_t headerLength = 0;
    size_t payloadEnd = 0;
    uint32_t storedCrc = 0;
    uint32_t computedCrc = 0;
    bool crcOk = false;
    bool isNsmp4 = false;

    // --- CNSP / NSMP ---
    std::string comboName;
    std::string name;
    std::string model;
    std::array<uint8_t, 128> keymap{};     // nota -> tecla raiz (0xFF = sem amostra)
    std::array<int8_t, 128> noteTrim{};    // décimos de dB por nota
    std::array<int8_t, 128> noteCents{};   // afinação fina por nota (cents)
    std::array<uint8_t, 128> damperFlags{};
    int8_t globalTrim = 0;                 // décimos de dB
    uint8_t damperBoundary = 0;            // primeira nota sem abafador (0 = não definido)
    uint16_t channels = 0;
    size_t blockBytes = 0;
    uint16_t totalRecords = 0;
    std::array<uint16_t, 128> perKeyCount{};

    std::vector<Record> records;
    size_t audioBase = 0;
    bool audioContiguous = true;

    size_t fileSize() const { return size_; }
    const std::string& path() const { return path_; }

    /// Decodifica um registro para PCM16 intercalado (channels canais).
    /// Lança FormatError em caso de dados corrompidos.
    std::vector<int16_t> decode(const Record& rec, DecodeStats* stats = nullptr) const;

    /// Libera o mapeamento do arquivo (após decodificar tudo o que for necessário).
    void unmap();

private:
    Document() = default;
    void parse();
    void parseNsmp4();
    std::vector<int16_t> decodeNsmp4(const Record& rec, DecodeStats* stats) const;

    std::string path_;
    const uint8_t* data_ = nullptr;
    size_t size_ = 0;
};

uint32_t crc32(const uint8_t* data, size_t len);
uint16_t crc16(const uint8_t* data, size_t len);

}  // namespace npno
