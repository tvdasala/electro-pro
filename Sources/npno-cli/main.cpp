// npno-cli — inspeção, validação e exportação de arquivos .npno (somente leitura).
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <thread>
#include <vector>

#include "npno/Document.hpp"
#include "npno/Engine.hpp"
#include "npno/Instrument.hpp"
#include "npno/Wav.hpp"

using namespace npno;

static const char* noteName(int n) {
    static char buf[8];
    static const char* names[] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
    std::snprintf(buf, sizeof buf, "%s%d", names[n % 12], n / 12 - 1);
    return buf;
}

static int cmdInfo(const Document& doc, bool verbose) {
    std::printf("Arquivo            : %s\n", doc.path().c_str());
    std::printf("Tamanho            : %zu bytes\n", doc.fileSize());
    std::printf("Container CBIN     : v%u (cabeçalho %zu bytes)\n", doc.containerVersion, doc.headerLength);
    std::printf("Versão do banco    : %u (%.2f)\n", doc.fileVersion, doc.fileVersion / 100.0);
    std::printf("CRC%s              : armazenado 0x%08X, calculado 0x%08X -> %s\n",
                doc.containerVersion == 1 ? "32" : "16", doc.storedCrc, doc.computedCrc,
                doc.crcOk ? "OK" : "DIVERGENTE");
    std::printf("Nome               : %s\n", doc.name.c_str());
    std::printf("Modelo             : %s\n", doc.model.c_str());
    std::printf("Nome combinado     : %s\n", doc.comboName.c_str());
    std::printf("Canais             : %u (bloco de %zu bytes)\n", doc.channels, doc.blockBytes);
    std::printf("Registros          : %u\n", doc.totalRecords);
    std::printf("Ganho global       : %d (x0.1 dB)\n", doc.globalTrim);
    std::printf("Limite de abafador : %u\n", doc.damperBoundary);
    std::printf("Áudio contíguo     : %s (início 0x%zX)\n", doc.audioContiguous ? "sim" : "não", doc.audioBase);

    std::map<int, int> kinds;
    uint64_t frames = 0;
    for (auto& r : doc.records) {
        kinds[(r.kind << 8)]++;
        frames += r.decodedFrames;
    }
    for (auto& [k, n] : kinds) std::printf("Tipo 0x%02X         : %d registros\n", k >> 8, n);
    std::printf("Frames totais      : %llu (%.1f s, %.1f MiB PCM16 %s)\n", (unsigned long long)frames,
                frames / kNativeSampleRate, frames * 2.0 * doc.channels / 1048576.0,
                doc.channels == 2 ? "estéreo" : "mono");

    int lo = -1, hi = -1;
    for (int n = 0; n < 128; ++n)
        if (doc.keymap[n] < 128) {
            if (lo < 0) lo = n;
            hi = n;
        }
    std::printf("Notas mapeadas     : %d (%s) .. %d", lo, noteName(lo), hi);
    std::printf(" (%s)\n", noteName(hi));

    if (verbose) {
        std::printf("\nnota raiz  trim cents dfl | registros (tipo:vel)\n");
        for (int n = 0; n < 128; ++n) {
            if (doc.keymap[n] >= 128) continue;
            std::printf("%4d %4d %5d %5d %3u |", n, doc.keymap[n], doc.noteTrim[n], doc.noteCents[n],
                        doc.damperFlags[n]);
            if (doc.keymap[n] == n)
                for (auto& r : doc.records)
                    if (r.rootKey == n) std::printf(" %X:%u", r.kind, r.velParam);
            std::printf("\n");
        }
    }
    return 0;
}

static int cmdRecords(const Document& doc, int key) {
    std::printf(" idx raiz tp vel   frames  blks  loopIni  loopLen  aten  rel lmin  decA(dB/s) decB(dB/s)\n");
    for (auto& r : doc.records) {
        if (key >= 0 && r.rootKey != key) continue;
        auto rate = [](uint32_t x) {
            if (x < 1 || x > (1u << 23)) return -1.0;
            double d = -20.0 * std::log10(double(x) / double(1u << 23)) * 21680.0;
            return std::clamp(d, 0.0, 60.0);
        };
        std::printf("%4u %4u %2X %3u %8u %5u %8u %8u %5d %4u %4u  %9.3f  %9.3f\n", r.index, r.rootKey, r.kind,
                    r.velParam, r.decodedFrames, r.blockCount, r.loopStart, r.loopLength, r.attenuation,
                    r.releaseParam, r.layerMin, rate(r.loopDecayRaw), rate(r.envDecayRaw));
    }
    return 0;
}

static int cmdValidate(const Document& doc) {
    std::atomic<uint32_t> next{0}, failed{0}, overlapBad{0}, loopBad{0};
    std::atomic<uint64_t> frames{0};
    std::atomic<uint32_t> orders[5] = {};
    std::vector<std::string> errors(doc.records.size());
    auto t0 = std::chrono::steady_clock::now();
    unsigned nThreads = std::max(1u, std::thread::hardware_concurrency());
    std::vector<std::thread> pool;
    for (unsigned t = 0; t < nThreads; ++t)
        pool.emplace_back([&] {
            for (;;) {
                uint32_t i = next++;
                if (i >= doc.records.size()) break;
                try {
                    DecodeStats st;
                    auto pcm = doc.decode(doc.records[i], &st);
                    frames += pcm.size() / doc.channels;
                    if (st.overlapMismatches) overlapBad++;
                    if (st.loopMismatches) loopBad++;
                    for (int o = 0; o < 5; ++o) orders[o] += st.orderHistogram[o];
                } catch (const std::exception& e) {
                    failed++;
                    errors[i] = e.what();
                }
            }
        });
    for (auto& th : pool) th.join();
    double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();

    std::printf("CRC do container      : %s\n", doc.crcOk ? "OK" : "DIVERGENTE");
    std::printf("Registros decodificados: %zu (%u falhas) em %.2f s (%u threads)\n", doc.records.size(),
                failed.load(), secs, nThreads);
    std::printf("Frames PCM decodificados: %llu\n", (unsigned long long)frames.load());
    std::printf("Sobreposição 64 frames : %u registros com divergência\n", overlapBad.load());
    std::printf("Emenda de loop         : %u registros com divergência\n", loopBad.load());
    std::printf("Blocos por ordem LPC   : 0:%u 1:%u 2:%u 3:%u 4:%u\n", orders[0].load(), orders[1].load(),
                orders[2].load(), orders[3].load(), orders[4].load());
    int shown = 0;
    for (size_t i = 0; i < errors.size() && shown < 10; ++i)
        if (!errors[i].empty()) {
            std::printf("  erro: %s\n", errors[i].c_str());
            ++shown;
        }
    bool ok = doc.crcOk && failed == 0 && overlapBad == 0 && loopBad == 0;
    std::printf("RESULTADO              : %s\n", ok ? "VÁLIDO" : "COM PROBLEMAS");
    return ok ? 0 : 2;
}

static int cmdExport(const Document& doc, uint32_t index, const std::string& out) {
    if (index >= doc.records.size()) {
        std::fprintf(stderr, "Índice fora do intervalo (0..%zu)\n", doc.records.size() - 1);
        return 1;
    }
    DecodeStats st;
    auto pcm = doc.decode(doc.records[index], &st);
    if (!writeWav16(out, pcm.data(), pcm.size() / doc.channels, doc.channels, uint32_t(kNativeSampleRate))) {
        std::fprintf(stderr, "Falha ao gravar %s\n", out.c_str());
        return 1;
    }
    std::printf("Registro %u exportado: %s (%zu frames, %u Hz)\n", index, out.c_str(), pcm.size() / doc.channels,
                unsigned(kNativeSampleRate));
    return 0;
}

// Renderiza offline uma pequena sequência musical pelo motor completo (sem dispositivo de áudio).
static int cmdRender(const std::string& path, const std::string& out) {
    auto t0 = std::chrono::steady_clock::now();
    std::unique_ptr<Instrument> inst = Instrument::load(path, nullptr, nullptr);
    double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    std::printf("Instrumento carregado em %.2f s: %s\n", secs, inst->summary().c_str());

    const double sr = 48000.0;
    Engine engine;
    engine.prepare(sr);
    engine.setInstrument(inst.release());

    struct Ev {
        double t;
        int type;  // 0 on, 1 off, 2 pedal
        int note;
        int vel;
    };
    std::vector<Ev> evs;
    // Escala de dó maior em várias dinâmicas, depois acorde com pedal e notas graves/agudas.
    int scale[] = {60, 62, 64, 65, 67, 69, 71, 72};
    double t = 0.2;
    for (int i = 0; i < 8; ++i) {
        int vel = 20 + i * 15;
        evs.push_back({t, 0, scale[i], vel});
        evs.push_back({t + 0.35, 1, scale[i], 0});
        t += 0.4;
    }
    t += 0.3;
    evs.push_back({t, 2, 0, 127});
    for (int n : {36, 48, 55, 60, 64, 67, 72}) evs.push_back({t + (n - 36) * 0.01, 0, n, 90});
    for (int n : {36, 48, 55, 60, 64, 67, 72}) evs.push_back({t + 0.5, 1, n, 0});
    evs.push_back({t + 4.0, 2, 0, 0});
    t += 4.6;
    for (int n : {21, 33, 96, 108}) {
        evs.push_back({t, 0, n, 100});
        evs.push_back({t + 1.2, 1, n, 0});
        t += 1.4;
    }
    std::sort(evs.begin(), evs.end(), [](auto& a, auto& b) { return a.t < b.t; });
    const double total = t + 2.5;

    const int block = 256;
    const size_t nFrames = size_t(total * sr);
    std::vector<float> L(nFrames), R(nFrames);
    size_t e = 0;
    for (size_t pos = 0; pos < nFrames; pos += block) {
        while (e < evs.size() && evs[e].t * sr <= double(pos)) {
            auto& ev = evs[e++];
            if (ev.type == 0) engine.noteOn(ev.note, ev.vel / 127.0f);
            else if (ev.type == 1) engine.noteOff(ev.note);
            else engine.sustain(ev.vel >= 64);
        }
        int n = int(std::min<size_t>(block, nFrames - pos));
        engine.render(L.data() + pos, R.data() + pos, n);
    }
    float peak = 0;
    for (size_t i = 0; i < nFrames; ++i) peak = std::max({peak, std::fabs(L[i]), std::fabs(R[i])});
    writeWavFloatStereo(out, L, R, uint32_t(sr));
    std::printf("Render offline gravado: %s (%.1f s, pico %.3f = %.1f dBFS)\n", out.c_str(), total, peak,
                20 * std::log10(std::max(peak, 1e-9f)));
    return 0;
}

static void usage() {
    std::printf(
        "Uso:\n"
        "  npno-cli info <arquivo.npno> [-v]          Metadados do banco\n"
        "  npno-cli records <arquivo.npno> [tecla]    Tabela de registros\n"
        "  npno-cli validate <arquivo.npno>           Decodifica e verifica todas as amostras\n"
        "  npno-cli export <arquivo.npno> <idx> <out.wav>  Exporta um registro como WAV\n"
        "  npno-cli render <arquivo.npno> <out.wav>   Renderização offline pelo motor de piano\n");
}

int main(int argc, char** argv) {
    if (argc < 3) {
        usage();
        return 1;
    }
    std::string cmd = argv[1], path = argv[2];
    try {
        if (cmd == "render") {
            if (argc < 4) return usage(), 1;
            return cmdRender(path, argv[3]);
        }
        auto doc = Document::open(path);
        if (cmd == "info") return cmdInfo(*doc, argc > 3 && std::strcmp(argv[3], "-v") == 0);
        if (cmd == "records") return cmdRecords(*doc, argc > 3 ? std::atoi(argv[3]) : -1);
        if (cmd == "validate") return cmdValidate(*doc);
        if (cmd == "export" && argc >= 5) return cmdExport(*doc, uint32_t(std::atoi(argv[3])), argv[4]);
        usage();
        return 1;
    } catch (const std::exception& e) {
        std::fprintf(stderr, "Erro: %s\n", e.what());
        return 2;
    }
}
