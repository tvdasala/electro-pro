#include "npno/Document.hpp"

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstring>
#include <limits>
#include <string>
#include <unordered_map>

namespace npno {

namespace {

inline uint16_t be16(const uint8_t* p) { return uint16_t((p[0] << 8) | p[1]); }
inline uint32_t be32(const uint8_t* p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}
inline uint32_t le32(const uint8_t* p) {
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}

std::string field(const uint8_t* p, size_t maxLen) {
    size_t n = 0;
    while (n < maxLen && p[n] != 0) ++n;
    std::string s(reinterpret_cast<const char*>(p), n);
    while (!s.empty() && (s.back() == ' ' || s.back() == '\0')) s.pop_back();
    return s;
}

[[noreturn]] void corrupt(const std::string& what) { throw FormatError(what); }

struct Crc32Table {
    uint32_t t[256];
    Crc32Table() {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            t[i] = c;
        }
    }
};

struct Crc16Table {
    uint16_t t[256];
    Crc16Table() {
        for (uint32_t i = 0; i < 256; ++i) {
            uint16_t c = uint16_t(i << 8);
            for (int k = 0; k < 8; ++k) c = (c & 0x8000) ? uint16_t((c << 1) ^ 0x1021) : uint16_t(c << 1);
            t[i] = c;
        }
    }
};

}  // namespace

uint32_t crc32(const uint8_t* data, size_t len) {
    static const Crc32Table table;
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; ++i) c = table.t[(c ^ data[i]) & 0xFF] ^ (c >> 8);
    return ~c;
}

uint16_t crc16(const uint8_t* data, size_t len) {
    static const Crc16Table table;
    uint16_t c = 0xFFFF;
    for (size_t i = 0; i < len; ++i) c = uint16_t(table.t[(data[i] ^ (c >> 8)) & 0xFF] ^ (c << 8));
    return c;
}

std::unique_ptr<Document> Document::open(const std::string& path) {
#ifdef _WIN32
    int wlen = MultiByteToWideChar(CP_UTF8, 0, path.data(), (int)path.size(), nullptr, 0);
    std::wstring wpath(size_t(wlen > 0 ? wlen : 0), L'\0');
    if (wlen > 0) {
        MultiByteToWideChar(CP_UTF8, 0, path.data(), (int)path.size(), wpath.data(), wlen);
    }
    HANDLE hFile = CreateFileW(wpath.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                               FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (hFile == INVALID_HANDLE_VALUE) {
        throw FormatError("Não foi possível abrir o arquivo: " + path);
    }
    LARGE_INTEGER fileSizeLI{};
    if (!GetFileSizeEx(hFile, &fileSizeLI)) {
        CloseHandle(hFile);
        throw FormatError("Falha ao obter o tamanho do arquivo");
    }
    size_t size = size_t(fileSizeLI.QuadPart);
    if (size <= 0x2B) {
        CloseHandle(hFile);
        throw FormatError("Arquivo pequeno demais para ser um .npno");
    }
    if (size > (size_t(1) << 31)) {
        CloseHandle(hFile);
        throw FormatError("Arquivo maior que 2 GiB");
    }
    HANDLE hMap = CreateFileMappingW(hFile, nullptr, PAGE_READONLY, 0, 0, nullptr);
    CloseHandle(hFile);
    if (!hMap) {
        throw FormatError("Falha ao criar mapeamento do arquivo em memória");
    }
    void* m = MapViewOfFile(hMap, FILE_MAP_READ, 0, 0, 0);
    CloseHandle(hMap);
    if (!m) {
        throw FormatError("Falha ao mapear o arquivo em memória");
    }
#else
    int fd = ::open(path.c_str(), O_RDONLY);
    if (fd < 0) throw FormatError("Não foi possível abrir o arquivo: " + path);
    struct stat st {};
    if (fstat(fd, &st) != 0) {
        ::close(fd);
        throw FormatError("Falha ao obter o tamanho do arquivo");
    }
    size_t size = size_t(st.st_size);
    if (size <= 0x2B) {
        ::close(fd);
        throw FormatError("Arquivo pequeno demais para ser um .npno");
    }
    if (size > (size_t(1) << 31)) {
        ::close(fd);
        throw FormatError("Arquivo maior que 2 GiB");
    }
    void* m = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
    ::close(fd);
    if (m == MAP_FAILED) throw FormatError("Falha ao mapear o arquivo em memória");
    madvise(m, size, MADV_SEQUENTIAL);
#endif

    std::unique_ptr<Document> doc(new Document());
    doc->path_ = path;
    doc->data_ = static_cast<const uint8_t*>(m);
    doc->size_ = size;
    doc->parse();
    return doc;
}

Document::~Document() { unmap(); }

void Document::unmap() {
    if (data_) {
#ifdef _WIN32
        UnmapViewOfFile(data_);
#else
        munmap(const_cast<uint8_t*>(data_), size_);
#endif
        data_ = nullptr;
    }
}

void Document::parse() {
    const uint8_t* d = data_;
    if (std::memcmp(d, "CBIN", 4) != 0) corrupt("Assinatura CBIN ausente");
    containerVersion = le32(d + 4);
    if (containerVersion > 1) corrupt("Versão de container CBIN não suportada: " + std::to_string(containerVersion));
    const bool isNpno = (std::memcmp(d + 8, "npno", 4) == 0);
    const bool isNsmp = (std::memcmp(d + 8, "nsmp", 4) == 0);
    if (!isNpno && !isNsmp) corrupt("O container CBIN não é do tipo npno nem nsmp");
    isNsmp4 = isNsmp;
    fileVersion = le32(d + 0x14);

    if (containerVersion == 1) {
        headerLength = 0x2C;
        payloadEnd = size_;
        storedCrc = le32(d + 0x18);
        computedCrc = crc32(d + 0x2C, size_ - 0x2C);
        crcOk = storedCrc == computedCrc;
    } else {
        headerLength = 0x18;
        payloadEnd = size_ - 2;
        storedCrc = uint32_t(d[size_ - 2]) | (uint32_t(d[size_ - 1]) << 8);
        computedCrc = crc16(d, size_ - 2);
        crcOk = storedCrc == computedCrc;
    }

    if (isNsmp4) {
        parseNsmp4();
        return;
    }

    if (payloadEnd < headerLength + kCnspSize) corrupt("Cabeçalho CNSP truncado");
    const uint8_t* c = d + headerLength;
    if (std::memcmp(c, "CNSP", 4) != 0 || c[4] != 4) corrupt("Cabeçalho CNSP inválido ou versão diferente de 4");

    comboName = field(c + 0x1C, 32);
    name = field(c + 0x3C, 32);
    model = field(c + 0x5C, 32);
    for (int i = 0; i < 128; ++i) {
        keymap[i] = c[0x8C + i];
        noteTrim[i] = int8_t(c[0x10C + i]);
        noteCents[i] = int8_t(c[0x18C + i]);
        damperFlags[i] = c[0x30C + i];
    }
    globalTrim = int8_t(c[0x40C]);
    damperBoundary = c[0x40D];

    channels = be16(c + 0x61E);
    if (channels < 1 || channels > 2) corrupt("Número de canais inválido: " + std::to_string(channels));
    blockBytes = size_t(channels) * 1022;
    totalRecords = be16(c + 0x620);
    if (totalRecords == 0) corrupt("O arquivo não contém amostras");
    uint32_t sum = 0;
    for (int k = 0; k < 128; ++k) {
        perKeyCount[k] = be16(c + 0x622 + 2 * k);
        sum += perKeyCount[k];
    }
    if (sum != totalRecords) corrupt("As contagens por tecla não somam o total de amostras");
    for (int n = 0; n < 128; ++n) {
        if (keymap[n] < 128 && perKeyCount[keymap[n]] == 0)
            corrupt("Mapa de teclas aponta para uma tecla sem amostras (nota " + std::to_string(n) + ")");
    }

    const size_t tableOffset = headerLength + kCnspSize;
    if (payloadEnd - tableOffset < size_t(totalRecords) * kRecordSize) corrupt("Tabela de registros truncada");
    audioBase = tableOffset + size_t(totalRecords) * kRecordSize;

    records.reserve(totalRecords);
    const uint8_t* r = d + tableOffset;
    uint32_t idx = 0;
    size_t expected = audioBase;
    size_t maxEnd = audioBase;
    for (int key = 0; key < 128; ++key) {
        for (uint16_t j = 0; j < perKeyCount[key]; ++j, ++idx, r += kRecordSize) {
            Record rec;
            rec.index = idx;
            rec.rootKey = uint8_t(key);
            std::memcpy(rec.raw.data(), r, kRecordSize);
            rec.absOffset = headerLength + uint64_t(be32(r + 0x00));
            rec.kind = r[0x04];
            rec.velParam = r[0x05];
            rec.decodedFrames = be32(r + 0x06);
            rec.blockCount = be16(r + 0x0A);
            for (uint32_t c = 0; c < 2; ++c)
                for (uint32_t k = 0; k < 4; ++k)
                    rec.initHist[c][k] = int16_t(be16(r + 0x0C + (c * 4 + k) * 2));
            rec.initL = rec.initHist[0][3];
            rec.initR = rec.initHist[1][3];
            rec.loopStart = be32(r + 0x1C);
            rec.loopLength = be32(r + 0x20);
            rec.loopDecayRaw = be32(r + 0x2E);
            rec.gainRef = int16_t(be16(r + 0x32));
            rec.attenuation = int16_t(be16(r + 0x34));
            rec.envDecayRaw = be32(r + 0x3A);
            rec.releaseParam = r[0x72];
            rec.layerMin = r[0x74];

            const std::string where = " (registro " + std::to_string(idx) + ")";
            if (rec.absOffset < audioBase) corrupt("Offset de áudio aponta para dentro do cabeçalho" + where);
            if (rec.decodedFrames > kMaxDecodedFrames) corrupt("Amostra excede o limite de frames" + where);
            if (uint64_t(rec.loopStart) + rec.loopLength > rec.decodedFrames)
                corrupt("Loop excede a quantidade de frames decodificados" + where);
            const uint64_t end = rec.absOffset + uint64_t(rec.blockCount) * blockBytes;
            if (end > payloadEnd) corrupt("Blocos de áudio ultrapassam o fim do arquivo" + where);
            if (rec.absOffset != expected) audioContiguous = false;
            expected = size_t(end);
            if (end > maxEnd) maxEnd = size_t(end);
            records.push_back(rec);
        }
    }
    if (maxEnd != payloadEnd) audioContiguous = false;
}

void Document::parseNsmp4() {
    const uint8_t* d = data_;
    if (payloadEnd < headerLength + 0x10) corrupt("Cabeçalho NSMP truncado");
    const uint8_t* nsmp = d + headerLength;
    if (std::memcmp(nsmp, "NSMP", 4) != 0) corrupt("Cabeçalho NSMP inválido");

    keymap.fill(0xFF);
    noteTrim.fill(0);
    noteCents.fill(0);
    damperFlags.fill(0);
    perKeyCount.fill(0);
    globalTrim = 0;
    damperBoundary = 128;
    channels = 1;
    blockBytes = 0;
    audioBase = headerLength + 0x10;
    audioContiguous = false;

    struct ZoneInfo {
        uint8_t rootKey = 60;
        uint8_t keyLow = 0;
        uint8_t keyHigh = 127;
        uint8_t velLow = 0;
        uint8_t velHigh = 127;
        uint32_t sampleId = 0;
    };
    std::vector<ZoneInfo> zones;
    std::unordered_map<uint32_t, ZoneInfo> zoneBySampleId;

    size_t pos = headerLength + 0x10;
    uint32_t recIdx = 0;
    while (pos + 12 <= payloadEnd) {
        const uint8_t* chdr = d + pos;
        const uint32_t csz = be32(chdr + 8);
        if (pos + 12 + size_t(csz) > payloadEnd) break;
        const uint8_t* p = chdr + 12;

        if (std::memcmp(chdr, "\0hdr", 4) == 0 && csz >= 0x5A) {
            name = field(p + 0x0A, 64);
            model = field(p + 0x4A, 16);
            comboName = model.empty() ? name : (name + " " + model);
        } else if (std::memcmp(chdr, "\0map", 4) == 0 && csz >= 1286 + 0x20) {
            const uint8_t* rem = p + 1286;
            const size_t remLen = size_t(csz) - 1286;
            const uint16_t zCount = be16(rem + 0x1E);
            for (uint16_t i = 0; i < zCount; ++i) {
                const size_t off = 0x20 + size_t(i) * 16;
                if (off + 16 > remLen) break;
                const uint8_t* e = rem + off;
                ZoneInfo z;
                z.rootKey = e[0];
                z.keyHigh = e[1];
                z.keyLow = e[2];
                if (z.keyLow > z.keyHigh) std::swap(z.keyLow, z.keyHigh);
                z.sampleId = be32(e + 8);
                z.velLow = e[13];
                z.velHigh = e[15];
                if (z.velLow > z.velHigh) std::swap(z.velLow, z.velHigh);
                zones.push_back(z);
                zoneBySampleId[z.sampleId] = z;
            }
        } else if (std::memcmp(chdr, "\0stk", 4) == 0 && csz >= 0x44) {
            Record rec;
            rec.index = recIdx++;
            rec.isNsmp4 = true;
            rec.sampleId = be32(p + 0x00);
            rec.kind = p[0x04];
            rec.rootKey = p[0x05] & 0x7Fu;
            rec.velParam = p[0x07];
            rec.channels = std::clamp<uint16_t>(p[0x08], 1, 2);
            if (rec.channels > channels) channels = rec.channels;
            rec.envDecayRaw = be32(p + 0x08) & 0xFFFFFFu;
            rec.releaseParam = p[0x0C];
            rec.attenuation = int16_t(be16(p + 0x0D));
            rec.gainRef = int16_t(p[0x0F]);
            rec.nsmpWordOffset = be32(p + 0x13) >> 8;
            rec.nsmpLoopStartWord = be32(p + 0x1C) >> 8;
            rec.nsmpLoopEndWord = be32(p + 0x25) >> 8;
            rec.nsmpEndWord = be32(p + 0x2E) >> 8;
            rec.absOffset = headerLength + uint64_t(rec.nsmpWordOffset) * 4u;

            const size_t fineOff = (rec.channels == 2 && csz >= 0x41) ? 0x39 : 0x36;
            float fine = std::bit_cast<float>(be32(p + fineOff));
            if (std::isfinite(fine) && std::fabs(fine) <= 100.0f) rec.fineTuneCents = fine;
            if (rec.channels == 1) {
                float linG = std::bit_cast<float>(be32(p + 0x3B));
                if (std::isfinite(linG) && linG >= 0.15f && linG <= 4.0f) rec.linearGain = linG;
            }

            auto zit = zoneBySampleId.find(rec.sampleId);
            if (zit != zoneBySampleId.end()) {
                rec.rootKey = zit->second.rootKey & 0x7Fu;
                rec.keyLow = std::min<uint8_t>(zit->second.keyLow, 127);
                rec.keyHigh = std::min<uint8_t>(zit->second.keyHigh, 127);
                rec.velLow = std::min<uint8_t>(zit->second.velLow, 127);
                rec.velHigh = std::min<uint8_t>(zit->second.velHigh, 127);
            } else {
                rec.keyLow = rec.rootKey;
                rec.keyHigh = rec.rootKey;
                rec.velLow = 0;
                rec.velHigh = 127;
            }

            // Calcula decodedFrames, loopStart e loopLength percorrendo os cabeçalhos de pacotes
            uint32_t cur = rec.nsmpWordOffset;
            uint32_t totalFrames = 0;
            uint32_t loopStartFrame = 0;
            bool hasLoop = false;
            const uint32_t ch = rec.channels;
            while (cur < rec.nsmpEndWord && (headerLength + uint64_t(cur + 1) * 4u <= payloadEnd)) {
                if (rec.nsmpLoopEndWord < rec.nsmpEndWord && cur == rec.nsmpLoopEndWord) {
                    loopStartFrame = totalFrames;
                    hasLoop = true;
                }
                const uint32_t w = be32(d + headerLength + size_t(cur) * 4u);
                const uint32_t hi = w >> 16;
                const uint32_t lo = w & 0xFFFFu;
                const uint32_t flag80 = (hi >> 7) & 1u;
                const uint32_t rawBits = (hi >> 3) & 0x0Fu;
                const uint32_t n = lo & 0x3FFFu;
                const uint32_t framesInPkt = n / ch;
                totalFrames += framesInPkt;
                uint32_t step = 1;
                if (!(flag80 && rawBits == 0)) {
                    const uint32_t width = rawBits + 1u;
                    const uint32_t wordsPerCh = (framesInPkt * width + 31u) / 32u;
                    step = 1u + ch * wordsPerCh;
                }
                cur += step;
            }
            rec.decodedFrames = totalFrames;
            if (hasLoop && totalFrames > loopStartFrame) {
                rec.loopStart = loopStartFrame;
                rec.loopLength = totalFrames - loopStartFrame;
            } else {
                rec.loopStart = 0;
                rec.loopLength = 0;
            }

            if (rec.decodedFrames > 0) {
                records.push_back(rec);
                if (rec.rootKey < 128) perKeyCount[rec.rootKey]++;
                for (uint8_t k = rec.keyLow; k <= rec.keyHigh && k < 128; ++k) {
                    if (keymap[k] == 0xFF) keymap[k] = rec.rootKey;
                }
            }
        }
        pos += 12 + size_t(csz);
    }

    totalRecords = uint16_t(records.size());
    if (totalRecords == 0) corrupt("O arquivo .nsmp4 não contém amostras válidas");
}

std::vector<int16_t> Document::decodeNsmp4(const Record& rec, DecodeStats* stats) const {
    if (!data_) throw FormatError("Documento já foi desmapeado");
    const uint32_t ch = std::clamp<uint32_t>(rec.channels, 1, 2);
    std::vector<int16_t> out;
    out.reserve(size_t(rec.decodedFrames) * ch);

    int64_t hist[2][4] = {};
    DecodeStats local{};
    uint32_t cur = rec.nsmpWordOffset;
    const uint32_t eWord = rec.nsmpEndWord;

    while (cur < eWord && (headerLength + uint64_t(cur + 1) * 4u <= payloadEnd)) {
        const uint32_t w = be32(data_ + headerLength + size_t(cur) * 4u);
        const uint32_t hi = w >> 16;
        const uint32_t lo = w & 0xFFFFu;
        const uint32_t flag80 = (hi >> 7) & 1u;
        const uint32_t rawBits = (hi >> 3) & 0x0Fu;
        const uint32_t order = (w >> 14) & 7u;
        const uint32_t n = lo & 0x3FFFu;
        const uint32_t frames = n / ch;
        if (order <= 4) local.orderHistogram[order]++;

        if (flag80 && rawBits == 0) {
            for (uint32_t f = 0; f < frames; ++f) {
                for (uint32_t c = 0; c < ch; ++c) {
                    int64_t* h = hist[c];
                    int64_t pred = 0;
                    switch (order) {
                        case 0: pred = 0; break;
                        case 1: pred = h[3]; break;
                        case 2: pred = 2 * h[3] - h[2]; break;
                        case 3: pred = 3 * h[3] - 3 * h[2] + h[1]; break;
                        default: pred = 4 * h[3] - 6 * h[2] + 4 * h[1] - h[0]; break;
                    }
                    const int64_t s = pred;
                    h[0] = h[1];
                    h[1] = h[2];
                    h[2] = h[3];
                    h[3] = s;
                    const int64_t scaled = std::clamp<int64_t>(s, -32768, 32767);
                    out.push_back(int16_t(scaled));
                }
            }
            cur += 1u;
        } else {
            const uint32_t width = rawBits + 1u;
            const uint32_t wordsPerCh = (frames * width + 31u) / 32u;
            const uint32_t totalWords = ch * wordsPerCh;
            if (headerLength + uint64_t(cur + 1u + totalWords) * 4u > payloadEnd) break;

            const uint8_t* pktWords = data_ + headerLength + size_t(cur + 1u) * 4u;
            const uint64_t mask = (uint64_t(1) << width) - 1u;
            uint64_t acc[2] = {};
            uint32_t bitsInAcc[2] = {};
            uint32_t wordIdx[2] = {};

            for (uint32_t f = 0; f < frames; ++f) {
                for (uint32_t c = 0; c < ch; ++c) {
                    while (bitsInAcc[c] < width) {
                        uint32_t wVal = 0;
                        if (wordIdx[c] < wordsPerCh) {
                            wVal = be32(pktWords + size_t(wordIdx[c] * ch + c) * 4u);
                            wordIdx[c]++;
                        }
                        acc[c] = (acc[c] << 32) | uint64_t(wVal);
                        bitsInAcc[c] += 32u;
                    }
                    bitsInAcc[c] -= width;
                    const uint64_t rawVal = (acc[c] >> bitsInAcc[c]) & mask;
                    const int64_t residual = int64_t(rawVal << (64u - width)) >> (64u - width);
                    int64_t* h = hist[c];
                    int64_t pred = 0;
                    switch (order) {
                        case 0: pred = 0; break;
                        case 1: pred = h[3]; break;
                        case 2: pred = 2 * h[3] - h[2]; break;
                        case 3: pred = 3 * h[3] - 3 * h[2] + h[1]; break;
                        default: pred = 4 * h[3] - 6 * h[2] + 4 * h[1] - h[0]; break;
                    }
                    const int64_t s = pred + residual;
                    h[0] = h[1];
                    h[1] = h[2];
                    h[2] = h[3];
                    h[3] = s;
                    const int64_t scaled = std::clamp<int64_t>(s, -32768, 32767);
                    out.push_back(int16_t(scaled));
                }
            }
            cur += 1u + totalWords;
        }
    }

    if (stats) *stats = local;
    return out;
}

std::vector<int16_t> Document::decode(const Record& rec, DecodeStats* stats) const {
    if (rec.isNsmp4) return decodeNsmp4(rec, stats);
    if (!data_) throw FormatError("Documento já foi desmapeado");
    const uint32_t ch = channels;
    const size_t bb = blockBytes;
    const uint8_t* base = data_ + rec.absOffset;
    const std::string where = " (registro " + std::to_string(rec.index) + ")";

    std::vector<int16_t> out;
    out.reserve(size_t(rec.decodedFrames) * ch);

    int64_t hist[2][4];
    for (uint32_t c = 0; c < 2; ++c)
        for (uint32_t k = 0; k < 4; ++k)
            hist[c][k] = rec.initHist[c][k];
    int16_t prevTail[kBlockOverlap * 2] = {};
    int16_t tail[kBlockOverlap * 2] = {};
    DecodeStats local;

    for (uint32_t b = 0; b < rec.blockCount; ++b) {
        const uint8_t* blk = base + size_t(b) * bb;
        const uint8_t hdr = blk[1];
        const uint32_t width = hdr & 0x1F;
        const uint32_t order = hdr >> 5;
        if (width < 1 || width > 16 || order > 4) corrupt("Cabeçalho de bloco inválido" + where);
        const uint32_t rawFrames = uint32_t(((bb * 8 - 16) / width) / ch);
        if (rawFrames <= kBlockOverlap) corrupt("Bloco comprimido sem frames reproduzíveis" + where);
        local.orderHistogram[order]++;

        const uint8_t* bp = blk + 2;
        uint64_t acc = 0;
        uint32_t cnt = 0;
        const uint64_t mask = (uint64_t(1) << width) - 1;
        const uint32_t keep = rawFrames - kBlockOverlap;
        int64_t saved[2][4];

        for (uint32_t f = 0; f < rawFrames; ++f) {
            if (f == keep) std::memcpy(saved, hist, sizeof(hist));
            int16_t frame[2];
            for (uint32_t c = 0; c < ch; ++c) {
                while (cnt < width) {
                    acc |= uint64_t(be16(bp)) << cnt;
                    bp += 2;
                    cnt += 16;
                }
                const uint64_t v = acc & mask;
                acc >>= width;
                cnt -= width;
                const int64_t residual = int64_t(v << (64 - width)) >> (64 - width);
                int64_t* h = hist[c];
                int64_t pred;
                switch (order) {
                    case 0: pred = 0; break;
                    case 1: pred = h[3]; break;
                    case 2: pred = 2 * h[3] - h[2]; break;
                    case 3: pred = 3 * h[3] - 3 * h[2] + h[1]; break;
                    default: pred = 4 * h[3] - 6 * h[2] + 4 * h[1] - h[0]; break;
                }
                const int64_t s = residual + pred;
                if (s < -32768 || s > 32767) corrupt("Estouro na reconstrução PCM16" + where);
                h[0] = h[1];
                h[1] = h[2];
                h[2] = h[3];
                h[3] = s;
                frame[c] = int16_t(s);
            }
            if (b > 0 && f < kBlockOverlap) {
                for (uint32_t c = 0; c < ch; ++c)
                    if (frame[c] != prevTail[f * ch + c]) {
                        local.overlapMismatches++;
                        break;
                    }
            }
            if (f < keep) {
                for (uint32_t c = 0; c < ch; ++c) out.push_back(frame[c]);
            } else {
                for (uint32_t c = 0; c < ch; ++c) tail[(f - keep) * ch + c] = frame[c];
            }
        }
        std::memcpy(hist, saved, sizeof(hist));
        std::memcpy(prevTail, tail, sizeof(tail));
    }

    if (out.size() != size_t(rec.decodedFrames) * ch)
        corrupt("Quantidade de frames declarada não confere com os blocos" + where);

    if (rec.loopLength > 0 && rec.decodedFrames > rec.loopStart + rec.loopLength) {
        const uint32_t avail = rec.decodedFrames - (rec.loopStart + rec.loopLength);
        const uint32_t n = avail < kBlockOverlap ? avail : kBlockOverlap;
        for (uint32_t i = 0; i < n; ++i)
            for (uint32_t c = 0; c < ch; ++c) {
                local.loopCheckedSamples++;
                if (out[size_t(rec.loopStart + i) * ch + c] != out[size_t(rec.loopStart + rec.loopLength + i) * ch + c])
                    local.loopMismatches++;
            }
    }
    if (stats) *stats = local;
    return out;
}

}  // namespace npno
