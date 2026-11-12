#include "npno/Instrument.hpp"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdio>
#include <mutex>
#include <thread>

namespace npno {

namespace {

// Tabelas copiadas bit a bit da seção __const do reprodutor de referência.
constexpr uint32_t kSelX[16] = {0x3f800000, 0x42200000, 0x42400000, 0x42600000, 0x42800000, 0x42900000,
                                0x42a00000, 0x42a80000, 0x42b00000, 0x42c00000, 0x42c80000, 0x42d00000,
                                0x42e00000, 0x42e80000, 0x42f00000, 0x42fe0000};
constexpr uint32_t kSelY[16] = {0x437f0000, 0x43200000, 0x43000000, 0x42d80000, 0x42a80000, 0x428f0000,
                                0x426c0000, 0x42580000, 0x42400000, 0x42180000, 0x41e80000, 0x41c40000,
                                0x41080000, 0x00000000, 0x00000000, 0x00000000};
constexpr uint32_t kVelLoX[6] = {0x41800000, 0x41c00000, 0x41e00000, 0x42000000, 0x42100000, 0x42200000};
constexpr uint32_t kVelLoY[6] = {0xc106e148, 0xc0d3f7cf, 0xc0a09375, 0xc0741893, 0xbf9a3d71, 0x00000000};
constexpr uint32_t kVelHiX[11] = {0x42200000, 0x42400000, 0x42600000, 0x42800000, 0x42900000, 0x42a00000,
                                  0x42b00000, 0x42c00000, 0x42d00000, 0x42e00000, 0x42e80000};
constexpr uint32_t kVelHiY[11] = {0xbf218937, 0xbe343958, 0xbf418937, 0x3eced917, 0x3d5d2f1b, 0x3e3126e9,
                                  0xbe8ccccd, 0xbe1fbe77, 0x3eb645a2, 0x3fc1eb85, 0x40000000};
constexpr uint32_t kVelLoScale = 0x3d540e57;

inline float F(uint32_t bits) { return std::bit_cast<float>(bits); }

// Interpolação linear por segmentos: i é o primeiro índice com x <= X[i] (1..n-1).
template <size_t N>
float piecewise(const uint32_t (&X)[N], const uint32_t (&Y)[N], float x) {
    size_t i = 1;
    while (i < N - 1 && x > F(X[i])) ++i;
    const float x0 = F(X[i - 1]), x1 = F(X[i]);
    const float y0 = F(Y[i - 1]), y1 = F(Y[i]);
    return y0 + (x - x0) / (x1 - x0) * (y1 - y0);
}

// Conversão de taxa UQ9.23 -> dB/s (applyEnvelopeMetadata). Negativo = inválido.
double rateFromRaw(uint32_t x) {
    if (x < 1 || x > (1u << 23)) return -1.0;
    double d = -20.0 * std::log10(double(x) / double(1u << 23)) * 21680.0;
    return std::clamp(d, 0.0, 60.0);
}

// Estimativa de decaimento por regressão linear da energia antes do loop (measureLoopDecay).
double measureLoopDecay(const Sample& s, const std::vector<int16_t>& pcm, uint32_t frames) {
    double T = 18.0 * std::exp2((60.0 - double(s.root)) / 36.0);
    T = std::min(T, 40.0);
    const double fallback = (T < 3.0) ? 20.0 : 60.0 / T;
    if (s.loopLength == 0 || s.loopStart > frames) return fallback;

    const uint32_t win = 3499;  // 0,1 s
    uint64_t start = s.loopStart > 52485 ? std::max<uint64_t>(s.loopStart - 52485, 6998) : 6998;
    double n = 0, st = 0, sy = 0, stt = 0, sty = 0;
    const int ch = s.channels;
    while (start + win <= s.loopStart) {
        double e = 0;
        for (uint64_t f = start; f < start + win; ++f) {
            if (ch == 2) {
                double l = pcm[f * 2], r = pcm[f * 2 + 1];
                e += l * l + r * r;
            } else {
                double l = pcm[f];
                e += 2 * l * l;
            }
        }
        double db = 10.0 * std::log10(std::max(e / 6998.0, 1.0));
        double t = (double(start) + 1749.5) / kNativeSampleRate;
        n += 1;
        st += t;
        sy += db;
        stt += t * t;
        sty += t * db;
        start += win;
    }
    if (n < 4) return fallback;
    double den = n * stt - st * st;
    if (den <= 0) return fallback;
    double d = (st * sy - n * sty) / den;
    if (!std::isfinite(d)) return fallback;
    d = std::min(d, 40.0);
    return d < fallback ? fallback : d;
}

}  // namespace

float Instrument::velocityGain(float v) {
    v = std::clamp(v, 0.0f, 1.0f);
    if (v == 0.0f) return 0.0f;
    const float x = v * 127.0f;
    if (x >= 116.0f) return 1.0f;
    if (x < 40.0f) {
        float db = piecewise(kVelLoX, kVelLoY, std::max(x, 16.0f));
        return std::pow(10.0f, db / 20.0f) * F(kVelLoScale);
    }
    float db = piecewise(kVelHiX, kVelHiY, x);
    return std::min(std::pow(v, 2.5f) * std::pow(10.0f, db / 20.0f), 1.0f);
}

const Sample* Instrument::select(int note, float velocity) const {
    if (note < 0 || note > 127 || velocity <= 0.0f) return nullptr;
    if (isNsmp4) {
        const auto& nlist = samplesByNote[note];
        const auto* listPtr = &nlist;
        if (listPtr->empty()) {
            const int root = keymap[note];
            if (root < 0) return nullptr;
            listPtr = &normalByRoot[root];
            if (listPtr->empty()) return nullptr;
        }
        const auto& list = *listPtr;
        const int v127 = std::clamp(int(std::lround(velocity * 127.0f)), 1, 127);
        const Sample* best = &samples[list[0]];
        int bestDist = 1000;
        for (uint32_t i : list) {
            const Sample* s = &samples[i];
            int dist = 0;
            if (v127 < int(s->velLow)) dist = int(s->velLow) - v127;
            else if (v127 > int(s->velHigh)) dist = v127 - int(s->velHigh);
            if (dist < bestDist) {
                bestDist = dist;
                best = s;
                if (dist == 0) break;
            }
        }
        if (best->sampleIndex < sampleUsed.size()) {
            sampleUsed[best->sampleIndex] = 1;
        }
        if (best->pcm.empty()) {
            for (uint32_t i : list) {
                if (!samples[i].pcm.empty()) {
                    if (i < sampleUsed.size()) sampleUsed[i] = 1;
                    return &samples[i];
                }
            }
            return nullptr;
        }
        return best;
    }

    const int root = keymap[note];
    if (root < 0) return nullptr;
    const auto& list = normalByRoot[root];
    if (list.empty()) return nullptr;
    const float x = std::clamp(velocity * 127.0f, 1.0f, 127.0f);
    const float y = piecewise(kSelX, kSelY, x);

    const Sample* best = &samples[list[0]];
    for (uint32_t i : list)
        if (samples[i].boundary < best->boundary) best = &samples[i];
    for (uint32_t i : list) {
        const Sample* s = &samples[i];
        if (y < float(s->boundary)) continue;
        if (s->boundary > best->boundary || (s->boundary == best->boundary && s->velParam < best->velParam))
            best = s;
    }
    if (best->sampleIndex < sampleUsed.size()) {
        sampleUsed[best->sampleIndex] = 1;
    }
    if (best->pcm.empty()) {
        for (uint32_t i : list) {
            if (!samples[i].pcm.empty()) {
                if (i < sampleUsed.size()) sampleUsed[i] = 1;
                return &samples[i];
            }
        }
        return nullptr;
    }
    return best;
}

const Sample* Instrument::selectRelease(int note) const {
    if (note < 0 || note > 127 || note >= damperBoundary) return nullptr;
    const int root = keymap[note];
    if (root < 0) return nullptr;
    const auto& list = releaseByRoot[root];
    if (list.empty()) return nullptr;
    const Sample* best = &samples[list[0]];
    for (uint32_t i : list)
        if (samples[i].velParam > best->velParam) best = &samples[i];
    if (best->sampleIndex < sampleUsed.size()) {
        sampleUsed[best->sampleIndex] = 1;
    }
    if (best->pcm.empty()) {
        for (uint32_t i : list) {
            if (!samples[i].pcm.empty()) {
                if (i < sampleUsed.size()) sampleUsed[i] = 1;
                return &samples[i];
            }
        }
        return nullptr;
    }
    return best;
}

void Instrument::resolveLayerBoundaries(bool legacyScale) {
    const uint32_t m = legacyScale ? 5 : 1;
    for (int k = 0; k < 128; ++k) {
        auto list = normalByRoot[k];
        if (list.size() < 2) {
            for (uint32_t i : list) samples[i].boundary = 0;
            continue;
        }
        bool explicitLayers = false;
        for (uint32_t i : list)
            if (samples[i].boundary != 0) explicitLayers = true;
        if (explicitLayers) continue;
        std::sort(list.begin(), list.end(), [&](uint32_t a, uint32_t b) {
            return samples[a].velParam < samples[b].velParam;
        });
        samples[list[0]].boundary = 0;
        for (size_t j = 1; j < list.size(); ++j) {
            uint32_t a = samples[list[j - 1]].velParam, b = samples[list[j]].velParam;
            samples[list[j]].boundary = ((a + b) * m + 1) >> 1;
        }
    }
}

std::unique_ptr<Instrument> Instrument::load(const std::string& path, const Progress& progress,
                                             const std::atomic<bool>* cancel) {
    auto doc = Document::open(path);
    if (!doc->crcOk) throw FormatError("Checksum do arquivo não confere (arquivo corrompido?)");

    auto inst = std::make_unique<Instrument>();
    inst->name = doc->name;
    inst->model = doc->model;
    inst->path = path;
    inst->fileVersion = doc->fileVersion;
    inst->channels = doc->channels;
    inst->recordCount = doc->totalRecords;
    inst->isNsmp4 = doc->isNsmp4;

    // Registros tocáveis: normais (tipo 0x00) e de soltura (tipo 0x02).
    std::vector<const Record*> playable;
    std::vector<uint32_t> playableRecordIndices;
    for (uint32_t recIdx = 0; recIdx < doc->records.size(); ++recIdx) {
        const auto& r = doc->records[recIdx];
        if (r.isNormal() || r.isRelease()) {
            playable.push_back(&r);
            playableRecordIndices.push_back(recIdx);
        }
    }
    inst->samples.resize(playable.size());
    inst->sampleUsed.assign(playable.size(), 0);
    inst->samplePurged.assign(playable.size(), 0);

    const float globalGain = std::pow(10.0f, float(doc->globalTrim) / 200.0f);
    std::atomic<size_t> next{0}, done{0};
    std::atomic<bool> failed{false};
    std::string error;
    std::mutex errMutex;

    auto worker = [&] {
        for (;;) {
            if (failed || (cancel && cancel->load())) return;
            size_t i = next++;
            if (i >= playable.size()) return;
            const Record& r = *playable[i];
            Sample& s = inst->samples[i];
            try {
                std::vector<int16_t> pcm = doc->decode(r);
                s.sampleIndex = uint32_t(i);
                s.recordIndex = playableRecordIndices[i];
                s.root = r.rootKey;
                s.velParam = r.velParam;
                s.boundary = r.layerMin;
                s.release = r.isRelease();
                s.channels = r.isNsmp4 ? r.channels : doc->channels;
                s.frames = r.decodedFrames;
                s.loopStart = r.loopStart;
                s.loopLength = r.loopLength;
                s.fineTuneCents = r.fineTuneCents;
                s.keyLow = r.keyLow;
                s.keyHigh = r.keyHigh;
                s.velLow = r.velLow;
                s.velHigh = r.velHigh;
                const int ch = s.channels;

                int peak = 1;
                for (int16_t v : pcm) peak = std::max(peak, std::abs(int(v)));
                s.peak = peak;

                // Ganho (Instrument::load / applyNormalGainMetadata).
                if (s.release) {
                    s.gain = 1.0f / 32768.0f;
                } else if (r.isNsmp4) {
                    double y0 = 0.0, y1 = 0.0, pk = 1.0, sumSq = 0.0;
                    uint32_t activeFrames = 0;
                    for (uint32_t f = 0; f < s.frames; ++f) {
                        double l = pcm[size_t(f) * ch], rr = pcm[size_t(f) * ch + (ch - 1)];
                        y0 = y0 * 0.5835 + l * 0.4165;
                        y1 = y1 * 0.5835 + rr * 0.4165;
                        pk = std::max({pk, std::fabs(y0), std::fabs(y1)});
                        double magSq = 0.5 * (l * l + rr * rr);
                        if (magSq > 16.0) {
                            sumSq += magSq;
                            ++activeFrames;
                        }
                    }
                    double rms = (activeFrames > 0) ? std::sqrt(sumSq / double(activeFrames)) : 1.0;
                    float g = F(0x38400000) * 0.72f * std::clamp(r.linearGain, 0.5f, 1.5f);
                    // Limita o pico individual (-10 dBFS) e o RMS contínuo para timbres sustentados (Strings/Pads/Bass)
                    const float maxPeakGain = float(0.32 / std::max(1.0, double(s.peak)));
                    const float maxSmoothGain = float(0.28 / std::max(1.0, pk));
                    const float maxRmsGain = float(0.095 / std::max(1.0, rms));
                    g = std::min({g, maxPeakGain, maxSmoothGain, maxRmsGain});
                    s.gain = g * globalGain;
                } else {
                    int att = doc->containerVersion == 0 ? (r.attenuation - r.gainRef) * 10 : r.attenuation;
                    float g;
                    if (att >= -600 && att <= 600) {
                        g = std::pow(10.0f, -float(att) / 200.0f) * F(0x38400000);
                    } else {
                        double y0 = 0, y1 = 0, pk = 1.0;
                        for (uint32_t f = 0; f < s.frames; ++f) {
                            double l = pcm[size_t(f) * ch], rr = pcm[size_t(f) * ch + (ch - 1)];
                            y0 = y0 * 0.5835 + l * 0.4165;
                            y1 = y1 * 0.5835 + rr * 0.4165;
                            pk = std::max({pk, std::fabs(y0), std::fabs(y1)});
                        }
                        g = float(0.65 / pk);
                    }
                    s.gain = g * globalGain;
                }

                // Decaimento (measureLoopDecay + applyEnvelopeMetadata).
                if (r.isNsmp4) {
                    s.loopDecayDb = (s.loopLength > 0) ? 2.2 : 0.8;
                    s.decayRealtime = true;
                    s.envDecayDb = s.loopDecayDb;
                    if (r.releaseParam != 0)
                        s.releaseMs = float(std::clamp(12.0 * std::exp2(double(r.releaseParam) / 3.2), 45.0, 2200.0));
                    else
                        s.releaseMs = 180.0f;
                } else {
                    s.loopDecayDb = measureLoopDecay(s, pcm, s.frames);
                    double env = rateFromRaw(r.envDecayRaw);
                    if (env >= 0) s.envDecayDb = env;
                    double loopRate = rateFromRaw(r.loopDecayRaw);
                    if (loopRate >= 0) {
                        s.loopDecayDb = loopRate;
                        s.decayRealtime = true;
                    }
                    if (r.releaseParam != 0)
                        s.releaseMs = float(std::clamp(2.0 * std::exp2(r.releaseParam / 6.0), 10.0, 4000.0));
                }

                // Garante pelo menos 4 frames após o fim (continuação do loop ou silêncio) para a interpolação.
                size_t needed = size_t(s.frames) + 4;
                if (s.loopLength > 0) {
                    size_t loopEnd = size_t(s.loopStart) + s.loopLength;
                    pcm.resize(std::max(pcm.size(), loopEnd * ch));
                    size_t have = pcm.size() / ch;
                    for (size_t f = have; f < loopEnd + 4; ++f)
                        for (int c = 0; c < ch; ++c) pcm.push_back(pcm[(f - s.loopLength) * ch + c]);
                    needed = std::max(needed, loopEnd + 4);
                }
                if (pcm.size() < needed * ch) pcm.resize(needed * ch, 0);
                pcm.shrink_to_fit();
                s.pcm = std::move(pcm);
            } catch (const std::exception& e) {
                std::lock_guard<std::mutex> lock(errMutex);
                if (!failed) error = e.what();
                failed = true;
                return;
            }
            size_t d = ++done;
            if (progress && (d % 16 == 0 || d == playable.size())) progress(float(d) / float(playable.size()));
        }
    };

    unsigned n = std::max(1u, std::min(8u, std::thread::hardware_concurrency()));
    std::vector<std::thread> pool;
    for (unsigned t = 0; t < n; ++t) pool.emplace_back(worker);
    for (auto& th : pool) th.join();
    if (failed) throw FormatError(error);
    if (cancel && cancel->load()) throw FormatError("Carregamento cancelado");

    for (uint32_t i = 0; i < inst->samples.size(); ++i) {
        const Sample& s = inst->samples[i];
        inst->decodedBytes += s.pcm.size() * sizeof(int16_t);
        (s.release ? inst->releaseByRoot : inst->normalByRoot)[s.root].push_back(i);
        if (inst->isNsmp4 && !s.release) {
            for (int nn = int(s.keyLow); nn <= int(s.keyHigh) && nn < 128; ++nn) {
                if (nn >= 0) inst->samplesByNote[nn].push_back(i);
            }
        }
    }
    inst->totalDecodedBytes = inst->decodedBytes;
    inst->resolveLayerBoundaries(doc->containerVersion == 0);

    // Normaliza as amostras de soltura pelo pico da amostra de maior parâmetro de cada tecla.
    for (int k = 0; k < 128; ++k) {
        auto& list = inst->releaseByRoot[k];
        if (list.empty()) continue;
        const Sample* ref = &inst->samples[list[0]];
        for (uint32_t i : list)
            if (inst->samples[i].velParam > ref->velParam) ref = &inst->samples[i];
        const float refPeak = float(ref->peak);
        for (uint32_t i : list) inst->samples[i].gain *= refPeak / float(inst->samples[i].peak);
    }

    // Mapa de notas, afinação e ganho por nota.
    for (int nn = 0; nn < 128; ++nn) {
        uint8_t root = doc->keymap[nn];
        inst->keymap[nn] = (root < 128 && !inst->normalByRoot[root].empty()) ? root : -1;
        inst->cents[nn] = doc->noteCents[nn];
        inst->trim[nn] = doc->noteTrim[nn];
    }
    // Extensão das teclas de borda do teclado de 88 notas (21..108) a partir da nota mapeada mais próxima.
    int lo = -1, hi = -1;
    for (int nn = 21; nn <= 108; ++nn)
        if (inst->keymap[nn] >= 0) {
            if (lo < 0) lo = nn;
            hi = nn;
        }
    if (lo >= 0 && hi - lo >= 60) {
        for (int nn = 21; nn < lo; ++nn) {
            inst->keymap[nn] = inst->keymap[lo];
            inst->cents[nn] = inst->cents[lo];
            inst->trim[nn] = inst->trim[lo];
            inst->extendedEdgeKeys++;
        }
        for (int nn = hi + 1; nn <= 108; ++nn) {
            inst->keymap[nn] = inst->keymap[hi];
            inst->cents[nn] = inst->cents[hi];
            inst->trim[nn] = inst->trim[hi];
            inst->extendedEdgeKeys++;
        }
    }
    for (int nn = 0; nn < 128; ++nn) {
        inst->noteGainLinear[nn] = std::pow(10.0f, float(inst->trim[nn]) / 200.0f);
        if (inst->keymap[nn] >= 0) {
            if (inst->lowestNote < 0) inst->lowestNote = nn;
            inst->highestNote = nn;
        }
    }

    // Limite dos abafadores (inferDamperBoundary).
    inst->damperBoundary = 128;
    if (doc->damperBoundary >= 21 && doc->damperBoundary <= 109) {
        inst->damperBoundary = doc->damperBoundary;
    } else {
        for (int nn = 108; nn >= 21; --nn) {
            int root = inst->keymap[nn];
            if (root < 0) break;
            bool hasRel = !inst->releaseByRoot[root].empty();
            if (doc->damperFlags[nn] == 0 && !hasRel) continue;
            if (nn <= 107 && doc->damperFlags[nn] != 0 && hasRel) inst->damperBoundary = nn + 1;
            break;
        }
    }
    if (progress) progress(1.0f);
    return inst;
}

size_t Instrument::purgeUnusedSamples() {
    size_t freed = 0;
    size_t remaining = 0;
    for (size_t i = 0; i < samples.size(); ++i) {
        Sample& s = samples[i];
        const bool used = (i < sampleUsed.size()) && (sampleUsed[i] != 0);
        if (!used && !s.pcm.empty()) {
            freed += s.pcm.size() * sizeof(int16_t);
            std::vector<int16_t>().swap(s.pcm);
            if (i < samplePurged.size()) samplePurged[i] = 1;
        } else {
            remaining += s.pcm.size() * sizeof(int16_t);
        }
    }
    decodedBytes = remaining;
    return freed;
}

bool Instrument::reloadPurgedSamples() {
    if (path.empty()) return false;
    bool anyPurged = false;
    for (size_t i = 0; i < samples.size(); ++i) {
        if (samples[i].pcm.empty()) {
            anyPurged = true;
            break;
        }
    }
    if (!anyPurged) return true;

    try {
        auto doc = Document::open(path);
        size_t totalBytes = 0;
        for (size_t i = 0; i < samples.size(); ++i) {
            Sample& s = samples[i];
            if (s.pcm.empty() && s.recordIndex < doc->records.size()) {
                const Record& r = doc->records[s.recordIndex];
                std::vector<int16_t> pcm = doc->decode(r);
                const int ch = s.channels;
                size_t needed = size_t(s.frames) + 4;
                if (s.loopLength > 0) {
                    size_t loopEnd = size_t(s.loopStart) + s.loopLength;
                    pcm.resize(std::max(pcm.size(), loopEnd * ch));
                    size_t have = pcm.size() / ch;
                    for (size_t f = have; f < loopEnd + 4; ++f)
                        for (int c = 0; c < ch; ++c) pcm.push_back(pcm[(f - s.loopLength) * ch + c]);
                    needed = std::max(needed, loopEnd + 4);
                }
                if (pcm.size() < needed * ch) pcm.resize(needed * ch, 0);
                pcm.shrink_to_fit();
                s.pcm = std::move(pcm);
                if (i < samplePurged.size()) samplePurged[i] = 0;
            }
            totalBytes += s.pcm.size() * sizeof(int16_t);
        }
        decodedBytes = totalBytes;
        return true;
    } catch (...) {
        return false;
    }
}

void Instrument::resetUsedMarks() const {
    std::fill(sampleUsed.begin(), sampleUsed.end(), 0);
}

size_t Instrument::residentSampleCount() const {
    size_t n = 0;
    for (const auto& s : samples) {
        if (!s.pcm.empty()) ++n;
    }
    return n;
}

std::string Instrument::summary() const {
    size_t normal = 0, rel = 0;
    for (auto& s : samples) (s.release ? rel : normal)++;
    char buf[256];
    std::snprintf(buf, sizeof buf,
                  "%s %s v%.2f | %zu amostras (%zu normais, %zu soltura) | %.0f MiB | notas %d-%d | abafador < %d",
                  name.c_str(), model.c_str(), fileVersion / 100.0, samples.size(), normal, rel,
                  decodedBytes / 1048576.0, lowestNote, highestNote, damperBoundary);
    return buf;
}

}  // namespace npno
