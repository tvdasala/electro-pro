#include "PluginShared.hpp"

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <dlfcn.h>
#include <sys/stat.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <unordered_set>

namespace epno {

static bool fileExists(const std::string& p) {
    if (p.empty()) return false;
    struct stat st {};
    return ::stat(p.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

static bool isSupportedSampleFile(const std::filesystem::path& p) {
    std::string ext = p.extension().string();
    for (char& c : ext) c = char(std::tolower(static_cast<unsigned char>(c)));
    return (ext == ".npno" || ext == ".nsmp4");
}

static std::vector<std::string> scanNpnoFiles(const std::string& fileOrDir) {
    std::vector<std::string> out;
    try {
        std::filesystem::path p(fileOrDir);
        std::filesystem::path dir = std::filesystem::is_directory(p) ? p : p.parent_path();
        if (dir.empty() || !std::filesystem::exists(dir)) return out;
        for (const auto& entry : std::filesystem::directory_iterator(dir)) {
            if (entry.is_regular_file() && isSupportedSampleFile(entry.path())) {
                out.push_back(entry.path().string());
            } else if (entry.is_directory()) {
                try {
                    for (const auto& sub : std::filesystem::directory_iterator(entry.path())) {
                        if (sub.is_regular_file() && isSupportedSampleFile(sub.path())) {
                            out.push_back(sub.path().string());
                        }
                    }
                } catch (...) {
                }
            }
        }
        std::sort(out.begin(), out.end());
    } catch (...) {
    }
    return out;
}

static std::string prefFilePath() {
    @autoreleasepool {
        NSArray<NSString*>* dirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
        NSString* base = dirs.firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
        NSString* dir = [base stringByAppendingPathComponent:@"ElectroPiano"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        return std::string([[dir stringByAppendingPathComponent:@"last_bank_path.txt"] UTF8String]);
    }
}

std::vector<std::string> ElectroPianoCore::findAllAvailableBankPaths() {
    std::vector<std::string> dirCandidates;

    Dl_info info{};
    if (dladdr((const void*)&ElectroPianoCore::findDefaultBankPath, &info) && info.dli_fname) {
        @autoreleasepool {
            NSString* binPath = [NSString stringWithUTF8String:info.dli_fname];
            NSString* contentsDir = [[binPath stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
            NSString* resSounds = [contentsDir stringByAppendingPathComponent:@"Resources/Sounds"];
            NSString* resDir = [contentsDir stringByAppendingPathComponent:@"Resources"];
            NSString* bundleParent = [[contentsDir stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
            dirCandidates.push_back([resSounds UTF8String]);
            dirCandidates.push_back([resDir UTF8String]);
            dirCandidates.push_back([[bundleParent stringByAppendingPathComponent:@"Sounds"] UTF8String]);
            dirCandidates.push_back([bundleParent UTF8String]);
        }
    }

    @autoreleasepool {
        dirCandidates.push_back("/Library/Application Support/Nord Electro Piano/Sounds");
        dirCandidates.push_back("/Library/Application Support/ElectroPiano/Sounds");
        NSString* userLib = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Nord Electro Piano/Sounds"];
        dirCandidates.push_back([userLib UTF8String]);
        NSString* userLib2 = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/ElectroPiano/Sounds"];
        dirCandidates.push_back([userLib2 UTF8String]);
        NSString* dl = [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads/electro pro"];
        dirCandidates.push_back([[dl stringByAppendingPathComponent:@"Sounds"] UTF8String]);
        dirCandidates.push_back([dl UTF8String]);
    }

    std::vector<std::string> results;
    std::unordered_set<std::string> seenFilenames;

    for (const auto& dir : dirCandidates) {
        auto files = scanNpnoFiles(dir);
        for (const auto& f : files) {
            std::filesystem::path fp(f);
            std::string fname = fp.filename().string();
            if (seenFilenames.insert(fname).second) {
                results.push_back(f);
            }
        }
    }

    std::sort(results.begin(), results.end(), [](const std::string& a, const std::string& b) {
        return std::filesystem::path(a).filename().string() < std::filesystem::path(b).filename().string();
    });

    return results;
}

std::string ElectroPianoCore::findDefaultBankPath() {
    auto all = findAllAvailableBankPaths();
    if (!all.empty()) {
        for (const auto& f : all) {
            if (f.find("Astoria") != std::string::npos || f.find("astoria") != std::string::npos) {
                saveLastBankPath(f);
                return f;
            }
        }
        saveLastBankPath(all.front());
        return all.front();
    }

    {
        std::ifstream in(prefFilePath());
        std::string saved;
        if (std::getline(in, saved) && fileExists(saved)) {
            return saved;
        }
    }
    return "";
}

void ElectroPianoCore::saveLastBankPath(const std::string& path) {
    if (!fileExists(path)) return;
    std::ofstream out(prefFilePath(), std::ios::trunc);
    if (out) {
        out << path << "\n";
    }
}

ElectroPianoCore::ElectroPianoCore() {
    for (uint32_t i = 0; i < kNumParams; ++i) {
        params_[i].store(kParamSpecs[i].defaultVal, std::memory_order_relaxed);
    }
    for (int l = 0; l < 4; ++l) {
        hasStagedInst_[l].store(false, std::memory_order_relaxed);
        loadGen_[l].store(0, std::memory_order_relaxed);
        loading_[l].store(false, std::memory_order_relaxed);
        loadProgress_[l].store(0.0f, std::memory_order_relaxed);
    }
    engine_.prepare(44100.0);

    std::string defPath = findDefaultBankPath();
    if (!defPath.empty()) {
        loadLayerBankAsync(0, defPath);
    }
}

ElectroPianoCore::~ElectroPianoCore() {
    demoRunning_.store(false, std::memory_order_relaxed);
    if (demoThread_.joinable()) {
        demoThread_.join();
    }
    for (int l = 0; l < 4; ++l) {
        loadGen_[l].fetch_add(1, std::memory_order_relaxed);
    }
    std::lock_guard<std::mutex> lk(loadMtx_);
    for (int l = 0; l < 4; ++l) {
        if (loadThread_[l].joinable()) {
            loadThread_[l].join();
        }
    }
}

void ElectroPianoCore::setSampleRate(double sr) {
    if (sr <= 1000.0) sr = 44100.0;
    sampleRate_.store(sr, std::memory_order_relaxed);
    engine_.prepare(sr);
}

void ElectroPianoCore::clearLayerBank(int layer) {
    if (layer < 0 || layer >= 4) return;
    std::lock_guard<std::mutex> lk(loadMtx_);
    loadGen_[layer].fetch_add(1, std::memory_order_relaxed);
    if (loadThread_[layer].joinable()) {
        loadThread_[layer].join();
    }
    loading_[layer].store(false, std::memory_order_relaxed);
    loadProgress_[layer].store(0.0f, std::memory_order_relaxed);
    while (stageSpin_.test_and_set(std::memory_order_acquire)) {}
    stagedInst_[layer].reset();
    hasStagedInst_[layer].store(false, std::memory_order_release);
    retiredInst_[layer] = std::move(audioThreadInst_[layer]);
    engine_.setLayerInstrument(layer, nullptr);
    stageSpin_.clear(std::memory_order_release);
    {
        std::lock_guard<std::mutex> slk(summaryMtx_);
        summaries_[layer] = BankSummary{};
    }
}

void ElectroPianoCore::loadLayerBankAsync(int layer, const std::string& path, bool preserveParams) {
    if (layer < 0 || layer >= 4 || path.empty()) return;
    std::lock_guard<std::mutex> lk(loadMtx_);
    const uint64_t myGen = loadGen_[layer].fetch_add(1, std::memory_order_relaxed) + 1;
    if (loadThread_[layer].joinable()) {
        loadThread_[layer].join();
    }
    preserveEnabledOnStage_[layer].store(preserveParams, std::memory_order_relaxed);
    loading_[layer].store(true, std::memory_order_relaxed);
    loadProgress_[layer].store(0.0f, std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> slk(summaryMtx_);
        summaries_[layer].error.clear();
        summaries_[layer].path = path;
    }

    loadThread_[layer] = std::thread([this, layer, path, myGen, preserveParams]() {
        try {
            auto inst = npno::Instrument::load(
                path,
                [this, layer, myGen](float p) {
                    if (loadGen_[layer].load(std::memory_order_relaxed) == myGen) {
                        loadProgress_[layer].store(p, std::memory_order_relaxed);
                    }
                },
                nullptr);
            if (!inst) {
                throw std::runtime_error("Falha ao decodificar arquivo de timbre");
            }
            if (loadGen_[layer].load(std::memory_order_relaxed) != myGen) return;

            std::shared_ptr<npno::Instrument> sharedInst(std::move(inst));
            auto files = scanNpnoFiles(path);
            int bIdx = 1;
            for (size_t i = 0; i < files.size(); ++i) {
                if (files[i] == path) {
                    bIdx = int(i) + 1;
                    break;
                }
            }

            BankSummary s;
            s.loaded = true;
            s.path = path;
            s.title = sharedInst->name.empty() ? "Timbre Nord" : sharedInst->name;
            s.subtitle = sharedInst->model;
            char verBuf[32];
            std::snprintf(verBuf, sizeof(verBuf), "%u.%02u", sharedInst->fileVersion / 100, sharedInst->fileVersion % 100);
            s.version = verBuf;
            uint32_t normCount = 0;
            uint32_t relCount = 0;
            for (const auto& smp : sharedInst->samples) {
                if (smp.release) ++relCount;
                else ++normCount;
            }
            s.normalSamples = normCount;
            s.releaseSamples = relCount;
            s.memoryMB = double(sharedInst->decodedBytes) / (1024.0 * 1024.0);
            s.damperBoundary = static_cast<uint8_t>(std::clamp(sharedInst->damperBoundary, 0, 127));
            s.bankIndex = bIdx;
            s.bankCount = int(files.size());

            while (stageSpin_.test_and_set(std::memory_order_acquire)) {}
            stagedInst_[layer] = sharedInst;
            retiredInst_[layer].reset();
            hasStagedInst_[layer].store(true, std::memory_order_release);
            stageSpin_.clear(std::memory_order_release);

            {
                std::lock_guard<std::mutex> slk(summaryMtx_);
                summaries_[layer] = std::move(s);
                bankFiles_[layer] = std::move(files);
            }
            if (layer == 0 && !preserveParams) saveLastBankPath(path);
            loadProgress_[layer].store(1.0f, std::memory_order_relaxed);
            loading_[layer].store(false, std::memory_order_relaxed);
        } catch (const std::exception& e) {
            if (loadGen_[layer].load(std::memory_order_relaxed) != myGen) return;
            std::lock_guard<std::mutex> slk(summaryMtx_);
            summaries_[layer].error = e.what();
            loading_[layer].store(false, std::memory_order_relaxed);
        }
    });
}

void ElectroPianoCore::stepLayerBankAsync(int layer, int delta) {
    if (layer < 0 || layer >= 4) return;
    std::string nextPath;
    {
        std::lock_guard<std::mutex> slk(summaryMtx_);
        auto files = bankFiles_[layer];
        if (files.empty() && !bankFiles_[0].empty()) {
            files = bankFiles_[0];
        }
        if (files.empty()) {
            files = findAllAvailableBankPaths();
        }
        if (files.empty()) return;
        int cur = summaries_[layer].bankIndex - 1;
        if (cur < 0) cur = 0;
        int n = int(files.size());
        cur = ((cur + delta) % n + n) % n;
        nextPath = files[size_t(cur)];
    }
    if (!nextPath.empty()) {
        loadLayerBankAsync(layer, nextPath);
    }
}

uint64_t ElectroPianoCore::purgeUnusedSamples() {
    engine_.panic();
    uint64_t freed = 0;
    std::lock_guard<std::mutex> slk(summaryMtx_);
    while (stageSpin_.test_and_set(std::memory_order_acquire)) {}
    for (int l = 0; l < 4; ++l) {
        if (audioThreadInst_[l]) {
            freed += audioThreadInst_[l]->purgeUnusedSamples();
            summaries_[l].memoryMB = double(audioThreadInst_[l]->decodedBytes) / (1024.0 * 1024.0);
        }
    }
    stageSpin_.clear(std::memory_order_release);
    return freed;
}

bool ElectroPianoCore::reloadPurgedSamples() {
    engine_.panic();
    bool ok = true;
    std::lock_guard<std::mutex> slk(summaryMtx_);
    while (stageSpin_.test_and_set(std::memory_order_acquire)) {}
    for (int l = 0; l < 4; ++l) {
        if (audioThreadInst_[l]) {
            if (!audioThreadInst_[l]->reloadPurgedSamples()) ok = false;
            summaries_[l].memoryMB = double(audioThreadInst_[l]->decodedBytes) / (1024.0 * 1024.0);
        }
    }
    stageSpin_.clear(std::memory_order_release);
    return ok;
}

uint64_t ElectroPianoCore::totalMemoryBytes() const {
    uint64_t total = 0;
    for (int l = 0; l < 4; ++l) {
        const auto* inst = engine_.layerInstrument(l);
        if (inst) total += inst->decodedBytes;
    }
    return total;
}

uint64_t ElectroPianoCore::totalUnpurgedBytes() const {
    uint64_t total = 0;
    for (int l = 0; l < 4; ++l) {
        const auto* inst = engine_.layerInstrument(l);
        if (inst) total += inst->totalDecodedBytes;
    }
    return total;
}

void ElectroPianoCore::applyPendingInstrumentOnAudioThread() {
    bool any = false;
    for (int l = 0; l < 4; ++l) {
        if (hasStagedInst_[l].load(std::memory_order_acquire)) {
            any = true;
            break;
        }
    }
    if (!any) return;
    if (!stageSpin_.test_and_set(std::memory_order_acquire)) {
        for (int l = 0; l < 4; ++l) {
            if (hasStagedInst_[l].load(std::memory_order_relaxed) && stagedInst_[l]) {
                const bool keepEnabled = preserveEnabledOnStage_[l].load(std::memory_order_relaxed);
                const bool prevEnabled = engine_.layerParams(l).enabled;
                retiredInst_[l] = std::move(audioThreadInst_[l]);
                audioThreadInst_[l] = std::move(stagedInst_[l]);
                engine_.setLayerInstrument(l, audioThreadInst_[l].get());
                if (keepEnabled) {
                    auto lp = engine_.layerParams(l);
                    lp.enabled = prevEnabled;
                    engine_.setLayerParams(l, lp);
                    preserveEnabledOnStage_[l].store(false, std::memory_order_relaxed);
                }
                hasStagedInst_[l].store(false, std::memory_order_release);
            }
        }
        stageSpin_.clear(std::memory_order_release);
    }
}

void ElectroPianoCore::notifyStateChanged() {
    std::function<void(uint32_t, float)> cb;
    {
        std::lock_guard<std::mutex> lk(cbMtx_);
        cb = paramChangeCb_;
    }
    if (cb) {
        cb(kParamMasterGainDb, getParamNormalized(kParamMasterGainDb));
    }
}

namespace {
struct BinaryWriter {
    std::vector<uint8_t> buf;
    void u8(uint8_t v) { buf.push_back(v); }
    void i32(int32_t v) { u32(static_cast<uint32_t>(v)); }
    void u32(uint32_t v) {
        buf.push_back(uint8_t(v & 0xFF));
        buf.push_back(uint8_t((v >> 8) & 0xFF));
        buf.push_back(uint8_t((v >> 16) & 0xFF));
        buf.push_back(uint8_t((v >> 24) & 0xFF));
    }
    void f32(float v) {
        uint32_t bits = 0;
        std::memcpy(&bits, &v, sizeof(float));
        u32(bits);
    }
    void str(const std::string& s) {
        u32(static_cast<uint32_t>(s.size()));
        buf.insert(buf.end(), s.begin(), s.end());
    }
};

struct BinaryReader {
    const uint8_t* data;
    size_t size;
    size_t pos = 0;
    bool ok = true;
    uint8_t u8() {
        if (pos + 1 > size) { ok = false; return 0; }
        return data[pos++];
    }
    uint32_t u32() {
        if (pos + 4 > size) { ok = false; return 0; }
        uint32_t v = uint32_t(data[pos]) | (uint32_t(data[pos + 1]) << 8) |
                     (uint32_t(data[pos + 2]) << 16) | (uint32_t(data[pos + 3]) << 24);
        pos += 4;
        return v;
    }
    int32_t i32() { return static_cast<int32_t>(u32()); }
    float f32() {
        uint32_t bits = u32();
        float v = 0.0f;
        std::memcpy(&v, &bits, sizeof(float));
        return std::isfinite(v) ? v : 0.0f;
    }
    std::string str() {
        uint32_t len = u32();
        if (!ok || len > 16384 || pos + len > size) { ok = false; return ""; }
        std::string s(reinterpret_cast<const char*>(data + pos), len);
        pos += len;
        return s;
    }
};
}  // namespace

std::vector<uint8_t> ElectroPianoCore::serializeState() const {
    BinaryWriter w;
    w.u32(0x54535045u); // 'EPST'
    w.u32(2u);          // version 2

    for (uint32_t i = 0; i < kNumParams; ++i) {
        w.f32(getParam(i));
    }

    w.f32(engine_.fineTuneCents());
    w.f32(engine_.masterPan());
    w.i32(engine_.maxVoices());
    w.i32(midiChannel());
    w.u8(engine_.driveEnabled() ? 1 : 0);
    w.f32(engine_.driveAmount());

    for (int m = 0; m < 2; ++m) {
        auto mp = engine_.modulatorParams(m);
        w.u8(mp.enabled ? 1 : 0);
        w.i32(mp.target);
        w.i32(mp.wave);
        w.f32(mp.rateHz);
        w.f32(mp.depth);
    }

    {
        auto d = engine_.delayParams();
        w.u8(d.enabled ? 1 : 0);
        w.f32(d.timeMs);
        w.f32(d.feedback);
        w.f32(d.amount);
        w.u8(d.pingPong ? 1 : 0);
        w.u8(d.syncToHost ? 1 : 0);
        w.i32(d.syncDivision);
        w.f32(d.hostBpm);
    }

    {
        auto r = engine_.reverbParams();
        w.u8(r.enabled ? 1 : 0);
        w.f32(r.size);
        w.f32(r.decay);
        w.f32(r.damping);
        w.f32(r.preDelayMs);
        w.f32(r.amount);
    }

    for (int l = 0; l < 4; ++l) {
        auto lp = engine_.layerParams(l);
        w.u8(lp.enabled ? 1 : 0);
        w.f32(lp.volume);
        w.f32(lp.filter);
        w.f32(lp.fxaAmount);
        w.f32(lp.fxaRelease);
        w.i32(lp.timbreMode);
        w.u8(lp.sustainPedalOn ? 1 : 0);
        w.u8(lp.undampedOn ? 1 : 0);
        w.u8(lp.compOn ? 1 : 0);
        w.f32(lp.compAmount);
        w.u8(lp.compFast ? 1 : 0);
        w.i32(lp.octaveShift);
        w.u8(lp.originalEnvelope ? 1 : 0);
        w.f32(lp.attackMs);
        w.f32(lp.releaseMs);
        w.i32(lp.keyLow);
        w.i32(lp.keyHigh);
        w.i32(lp.velLow);
        w.i32(lp.velHigh);
        w.i32(lp.midiChannel);
        w.i32(lp.velocityCurve);
        w.i32(lp.pitchBendDown);
        w.i32(lp.pitchBendUp);
        w.u8(lp.portamentoOn ? 1 : 0);
        w.f32(lp.portamentoTimeMs);
        w.u8(lp.fixedVelocity ? 1 : 0);
        w.i32(lp.fixedVelocityValue);
        w.u8(lp.legatoMono ? 1 : 0);
        w.i32(lp.ccVolume);
        w.i32(lp.ccFilter);
        w.i32(lp.ccFxaAmount);
        w.i32(lp.ccFxaRelease);

        std::string lpath;
        {
            std::lock_guard<std::mutex> slk(summaryMtx_);
            lpath = summaries_[l].path;
        }
        w.str(lpath);
    }

    return w.buf;
}

bool ElectroPianoCore::deserializeState(const uint8_t* data, size_t size) {
    if (!data || size < 4) return false;
    BinaryReader r{data, size, 0, true};
    uint32_t magicOrVer = r.u32();

    // Retrocompatibilidade com formato v1 antigo
    if (magicOrVer == 1u) {
        for (uint32_t i = 0; i < kNumParams; ++i) {
            float v = r.f32();
            if (!r.ok) return false;
            setParam(i, v);
        }
        std::string path = r.str();
        if (r.ok && !path.empty() && fileExists(path)) {
            loadLayerBankAsync(0, path, true);
        }
        return true;
    }

    if (magicOrVer != 0x54535045u) return false;
    uint32_t ver = r.u32();
    if (!r.ok || ver < 2u) return false;

    for (uint32_t i = 0; i < kNumParams; ++i) {
        setParam(i, r.f32());
    }

    engine_.setFineTuneCents(r.f32());
    engine_.setMasterPan(r.f32());
    engine_.setMaxVoices(r.i32());
    setMidiChannel(r.i32());
    engine_.setDriveEnabled(r.u8() != 0);
    engine_.setDriveAmount(r.f32());

    for (int m = 0; m < 2; ++m) {
        npno::ModulatorParams mp;
        mp.enabled = r.u8() != 0;
        mp.target = r.i32();
        mp.wave = r.i32();
        mp.rateHz = r.f32();
        mp.depth = r.f32();
        if (r.ok) engine_.setModulatorParams(m, mp);
    }

    {
        npno::DelayParams d;
        d.enabled = r.u8() != 0;
        d.timeMs = r.f32();
        d.feedback = r.f32();
        d.amount = r.f32();
        d.pingPong = r.u8() != 0;
        d.syncToHost = r.u8() != 0;
        d.syncDivision = r.i32();
        d.hostBpm = r.f32();
        if (r.ok) engine_.setDelayParams(d);
    }

    {
        npno::ReverbParams rev;
        rev.enabled = r.u8() != 0;
        rev.size = r.f32();
        rev.decay = r.f32();
        rev.damping = r.f32();
        rev.preDelayMs = r.f32();
        rev.amount = r.f32();
        if (r.ok) engine_.setReverbParams(rev);
    }

    auto available = findAllAvailableBankPaths();

    for (int l = 0; l < 4; ++l) {
        npno::LayerParams lp;
        lp.enabled = r.u8() != 0;
        lp.volume = r.f32();
        lp.filter = r.f32();
        lp.fxaAmount = r.f32();
        lp.fxaRelease = r.f32();
        lp.timbreMode = r.i32();
        lp.sustainPedalOn = r.u8() != 0;
        lp.undampedOn = r.u8() != 0;
        lp.compOn = r.u8() != 0;
        lp.compAmount = r.f32();
        lp.compFast = r.u8() != 0;
        lp.octaveShift = r.i32();
        lp.originalEnvelope = r.u8() != 0;
        lp.attackMs = r.f32();
        lp.releaseMs = r.f32();
        lp.keyLow = r.i32();
        lp.keyHigh = r.i32();
        lp.velLow = r.i32();
        lp.velHigh = r.i32();
        lp.midiChannel = r.i32();
        lp.velocityCurve = r.i32();
        lp.pitchBendDown = r.i32();
        lp.pitchBendUp = r.i32();
        lp.portamentoOn = r.u8() != 0;
        lp.portamentoTimeMs = r.f32();
        lp.fixedVelocity = r.u8() != 0;
        lp.fixedVelocityValue = r.i32();
        lp.legatoMono = r.u8() != 0;
        lp.ccVolume = r.i32();
        lp.ccFilter = r.i32();
        lp.ccFxaAmount = r.i32();
        lp.ccFxaRelease = r.i32();
        std::string savedPath = r.str();
        if (!r.ok) return false;

        engine_.setLayerParams(l, lp);

        if (!savedPath.empty()) {
            std::string resolved = savedPath;
            if (!fileExists(resolved)) {
                std::string fname = std::filesystem::path(savedPath).filename().string();
                for (const auto& cand : available) {
                    if (std::filesystem::path(cand).filename().string() == fname) {
                        resolved = cand;
                        break;
                    }
                }
            }
            if (fileExists(resolved)) {
                std::string curPath;
                bool curLoaded = false;
                {
                    std::lock_guard<std::mutex> slk(summaryMtx_);
                    curPath = summaries_[l].path;
                    curLoaded = summaries_[l].loaded || loading_[l].load(std::memory_order_relaxed);
                }
                if (!curLoaded || curPath != resolved) {
                    loadLayerBankAsync(l, resolved, true);
                } else {
                    preserveEnabledOnStage_[l].store(true, std::memory_order_relaxed);
                }
            }
        } else if (l > 0) {
            clearLayerBank(l);
            engine_.setLayerParams(l, lp);
        }
    }

    return true;
}

ElectroPianoCore::BankSummary ElectroPianoCore::getLayerSummary(int layer) const {
    if (layer < 0 || layer >= 4) return BankSummary{};
    if (!const_cast<ElectroPianoCore*>(this)->stageSpin_.test_and_set(std::memory_order_acquire)) {
        std::shared_ptr<npno::Instrument> toDrop = std::move(const_cast<ElectroPianoCore*>(this)->retiredInst_[layer]);
        const_cast<ElectroPianoCore*>(this)->stageSpin_.clear(std::memory_order_release);
        (void)toDrop;
    }
    std::lock_guard<std::mutex> slk(summaryMtx_);
    return summaries_[layer];
}

float ElectroPianoCore::getParam(uint32_t id) const {
    if (id >= kNumParams) return 0.0f;
    return params_[id].load(std::memory_order_relaxed);
}

void ElectroPianoCore::setParam(uint32_t id, float value) {
    if (id >= kNumParams || std::isnan(value) || std::isinf(value)) return;
    const auto& spec = kParamSpecs[id];
    float clamped = std::clamp(value, spec.minVal, spec.maxVal);
    if (spec.isStepped) clamped = std::round(clamped);
    params_[id].store(clamped, std::memory_order_relaxed);

    switch (id) {
        case kParamMasterGainDb:
            engine_.setMasterGain(std::pow(10.0f, clamped / 20.0f));
            break;
        case kParamVelocityCurve:
            engine_.setVelocityCurve(int(clamped) - 1);
            break;
        case kParamTranspose:
            engine_.setTransposeSemitones(int(clamped));
            break;
        case kParamTuningHz:
            engine_.setBaseTuningHz(clamped);
            break;
        case kParamReleaseSamples: {
            const float gain = clamped / 100.0f;
            engine_.setReleaseSampleGain(gain);
            engine_.setReleaseSamplesEnabled(gain > 0.005f);
            break;
        }
        case kParamSustainPedal:
            engine_.pushEvent(npno::Engine::EventType::Sustain, 0, clamped >= 0.5f ? 1.0f : 0.0f);
            break;
        case kParamReleaseTime:
            engine_.setReleaseScale(clamped / 100.0f);
            break;
        case kParamEqBassDb:
            engine_.setEqBassDb(clamped);
            break;
        case kParamEqMidDb:
            engine_.setEqMidDb(clamped);
            break;
        case kParamEqMidFreqHz:
            engine_.setEqMidFreqHz(clamped);
            break;
        case kParamEqTrebleDb:
            engine_.setEqTrebleDb(clamped);
            break;
        default:
            break;
    }
}

void ElectroPianoCore::resetAllParams() {
    for (uint32_t i = 0; i < kNumParams; ++i) {
        setParam(i, kParamSpecs[i].defaultVal);
    }
}

float ElectroPianoCore::plainToNormalized(uint32_t id, float plain) {
    if (id >= kNumParams) return 0.0f;
    const auto& s = kParamSpecs[id];
    if (s.maxVal <= s.minVal) return 0.0f;
    return std::clamp((plain - s.minVal) / (s.maxVal - s.minVal), 0.0f, 1.0f);
}

float ElectroPianoCore::normalizedToPlain(uint32_t id, float norm) {
    if (id >= kNumParams) return 0.0f;
    const auto& s = kParamSpecs[id];
    float v = s.minVal + std::clamp(norm, 0.0f, 1.0f) * (s.maxVal - s.minVal);
    return s.isStepped ? std::round(v) : v;
}

float ElectroPianoCore::getParamNormalized(uint32_t id) const {
    return plainToNormalized(id, getParam(id));
}

void ElectroPianoCore::setParamNormalized(uint32_t id, float norm) {
    setParam(id, normalizedToPlain(id, norm));
}

void ElectroPianoCore::markNoteActive(int note, bool active) {
    if (note < 0 || note > 127) return;
    if (note < 64) {
        uint64_t bit = uint64_t(1) << note;
        if (active) activeNotesLo_.fetch_or(bit, std::memory_order_relaxed);
        else activeNotesLo_.fetch_and(~bit, std::memory_order_relaxed);
    } else {
        uint64_t bit = uint64_t(1) << (note - 64);
        if (active) activeNotesHi_.fetch_or(bit, std::memory_order_relaxed);
        else activeNotesHi_.fetch_and(~bit, std::memory_order_relaxed);
    }
}

void ElectroPianoCore::handleMidiEvent(uint8_t status, uint8_t data1, uint8_t data2) {
    const uint8_t type = status & 0xF0;
    const int chan = int(status & 0x0F) + 1;
    const int filter = midiChannel_.load(std::memory_order_relaxed);
    if (filter != 0 && filter != chan && type < 0xF0) {
        return;
    }

    switch (type) {
        case 0x90:
            if (data2 > 0) {
                markNoteActive(data1 & 0x7F, true);
                engine_.pushEvent(npno::Engine::EventType::NoteOn, data1 & 0x7F, float(data2 & 0x7F) / 127.0f, chan);
            } else {
                markNoteActive(data1 & 0x7F, false);
                engine_.pushEvent(npno::Engine::EventType::NoteOff, data1 & 0x7F, 0.0f, chan);
            }
            break;
        case 0x80:
            markNoteActive(data1 & 0x7F, false);
            engine_.pushEvent(npno::Engine::EventType::NoteOff, data1 & 0x7F, 0.0f, chan);
            break;
        case 0xB0: {
            const uint8_t cc = data1 & 0x7F;
            const uint8_t val = data2 & 0x7F;
            if (cc == 64) {
                setSustain(val >= 64);
            } else if (cc == 120 || cc == 123) {
                panic();
            } else {
                engine_.pushEvent(npno::Engine::EventType::ControlChange, cc, float(val), chan);
            }
            break;
        }
        case 0xE0: {
            const int bend14 = (int(data2 & 0x7F) << 7) | int(data1 & 0x7F);
            const float norm = float(bend14 - 8192) / 8192.0f;
            engine_.pushEvent(npno::Engine::EventType::PitchBend, 0, norm, chan);
            break;
        }
        default:
            break;
    }
}

void ElectroPianoCore::noteOn(int midiNote, uint8_t velocity) {
    const int n = std::clamp(midiNote, 0, 127);
    if (velocity == 0) {
        noteOff(n);
        return;
    }
    markNoteActive(n, true);
    engine_.pushEvent(npno::Engine::EventType::NoteOn, n, float(std::clamp<int>(velocity, 1, 127)) / 127.0f, 0);
}

void ElectroPianoCore::noteOff(int midiNote) {
    const int n = std::clamp(midiNote, 0, 127);
    markNoteActive(n, false);
    engine_.pushEvent(npno::Engine::EventType::NoteOff, n, 0.0f, 0);
}

void ElectroPianoCore::setSustain(bool down) {
    params_[kParamSustainPedal].store(down ? 1.0f : 0.0f, std::memory_order_relaxed);
    engine_.pushEvent(npno::Engine::EventType::Sustain, 0, down ? 1.0f : 0.0f, 0);
}

void ElectroPianoCore::setPitchBendSemitones(float semitones) {
    engine_.pushEvent(npno::Engine::EventType::PitchBend, 0, semitones, 0);
}

void ElectroPianoCore::panic() {
    activeNotesLo_.store(0, std::memory_order_relaxed);
    activeNotesHi_.store(0, std::memory_order_relaxed);
    params_[kParamSustainPedal].store(0.0f, std::memory_order_relaxed);
    engine_.pushEvent(npno::Engine::EventType::Panic, 0, 0.0f, 0);
}

void ElectroPianoCore::toggleDemo() {
    if (demoRunning_.load(std::memory_order_relaxed)) {
        demoRunning_.store(false, std::memory_order_relaxed);
        if (demoThread_.joinable()) demoThread_.join();
        panic();
        return;
    }
    if (demoThread_.joinable()) demoThread_.join();
    demoRunning_.store(true, std::memory_order_relaxed);
    demoThread_ = std::thread([this]() {
        struct Step {
            int ms;
            int kind;
            int note;
            uint8_t vel;
        };
        static const Step seq[] = {
            {0, 2, 0, 127},   {0, 0, 48, 86},   {180, 0, 55, 78}, {360, 0, 60, 84},
            {540, 0, 64, 92}, {720, 0, 67, 88}, {900, 0, 72, 98}, {1500, 1, 48, 0},
            {1500, 1, 55, 0}, {1500, 1, 60, 0}, {1500, 1, 64, 0}, {1500, 1, 67, 0},
            {1500, 1, 72, 0}, {1600, 2, 0, 0},  {1680, 2, 0, 127},{1700, 0, 45, 84},
            {1880, 0, 52, 78},{2060, 0, 57, 82},{2240, 0, 60, 88},{2420, 0, 64, 92},
            {2600, 0, 69, 96},{3200, 1, 45, 0}, {3200, 1, 52, 0}, {3200, 1, 57, 0},
            {3200, 1, 60, 0}, {3200, 1, 64, 0}, {3200, 1, 69, 0}, {3300, 2, 0, 0},
            {3380, 2, 0, 127},{3400, 0, 41, 86},{3580, 0, 48, 80},{3760, 0, 53, 84},
            {3940, 0, 57, 88},{4120, 0, 60, 92},{4300, 0, 65, 96},{4900, 2, 0, 0},
            {4980, 2, 0, 127},{5000, 0, 43, 88},{5180, 0, 50, 82},{5360, 0, 55, 86},
            {5540, 0, 59, 90},{5720, 0, 62, 94},{5900, 0, 67, 98},{6500, 2, 0, 0},
            {6580, 2, 0, 127},{6600, 0, 36, 96},{6620, 0, 48, 92},{6640, 0, 55, 90},
            {6660, 0, 60, 94},{6680, 0, 64, 98},{6700, 0, 72, 105},{8200, 1, 36, 0},
            {8200, 1, 48, 0}, {8200, 1, 55, 0}, {8200, 1, 60, 0}, {8200, 1, 64, 0},
            {8200, 1, 72, 0}, {8600, 2, 0, 0}
        };
        int prevMs = 0;
        for (const auto& s : seq) {
            int waitMs = s.ms - prevMs;
            prevMs = s.ms;
            for (int w = 0; w < waitMs && demoRunning_.load(std::memory_order_relaxed); w += 15) {
                std::this_thread::sleep_for(std::chrono::milliseconds(std::min(15, waitMs - w)));
            }
            if (!demoRunning_.load(std::memory_order_relaxed)) break;
            if (s.kind == 0) noteOn(s.note, s.vel);
            else if (s.kind == 1) noteOff(s.note);
            else setSustain(s.vel >= 64);
        }
        demoRunning_.store(false, std::memory_order_relaxed);
    });
}

void ElectroPianoCore::render(float* outL, float* outR, int numFrames) {
    if (!outL || !outR || numFrames <= 0) return;
    applyPendingInstrumentOnAudioThread();
    engine_.render(outL, outR, numFrames);

    float maxL = 0.0f, maxR = 0.0f;
    for (int i = 0; i < numFrames; ++i) {
        maxL = std::max(maxL, std::fabs(outL[i]));
        maxR = std::max(maxR, std::fabs(outR[i]));
    }
    peakL_.store(std::max(maxL, peakL_.load(std::memory_order_relaxed) * 0.85f), std::memory_order_relaxed);
    peakR_.store(std::max(maxR, peakR_.load(std::memory_order_relaxed) * 0.85f), std::memory_order_relaxed);
}

}  // namespace epno

// ============================================================================
// Interface Gráfica Cocoa Completa (7 Seções / 4 Camadas — 1140 x 650)
// ============================================================================

#if defined(EPNO_BUILD_VST3)
#define ElectroPianoPluginMainView ElectroPianoVST3PluginMainView
#define ElectroPianoSettingsViewController ElectroPianoVST3SettingsViewController
#endif

namespace {

struct DynamicKnob {
    NSRect rect;
    NSString* title;
    float minVal;
    float maxVal;
    float defaultVal;
    float currentVal;
    bool stepped;
    bool enabled;
    NSString* valueText;
    std::function<void(float)> onChange;
};

struct DynamicButton {
    NSRect rect;
    NSString* label;
    bool ledOn;
    int ledColorType; // 0=none, 1=green, 2=red, 3=amber, 4=cyan
    std::function<void()> onClick;
};

static NSString* formatMidiNote(int note) {
    static const char* kNames[12] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
    int c = std::clamp(note, 0, 127);
    return [NSString stringWithFormat:@"%s%d", kNames[c % 12], (c / 12) - 1];
}

}  // namespace

@interface ElectroPianoSettingsViewController : NSViewController
@property(nonatomic, assign) epno::ElectroPianoCore* core;
@end

@implementation ElectroPianoSettingsViewController {
    NSPopUpButton* _midiChannelPopup;
    NSTextField* _audioInfoLabel;
}

- (void)loadView {
    NSView* v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 380, 194)];
    self.view = v;

    NSTextField* header = [NSTextField labelWithString:@"CONFIGURAÇÕES DE MIDI E ÁUDIO (PLUGIN)"];
    header.font = [NSFont systemFontOfSize:13 weight:NSFontWeightBlack];
    header.textColor = [NSColor whiteColor];
    header.frame = NSMakeRect(16, 158, 348, 20);
    [v addSubview:header];

    NSTextField* midiLbl = [NSTextField labelWithString:@"Canal de Recepção MIDI Global:"];
    midiLbl.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold];
    midiLbl.frame = NSMakeRect(16, 120, 175, 20);
    [v addSubview:midiLbl];

    _midiChannelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(195, 116, 168, 26) pullsDown:NO];
    [_midiChannelPopup addItemWithTitle:@"Omni (Todos 1–16)"];
    for (int ch = 1; ch <= 16; ++ch) {
        [_midiChannelPopup addItemWithTitle:[NSString stringWithFormat:@"Canal %d", ch]];
    }
    _midiChannelPopup.target = self;
    _midiChannelPopup.action = @selector(onMidiChannelChanged:);
    [v addSubview:_midiChannelPopup];

    NSButton* audioSetupBtn = [NSButton buttonWithTitle:@"Open Audio MIDI Setup…"
                                                 target:self
                                                 action:@selector(onOpenAudioPanel:)];
    audioSetupBtn.frame = NSMakeRect(16, 76, 348, 28);
    audioSetupBtn.bezelStyle = NSBezelStyleRounded;
    [v addSubview:audioSetupBtn];

    _audioInfoLabel = [NSTextField labelWithString:@"Saída Estéreo 32-bit Float (Host DAW / MainStage)"];
    _audioInfoLabel.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightMedium];
    _audioInfoLabel.textColor = [NSColor secondaryLabelColor];
    _audioInfoLabel.frame = NSMakeRect(16, 26, 348, 38);
    [v addSubview:_audioInfoLabel];

    if (_core) {
        [_midiChannelPopup selectItemAtIndex:std::clamp(_core->midiChannel(), 0, 16)];
        _audioInfoLabel.stringValue = [NSString stringWithFormat:@"Saída Estéreo 32-bit Float • %.1f kHz (Host DAW / MainStage)",
                                                                 _core->sampleRate() / 1000.0];
    }
}

- (void)onOpenAudioPanel:(id)sender {
    (void)sender;
    NSURL* url = [NSURL fileURLWithPath:@"/System/Applications/Utilities/Audio MIDI Setup.app"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)onMidiChannelChanged:(id)sender {
    (void)sender;
    if (_core) {
        _core->setMidiChannel((int)_midiChannelPopup.indexOfSelectedItem);
        _core->notifyStateChanged();
    }
}
@end

@interface ElectroPianoPluginMainView : NSView {
    epno::ElectroPianoCore* _core;
    NSTimer* _uiTimer;

    int _selectedTab;   // 0=Timbre, 1=Teclado&Curva, 2=MIDI&CC, 3=EQ|Drive&Mod, 4=Delay&Reverb
    int _selectedLayer; // 0..3 (A..D)
    CGFloat _uiScale;   // 0.70 .. 1.50 (fixa proporção 1140x650 sem distorcer itens)

    std::vector<DynamicKnob> _knobs;
    std::vector<DynamicButton> _buttons;
    int _activeKnobIdx;
    CGFloat _dragStartY;
    float _dragStartVal;

    NSPopover* _settingsPopover;
    ElectroPianoSettingsViewController* _settingsVC;
}
- (instancetype)initWithFrame:(NSRect)frame core:(epno::ElectroPianoCore*)core;
- (CGFloat)uiScale;
@end

static constexpr CGFloat kPluginBaseWidth = 1140.0;
static constexpr CGFloat kPluginBaseHeight = 650.0;
static NSString* const kPluginUIScaleDefaultsKey = @"ElectroPiano_PluginUIScale_v1";

@implementation ElectroPianoPluginMainView

- (instancetype)initWithFrame:(NSRect)frame core:(epno::ElectroPianoCore*)core {
    double savedScale = [[NSUserDefaults standardUserDefaults] doubleForKey:kPluginUIScaleDefaultsKey];
    CGFloat initScale = (savedScale >= 0.70 && savedScale <= 1.60) ? (CGFloat)savedScale : 1.0;
    NSRect scaledFrame = NSMakeRect(frame.origin.x,
                                    frame.origin.y,
                                    std::round(kPluginBaseWidth * initScale),
                                    std::round(kPluginBaseHeight * initScale));
    self = [super initWithFrame:scaledFrame];
    if (self) {
        self.postsFrameChangedNotifications = YES;
        _core = core;
        _selectedTab = 0;
        _selectedLayer = 0;
        _uiScale = initScale;
        _activeKnobIdx = -1;

        [self rebuildLayout];

        __weak ElectroPianoPluginMainView* weakSelf = self;
        _uiTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
                                                   repeats:YES
                                                     block:^(NSTimer* _Nonnull) {
                                                         [weakSelf tickUI];
                                                     }];
        [[NSRunLoop mainRunLoop] addTimer:_uiTimer forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (CGFloat)uiScale {
    return _uiScale;
}

- (void)applyUIScale:(CGFloat)nextScale {
    _uiScale = std::clamp<CGFloat>(std::round(nextScale * 20.0) / 20.0, 0.70, 1.50);
    [[NSUserDefaults standardUserDefaults] setDouble:(double)_uiScale forKey:kPluginUIScaleDefaultsKey];
    NSSize newSize = NSMakeSize(std::round(kPluginBaseWidth * _uiScale),
                                std::round(kPluginBaseHeight * _uiScale));
    [self setFrameSize:newSize];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSViewFrameDidChangeNotification object:self];
    [self rebuildLayout];
    [self setNeedsDisplay:YES];
}

- (void)computeCanvasTransform:(CGFloat*)outScale offsetX:(CGFloat*)outOffX offsetY:(CGFloat*)outOffY {
    const CGFloat W = std::max<CGFloat>(1.0, self.bounds.size.width);
    const CGFloat H = std::max<CGFloat>(1.0, self.bounds.size.height);
    const CGFloat s = std::min(W / kPluginBaseWidth, H / kPluginBaseHeight);
    if (outScale) *outScale = s;
    if (outOffX) *outOffX = std::floor((W - kPluginBaseWidth * s) * 0.5);
    if (outOffY) *outOffY = std::floor((H - kPluginBaseHeight * s) * 0.5);
}

- (NSPoint)logicalPointFromEvent:(NSEvent*)event {
    NSPoint raw = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat s = 1.0, ox = 0.0, oy = 0.0;
    [self computeCanvasTransform:&s offsetX:&ox offsetY:&oy];
    return NSMakePoint((raw.x - ox) / s, (raw.y - oy) / s);
}

- (NSRect)viewRectFromLogicalRect:(NSRect)r {
    CGFloat s = 1.0, ox = 0.0, oy = 0.0;
    [self computeCanvasTransform:&s offsetX:&ox offsetY:&oy];
    return NSMakeRect(ox + r.origin.x * s, oy + r.origin.y * s, r.size.width * s, r.size.height * s);
}

- (BOOL)isFlipped {
    return YES;
}

- (void)removeFromSuperview {
    [_uiTimer invalidate];
    _uiTimer = nil;
    [super removeFromSuperview];
}

- (void)dealloc {
    [_uiTimer invalidate];
    _uiTimer = nil;
}

- (void)openFilePickerForLayer:(int)layer {
    if (!_core) return;
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    const char* lNames[4] = {"A", "B", "C", "D"};
    panel.title = [NSString stringWithFormat:@"Selecionar Timbre .npno / .nsmp4 para Camada %s", lNames[layer & 3]];
    std::string defPath = epno::ElectroPianoCore::findDefaultBankPath();
    if (!defPath.empty()) {
        NSString* dir = [[NSString stringWithUTF8String:defPath.c_str()] stringByDeletingLastPathComponent];
        panel.directoryURL = [NSURL fileURLWithPath:dir isDirectory:YES];
    }
    NSMutableArray<UTType*>* types = [NSMutableArray array];
    UTType* npnoType = [UTType typeWithFilenameExtension:@"npno"];
    if (npnoType) [types addObject:npnoType];
    UTType* nsmp4Type = [UTType typeWithFilenameExtension:@"nsmp4"];
    if (nsmp4Type) [types addObject:nsmp4Type];
    if (types.count > 0) panel.allowedContentTypes = types;
    if ([panel runModal] == NSModalResponseOK && panel.URL.path) {
        _core->loadLayerBankAsync(layer, [panel.URL.path UTF8String]);
        _core->notifyStateChanged();
    }
}

- (void)onSelectTimbreMenuItem:(NSMenuItem*)sender {
    if (!_core) return;
    int layer = (int)(sender.tag >> 16) & 0x3;
    int action = (int)(sender.tag & 0xFFFF);
    if (action == 0xFFFF) {
        [self openFilePickerForLayer:layer];
        return;
    }
    NSString* pathObj = (NSString*)sender.representedObject;
    if (pathObj && [pathObj isKindOfClass:[NSString class]]) {
        _core->loadLayerBankAsync(layer, [pathObj UTF8String]);
        _core->notifyStateChanged();
    }
}

- (void)showTimbreMenuForLayer:(int)layer atPoint:(NSPoint)pt {
    if (!_core) return;
    auto files = _core->findAllAvailableBankPaths();
    if (files.empty()) {
        std::string curPath = _core->getLayerSummary(layer).path;
        if (curPath.empty()) curPath = _core->getLayerSummary(0).path;
        if (curPath.empty()) curPath = epno::ElectroPianoCore::findDefaultBankPath();
        files = epno::scanNpnoFiles(curPath);
    }

    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Timbres Nord"];
    for (size_t i = 0; i < files.size(); ++i) {
        NSString* fullPath = [NSString stringWithUTF8String:files[i].c_str()];
        NSString* dispName = [[fullPath lastPathComponent] stringByDeletingPathExtension];
        NSString* title = [NSString stringWithFormat:@"%02zu. %@", i + 1, dispName];
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                      action:@selector(onSelectTimbreMenuItem:)
                                               keyEquivalent:@""];
        item.target = self;
        item.tag = ((layer & 3) << 16) | (int)(i & 0x7FFF);
        item.representedObject = fullPath;
        if (files[i] == _core->getLayerSummary(layer).path && _core->getLayerSummary(layer).loaded) {
            item.state = NSControlStateValueOn;
        }
        [menu addItem:item];
    }
    if (!files.empty()) {
        [menu addItem:[NSMenuItem separatorItem]];
    }
    NSMenuItem* browseItem = [[NSMenuItem alloc] initWithTitle:@"Abrir outro arquivo .npno / .nsmp4 do disco..."
                                                        action:@selector(onSelectTimbreMenuItem:)
                                                 keyEquivalent:@""];
    browseItem.target = self;
    browseItem.tag = ((layer & 3) << 16) | 0xFFFF;
    [menu addItem:browseItem];

    NSRect vRect = [self viewRectFromLogicalRect:NSMakeRect(pt.x, pt.y, 1, 1)];
    [menu popUpMenuPositioningItem:nil atLocation:vRect.origin inView:self];
}

- (void)showSettingsPopoverAtRect:(NSRect)anchor {
    if (!_settingsPopover) {
        _settingsVC = [[ElectroPianoSettingsViewController alloc] init];
        _settingsVC.core = _core;
        _settingsPopover = [[NSPopover alloc] init];
        _settingsPopover.contentViewController = _settingsVC;
        _settingsPopover.behavior = NSPopoverBehaviorTransient;
    }
    if (_settingsPopover.isShown) {
        [_settingsPopover close];
    } else {
        NSRect vAnchor = [self viewRectFromLogicalRect:anchor];
        [_settingsPopover showRelativeToRect:vAnchor ofView:self preferredEdge:NSRectEdgeMaxY];
    }
}

- (void)tickUI {
    if (_activeKnobIdx < 0) {
        [self rebuildLayout];
    }
    [self setNeedsDisplay:YES];
}

- (void)addSteppedKnobWithNudge:(DynamicKnob)kw step:(float)step {
    NSRect orig = kw.rect;
    kw.rect = NSMakeRect(orig.origin.x, orig.origin.y, orig.size.width, orig.size.height - 18.0);
    _knobs.push_back(kw);

    CGFloat btnY = orig.origin.y + orig.size.height - 16.0;
    CGFloat halfW = std::floor((orig.size.width - 8.0) * 0.5);
    float cur = kw.currentVal;
    float minV = kw.minVal;
    float maxV = kw.maxVal;
    auto cb = kw.onChange;
    _buttons.push_back({NSMakeRect(orig.origin.x + 2.0, btnY, halfW, 15.0), @"◀", false, 0,
                        [cb, cur, minV, maxV, step]() {
                            if (cb) cb(std::clamp(std::round(cur - step), minV, maxV));
                        }});
    _buttons.push_back({NSMakeRect(orig.origin.x + 4.0 + halfW, btnY, halfW, 15.0), @"▶", false, 0,
                        [cb, cur, minV, maxV, step]() {
                            if (cb) cb(std::clamp(std::round(cur + step), minV, maxV));
                        }});
}

- (void)rebuildLayout {
    _knobs.clear();
    _buttons.clear();
    if (!_core) return;

    auto& eng = _core->engine();

    // --- SEÇÃO 1: BARRA SUPERIOR MESTRE (DEMO, PANIC, TRANSPOSE -/+, KNOBS MASTER, ZOOM -/+) ---
    _buttons.push_back({NSMakeRect(22, 34, 86, 22),
                        _core->isDemoPlaying() ? @"■ STOP" : @"▶ DEMO",
                        _core->isDemoPlaying(), 2,
                        [self]() { _core->toggleDemo(); }});
    _buttons.push_back({NSMakeRect(112, 34, 64, 22),
                        @"PANIC", _core->activeVoices() > 0, 2,
                        [self]() { _core->panic(); }});

    // TRANSPOSE por botões de -1 / +1 semitom + visor clicável (zera)
    int trSt = (int)std::lround(_core->getParam(epno::kParamTranspose));
    _buttons.push_back({NSMakeRect(188, 28, 28, 26), @"−", trSt < 0, 3,
                        [self, trSt]() {
                            _core->setParam(epno::kParamTranspose, (float)std::max(-12, trSt - 1));
                        }});
    _buttons.push_back({NSMakeRect(218, 28, 52, 26),
                        trSt == 0 ? @"0 st" : [NSString stringWithFormat:@"%+d st", trSt],
                        trSt != 0, 3,
                        [self]() {
                            _core->setParam(epno::kParamTranspose, 0.0f);
                        }});
    _buttons.push_back({NSMakeRect(272, 28, 28, 26), @"+", trSt > 0, 3,
                        [self, trSt]() {
                            _core->setParam(epno::kParamTranspose, (float)std::min(12, trSt + 1));
                        }});

    // Knobs Master: VOLUME, PAN, FINE TUNE
    float volDb = _core->getParam(epno::kParamMasterGainDb);
    _knobs.push_back({NSMakeRect(310, 4, 56, 56), @"VOLUME", -36.0f, 12.0f, 0.0f, volDb, false, true,
                      [NSString stringWithFormat:@"%+.1f dB", volDb],
                      [self](float v) { _core->setParam(epno::kParamMasterGainDb, v); }});

    float panPct = eng.masterPan() * 100.0f;
    int panInt = (int)std::lround(panPct);
    NSString* panTxt = (panInt == 0) ? @"CENTER" : (panInt < 0 ? [NSString stringWithFormat:@"%dL", -panInt]
                                                               : [NSString stringWithFormat:@"%dR", panInt]);
    _knobs.push_back({NSMakeRect(368, 4, 56, 56), @"PAN", -100.0f, 100.0f, 0.0f, panPct, false, true, panTxt,
                      [self](float v) { _core->engine().setMasterPan(v / 100.0f); }});

    float tuneCt = eng.fineTuneCents();
    _knobs.push_back({NSMakeRect(426, 4, 56, 56), @"FINE", -100.0f, 100.0f, 0.0f, tuneCt, false, true,
                      [NSString stringWithFormat:@"%+.0f ct", tuneCt],
                      [self](float v) { _core->engine().setFineTuneCents(v); }});

    // Controle de Redimensionamento / ZOOM da Interface (- / % / +)
    int zoomPct = (int)std::lround(_uiScale * 100.0);
    _buttons.push_back({NSMakeRect(760, 10, 26, 22), @"−", false, 0,
                        [self]() { [self applyUIScale:_uiScale - 0.10]; }});
    _buttons.push_back({NSMakeRect(788, 10, 56, 22),
                        [NSString stringWithFormat:@"%d%%", zoomPct],
                        zoomPct != 100, 4,
                        [self]() { [self applyUIScale:1.0]; }});
    _buttons.push_back({NSMakeRect(846, 10, 26, 22), @"+", false, 0,
                        [self]() { [self applyUIScale:_uiScale + 0.10]; }});

    int globCh = _core->midiChannel();
    _buttons.push_back({NSMakeRect(760, 35, 112, 21),
                        globCh == 0 ? @"MIDI: OMNI" : [NSString stringWithFormat:@"MIDI: CH %d", globCh],
                        globCh > 0, 3,
                        [self, globCh]() {
                            _core->setMidiChannel((globCh + 1) % 17);
                        }});

    bool isPurged = _core->totalMemoryBytes() < _core->totalUnpurgedBytes();
    _buttons.push_back({NSMakeRect(880, 10, 88, 22), @"PURGE RAM", isPurged, 3,
                        [self]() { _core->purgeUnusedSamples(); }});
    _buttons.push_back({NSMakeRect(972, 10, 68, 22), @"RELOAD", false, 0,
                        [self]() { _core->reloadPurgedSamples(); }});
    int maxV = eng.maxVoices();
    _buttons.push_back({NSMakeRect(1044, 10, 72, 22),
                        [NSString stringWithFormat:@"%d VOZ", maxV], true, 3,
                        [self, maxV]() {
                            int next = (maxV == 64) ? 128 : (maxV == 128 ? 256 : (maxV == 256 ? 512 : 64));
                            _core->engine().setMaxVoices(next);
                        }});

    _buttons.push_back({NSMakeRect(880, 35, 114, 21), @"⚙ CONFIG", false, 3,
                        [self]() { [self showSettingsPopoverAtRect:NSMakeRect(880, 35, 114, 21)]; }});
    _buttons.push_back({NSMakeRect(998, 35, 118, 21), @"CORE AUDIO", false, 3,
                        []() {
                            NSURL* url = [NSURL fileURLWithPath:@"/System/Applications/Utilities/Audio MIDI Setup.app"];
                            [[NSWorkspace sharedWorkspace] openURL:url];
                        }});

    // --- SEÇÃO 2: 4 CAMADAS A / B / C / D ---
    const char* lNames[4] = {"A", "B", "C", "D"};
    for (int l = 0; l < 4; ++l) {
        CGFloat cx = 22.0 + l * 276.0;
        npno::LayerParams lp = eng.layerParams(l);

        _buttons.push_back({NSMakeRect(cx + 8, 72, 122, 22),
                            [NSString stringWithFormat:@"CAMADA %s %s", lNames[l], lp.enabled ? "ON" : "OFF"],
                            lp.enabled, 1,
                            [self, l]() {
                                auto p = _core->engine().layerParams(l);
                                p.enabled = !p.enabled;
                                _core->engine().setLayerParams(l, p);
                            }});

        _buttons.push_back({NSMakeRect(cx + 184, 72, 76, 22),
                            @"EDITAR", _selectedLayer == l, 3,
                            [self, l]() { _selectedLayer = l; }});

        _buttons.push_back({NSMakeRect(cx + 8, 180, 66, 22), @"◀ ANT", false, 0,
                            [self, l]() { _core->stepLayerBankAsync(l, -1); }});
        _buttons.push_back({NSMakeRect(cx + 78, 180, 66, 22), @"PRÓX ▶", false, 0,
                            [self, l]() { _core->stepLayerBankAsync(l, 1); }});
        bool loaded = _core->getLayerSummary(l).loaded;
        _buttons.push_back({NSMakeRect(cx + 148, 180, 112, 22), @"TIMBRES ▼", loaded, 1,
                            [self, l, cx]() { [self showTimbreMenuForLayer:l atPoint:NSMakePoint(cx + 148, 202)]; }});

        // 4 Knobs da camada: VOLUME, FILTRO, FXA AM, FXA RT
        float volP = lp.volume * 100.0f;
        _knobs.push_back({NSMakeRect(cx + 6, 210, 62, 116), @"VOLUME", 0.0f, 150.0f, 100.0f, volP, false, true,
                          [NSString stringWithFormat:@"%.0f%%", volP],
                          [self, l](float v) {
                              auto p = _core->engine().layerParams(l);
                              p.volume = v / 100.0f;
                              _core->engine().setLayerParams(l, p);
                          }});

        float fltP = lp.filter * 100.0f;
        double fc = 140.0 * std::pow(142.857, double(lp.filter));
        NSString* fltTxt = (fc >= 1000.0) ? [NSString stringWithFormat:@"%.1fk", fc / 1000.0]
                                          : [NSString stringWithFormat:@"%.0fHz", fc];
        _knobs.push_back({NSMakeRect(cx + 70, 210, 62, 116), @"FILTRO", 0.0f, 100.0f, 100.0f, fltP, false, true, fltTxt,
                          [self, l](float v) {
                              auto p = _core->engine().layerParams(l);
                              p.filter = v / 100.0f;
                              _core->engine().setLayerParams(l, p);
                          }});

        float fxaAm = lp.fxaAmount * 100.0f;
        _knobs.push_back({NSMakeRect(cx + 134, 210, 62, 116), @"FXA AM", 0.0f, 100.0f, 20.0f, fxaAm, false, true,
                          [NSString stringWithFormat:@"%.0f%%", fxaAm],
                          [self, l](float v) {
                              auto p = _core->engine().layerParams(l);
                              p.fxaAmount = v / 100.0f;
                              _core->engine().setLayerParams(l, p);
                          }});

        float fxaRt = lp.fxaRelease * 100.0f;
        _knobs.push_back({NSMakeRect(cx + 198, 210, 62, 116), @"FXA RT", 0.0f, 100.0f, 50.0f, fxaRt, false, true,
                          [NSString stringWithFormat:@"%.0f%%", fxaRt],
                          [self, l](float v) {
                              auto p = _core->engine().layerParams(l);
                              p.fxaRelease = v / 100.0f;
                              _core->engine().setLayerParams(l, p);
                          }});
    }

    // --- BARRA DE 5 ABAS DO RACK INFERIOR ---
    NSString* tabTitles[5] = {
        @"1. TIMBRE & ENVELOPE",
        @"2. TECLADO & TOQUE",
        @"3. MIDI & CC LEARN",
        @"4. EQ • DRIVE • MOD",
        @"5. DELAY & REVERB"
    };
    CGFloat tabWidths[5] = {152.0, 152.0, 146.0, 154.0, 146.0};
    CGFloat tabX = 22.0;
    for (int t = 0; t < 5; ++t) {
        _buttons.push_back({NSMakeRect(tabX, 344, tabWidths[t], 26), tabTitles[t], _selectedTab == t, 3,
                            [self, t]() { _selectedTab = t; }});
        tabX += tabWidths[t] + 5.0;
    }
    for (int l = 0; l < 4; ++l) {
        _buttons.push_back({NSMakeRect(822 + l * 74, 344, 70, 26),
                            [NSString stringWithFormat:@"CAMADA %s", lNames[l]],
                            _selectedLayer == l, 1,
                            [self, l]() { _selectedLayer = l; }});
    }

    const int sl = _selectedLayer;
    npno::LayerParams slp = eng.layerParams(sl);

    if (_selectedTab == 0) {
        // --- ABA 1: TIMBRE & ENVELOPE ---
        const char* tModes[5] = {"MID", "BRIGHT", "SOFT", "DYNO 1", "DYNO 2"};
        const int tOrder[5] = {1, 0, 2, 3, 4};
        for (int i = 0; i < 5; ++i) {
            int m = tOrder[i];
            _buttons.push_back({NSMakeRect(36 + i * 76, 412, 72, 26),
                                [NSString stringWithUTF8String:tModes[m]],
                                slp.timbreMode == m, 3,
                                [self, sl, m]() {
                                    auto p = _core->engine().layerParams(sl);
                                    p.timbreMode = m;
                                    _core->engine().setLayerParams(sl, p);
                                }});
        }

        _buttons.push_back({NSMakeRect(36, 452, 128, 26), @"SUSTPED (CC64)", slp.sustainPedalOn, 1,
                            [self, sl]() {
                                auto p = _core->engine().layerParams(sl);
                                p.sustainPedalOn = !p.sustainPedalOn;
                                _core->engine().setLayerParams(sl, p);
                            }});
        _buttons.push_back({NSMakeRect(170, 452, 128, 26), @"RESSONÂNCIA", slp.undampedOn, 1,
                            [self, sl]() {
                                auto p = _core->engine().layerParams(sl);
                                p.undampedOn = !p.undampedOn;
                                _core->engine().setLayerParams(sl, p);
                            }});

        // Oitava com botões - / visor / +
        _buttons.push_back({NSMakeRect(306, 452, 32, 26), @"−", slp.octaveShift < 0, 3,
                            [self, sl]() {
                                auto p = _core->engine().layerParams(sl);
                                p.octaveShift = std::max(-3, p.octaveShift - 1);
                                _core->engine().setLayerParams(sl, p);
                            }});
        _buttons.push_back({NSMakeRect(340, 452, 66, 26),
                            [NSString stringWithFormat:@"OIT %+d", slp.octaveShift],
                            slp.octaveShift != 0, 3,
                            [self, sl]() {
                                auto p = _core->engine().layerParams(sl);
                                p.octaveShift = 0;
                                _core->engine().setLayerParams(sl, p);
                            }});
        _buttons.push_back({NSMakeRect(408, 452, 32, 26), @"+", slp.octaveShift > 0, 3,
                            [self, sl]() {
                                auto p = _core->engine().layerParams(sl);
                                p.octaveShift = std::min(3, p.octaveShift + 1);
                                _core->engine().setLayerParams(sl, p);
                            }});

        // Compressor
        _buttons.push_back({NSMakeRect(464, 418, 108, 26), slp.compOn ? @"COMP ON" : @"COMP OFF", slp.compOn, 2,
                            [self, sl]() {
                                auto p = _core->engine().layerParams(sl);
                                p.compOn = !p.compOn;
                                _core->engine().setLayerParams(sl, p);
                            }});
        _buttons.push_back({NSMakeRect(464, 454, 108, 26), @"ATAQUE RÁP.", slp.compFast, 3,
                            [self, sl]() {
                                auto p = _core->engine().layerParams(sl);
                                p.compFast = !p.compFast;
                                _core->engine().setLayerParams(sl, p);
                            }});
        float compAmt = slp.compAmount * 100.0f;
        _knobs.push_back({NSMakeRect(580, 410, 74, 116), @"COMP AMT", 0.0f, 100.0f, 45.0f, compAmt, false, slp.compOn,
                          [NSString stringWithFormat:@"%.0f%%", compAmt],
                          [self, sl](float v) {
                              auto p = _core->engine().layerParams(sl);
                              p.compAmount = v / 100.0f;
                              _core->engine().setLayerParams(sl, p);
                          }});

        // Envelope & Soltura
        _buttons.push_back({NSMakeRect(692, 424, 128, 28), @"ENV ORIGINAL", slp.originalEnvelope, 1,
                            [self, sl]() {
                                auto p = _core->engine().layerParams(sl);
                                p.originalEnvelope = !p.originalEnvelope;
                                _core->engine().setLayerParams(sl, p);
                            }});

        _knobs.push_back({NSMakeRect(832, 410, 74, 116), @"ATAQUE", 0.5f, 1500.0f, 1.0f, slp.attackMs, false,
                          !slp.originalEnvelope,
                          [NSString stringWithFormat:@"%.0f ms", slp.attackMs],
                          [self, sl](float v) {
                              auto p = _core->engine().layerParams(sl);
                              p.attackMs = v;
                              _core->engine().setLayerParams(sl, p);
                          }});

        _knobs.push_back({NSMakeRect(916, 410, 74, 116), @"RELEASE", 30.0f, 4000.0f, 600.0f, slp.releaseMs, false,
                          !slp.originalEnvelope,
                          [NSString stringWithFormat:@"%.0f ms", slp.releaseMs],
                          [self, sl](float v) {
                              auto p = _core->engine().layerParams(sl);
                              p.releaseMs = v;
                              _core->engine().setLayerParams(sl, p);
                          }});

        float relNoise = _core->getParam(epno::kParamReleaseSamples);
        _knobs.push_back({NSMakeRect(1000, 410, 74, 116), @"SOLTURA", 0.0f, 200.0f, 100.0f, relNoise, false, true,
                          relNoise <= 0.5f ? @"OFF" : [NSString stringWithFormat:@"%.0f%%", relNoise],
                          [self](float v) { _core->setParam(epno::kParamReleaseSamples, v); }});

    } else if (_selectedTab == 1) {
        // --- ABA 2: TECLADO & TOQUE (ZONAS, TRANSPOSE -/+, CURVA VISUAL INTERATIVA) ---
        [self addSteppedKnobWithNudge:{NSMakeRect(32, 404, 64, 126), @"K. LOW", 0.0f, 127.0f, 0.0f, float(slp.keyLow), true, true,
                                       formatMidiNote(slp.keyLow),
                                       [self, sl](float v) {
                                           auto p = _core->engine().layerParams(sl);
                                           p.keyLow = (int)std::lround(v);
                                           _core->engine().setLayerParams(sl, p);
                                       }} step:1.0f];
        [self addSteppedKnobWithNudge:{NSMakeRect(100, 404, 64, 126), @"K. HIGH", 0.0f, 127.0f, 127.0f, float(slp.keyHigh), true, true,
                                       formatMidiNote(slp.keyHigh),
                                       [self, sl](float v) {
                                           auto p = _core->engine().layerParams(sl);
                                           p.keyHigh = (int)std::lround(v);
                                           _core->engine().setLayerParams(sl, p);
                                       }} step:1.0f];
        [self addSteppedKnobWithNudge:{NSMakeRect(168, 404, 64, 126), @"V. MÍN", 1.0f, 127.0f, 1.0f, float(slp.velLow), true, true,
                                       [NSString stringWithFormat:@"%d", slp.velLow],
                                       [self, sl](float v) {
                                           auto p = _core->engine().layerParams(sl);
                                           p.velLow = (int)std::lround(v);
                                           _core->engine().setLayerParams(sl, p);
                                       }} step:1.0f];
        [self addSteppedKnobWithNudge:{NSMakeRect(236, 404, 64, 126), @"V. MÁX", 1.0f, 127.0f, 127.0f, float(slp.velHigh), true, true,
                                       [NSString stringWithFormat:@"%d", slp.velHigh],
                                       [self, sl](float v) {
                                           auto p = _core->engine().layerParams(sl);
                                           p.velHigh = (int)std::lround(v);
                                           _core->engine().setLayerParams(sl, p);
                                       }} step:1.0f];

        _buttons.push_back({NSMakeRect(36, 540, 260, 22), @"RESETAR ZONA (A0..C8 • VEL 1..127)", false, 0,
                            [self, sl]() {
                                auto p = _core->engine().layerParams(sl);
                                p.keyLow = 0; p.keyHigh = 127; p.velLow = 1; p.velHigh = 127;
                                _core->engine().setLayerParams(sl, p);
                            }});

        // Coluna Central: Pitch Bend, Portamento, Legato e Transpose -/+
        [self addSteppedKnobWithNudge:{NSMakeRect(318, 404, 64, 126), @"BEND ↓", -24.0f, 0.0f, -2.0f, float(slp.pitchBendDown), true, true,
                                       [NSString stringWithFormat:@"%+d st", slp.pitchBendDown],
                                       [self, sl](float v) {
                                           auto p = _core->engine().layerParams(sl);
                                           p.pitchBendDown = (int)std::lround(v);
                                           _core->engine().setLayerParams(sl, p);
                                       }} step:1.0f];
        [self addSteppedKnobWithNudge:{NSMakeRect(386, 404, 64, 126), @"BEND ↑", 0.0f, 24.0f, 2.0f, float(slp.pitchBendUp), true, true,
                                       [NSString stringWithFormat:@"%+d st", slp.pitchBendUp],
                                       [self, sl](float v) {
                                           auto p = _core->engine().layerParams(sl);
                                           p.pitchBendUp = (int)std::lround(v);
                                           _core->engine().setLayerParams(sl, p);
                                       }} step:1.0f];

        _knobs.push_back({NSMakeRect(454, 404, 68, 116), @"PORT TIME", 5.0f, 1500.0f, 120.0f, slp.portamentoTimeMs, false, slp.portamentoOn,
                          [NSString stringWithFormat:@"%.0f ms", slp.portamentoTimeMs],
                          [self, sl](float v) {
                              auto p = _core->engine().layerParams(sl);
                              p.portamentoTimeMs = v;
                              _core->engine().setLayerParams(sl, p);
                          }});

        _buttons.push_back({NSMakeRect(320, 540, 96, 22), @"PORTAMENTO", slp.portamentoOn, 1,
                            [self, sl]() {
                                auto p = _core->engine().layerParams(sl);
                                p.portamentoOn = !p.portamentoOn;
                                _core->engine().setLayerParams(sl, p);
                            }});
        _buttons.push_back({NSMakeRect(420, 540, 100, 22), @"LEGATO MONO", slp.legatoMono, 2,
                            [self, sl]() {
                                auto p = _core->engine().layerParams(sl);
                                p.legatoMono = !p.legatoMono;
                                _core->engine().setLayerParams(sl, p);
                            }});

        // Painel Direito (x=540..1100): SENSIBILIDADE DAS TECLAS & CURVA DE VELOCIDADE
        // (Gráfico visual fica em x=552, y=412, w=156, h=146 desenhado em drawRect)
        // 6 botões diretos para a curva da camada: SOFT(1), LOG(5), NORMAL(0), LINEAR(2), HARD(3), EXP(4)
        struct CurveBtnDef { int code; const char* title; };
        static const CurveBtnDef kCurveDefs[6] = {
            {1, "SOFT (LEVE)"}, {5, "LOG (RÁPIDA)"}, {0, "NORMAL"},
            {2, "LINEAR"},      {3, "HARD (PESADA)"}, {4, "EXP (FORTE)"}
        };
        for (int i = 0; i < 6; ++i) {
            int col = i % 3;
            int row = i / 3;
            int code = kCurveDefs[i].code;
            CGFloat bx = 724.0 + col * 124.0;
            CGFloat by = 414.0 + row * 32.0;
            _buttons.push_back({NSMakeRect(bx, by, 118, 26),
                                [NSString stringWithUTF8String:kCurveDefs[i].title],
                                !slp.fixedVelocity && slp.velocityCurve == code, 3,
                                [self, sl, code]() {
                                    auto p = _core->engine().layerParams(sl);
                                    p.fixedVelocity = false;
                                    p.velocityCurve = code;
                                    _core->engine().setLayerParams(sl, p);
                                }});
        }

        // Sensibilidade Global KBD TOUCH: LEVE(0), NORMAL(1), PESADA(2) + VEL FIXA 127
        int globTouch = (int)std::lround(_core->getParam(epno::kParamVelocityCurve));
        const char* touchNames[3] = {"TOQUE: LEVE", "TOQUE: NORMAL", "TOQUE: PESADA"};
        for (int t = 0; t < 3; ++t) {
            _buttons.push_back({NSMakeRect(724.0 + t * 92.0, 496.0, 88.0, 24.0),
                                [NSString stringWithUTF8String:touchNames[t]],
                                globTouch == t, 4,
                                [self, t]() {
                                    _core->setParam(epno::kParamVelocityCurve, (float)t);
                                }});
        }
        _buttons.push_back({NSMakeRect(1002.0, 496.0, 94.0, 24.0), @"VEL FIXA 127", slp.fixedVelocity, 2,
                            [self, sl]() {
                                auto p = _core->engine().layerParams(sl);
                                p.fixedVelocity = !p.fixedVelocity;
                                _core->engine().setLayerParams(sl, p);
                            }});

        // Botões dedicados de TRANSPOSE (-1 / Visor / +1 semitom) também na aba de Teclado
        _buttons.push_back({NSMakeRect(724.0, 534.0, 96.0, 26.0), @"TRANSPOSE −1", trSt < 0, 3,
                            [self, trSt]() {
                                _core->setParam(epno::kParamTranspose, (float)std::max(-12, trSt - 1));
                            }});
        _buttons.push_back({NSMakeRect(824.0, 534.0, 170.0, 26.0),
                            trSt == 0 ? @"TRANSPOSE: 0 SEMITONS" : [NSString stringWithFormat:@"TRANSPOSE: %+d SEMITONS", trSt],
                            trSt != 0, 3,
                            [self]() {
                                _core->setParam(epno::kParamTranspose, 0.0f);
                            }});
        _buttons.push_back({NSMakeRect(998.0, 534.0, 98.0, 26.0), @"TRANSPOSE +1", trSt > 0, 3,
                            [self, trSt]() {
                                _core->setParam(epno::kParamTranspose, (float)std::min(12, trSt + 1));
                            }});

    } else if (_selectedTab == 2) {
        // --- ABA 3: MIDI & CC LEARN ---
        const char* ccNames[4] = {"VOLUME CC", "FILTRO CC", "FXA AMT CC", "FXA REL CC"};
        int ccs[4] = {slp.ccVolume, slp.ccFilter, slp.ccFxaAmount, slp.ccFxaRelease};
        for (int s = 0; s < 4; ++s) {
            CGFloat cx = 36.0 + s * 195.0;
            NSString* ccStr = (ccs[s] < 0) ? [NSString stringWithFormat:@"%s: OFF", ccNames[s]]
                                           : [NSString stringWithFormat:@"%s: CC %d", ccNames[s], ccs[s]];
            _buttons.push_back({NSMakeRect(cx, 424, 180, 28), ccStr, ccs[s] >= 0, 3,
                                [self, sl, s]() {
                                    static const int kPresets[] = {-1, 1, 7, 11, 71, 74, 91, 93};
                                    auto p = _core->engine().layerParams(sl);
                                    int cur = (s == 0) ? p.ccVolume : (s == 1 ? p.ccFilter : (s == 2 ? p.ccFxaAmount : p.ccFxaRelease));
                                    int next = -1;
                                    for (size_t i = 0; i < 8; ++i) {
                                        if (kPresets[i] == cur) { next = kPresets[(i + 1) % 8]; break; }
                                    }
                                    if (s == 0) p.ccVolume = next;
                                    else if (s == 1) p.ccFilter = next;
                                    else if (s == 2) p.ccFxaAmount = next;
                                    else p.ccFxaRelease = next;
                                    _core->engine().setLayerParams(sl, p);
                                }});
            bool learning = (eng.midiLearnLayer() == sl && eng.midiLearnSlot() == s);
            _buttons.push_back({NSMakeRect(cx, 462, 180, 28), learning ? @"AGUARDANDO CC..." : @"MIDI LEARN", learning, 2,
                                [self, sl, s, learning]() {
                                    if (learning) _core->engine().cancelMidiLearn();
                                    else _core->engine().startMidiLearn(sl, s);
                                }});
        }

        _buttons.push_back({NSMakeRect(36, 516, 240, 28),
                            slp.midiChannel == 0 ? @"CANAL DA CAMADA: GLOBAL (OMNI)" : [NSString stringWithFormat:@"CANAL DA CAMADA: CH %d", slp.midiChannel],
                            slp.midiChannel > 0, 3,
                            [self, sl]() {
                                auto p = _core->engine().layerParams(sl);
                                p.midiChannel = (p.midiChannel + 1) % 17;
                                _core->engine().setLayerParams(sl, p);
                            }});

        float a4 = _core->getParam(epno::kParamTuningHz);
        _knobs.push_back({NSMakeRect(860, 412, 82, 118), @"GLOBAL A4", 432.0f, 446.0f, 440.0f, a4, false, true,
                          [NSString stringWithFormat:@"%.1f Hz", a4],
                          [self](float v) { _core->setParam(epno::kParamTuningHz, v); }});

    } else if (_selectedTab == 3) {
        // --- ABA 4: EQ • DRIVE • MOD 1/2 ---
        float bass = _core->getParam(epno::kParamEqBassDb);
        float midG = _core->getParam(epno::kParamEqMidDb);
        float midF = _core->getParam(epno::kParamEqMidFreqHz);
        float treb = _core->getParam(epno::kParamEqTrebleDb);

        _knobs.push_back({NSMakeRect(34, 410, 68, 116), @"BASS", -15.0f, 15.0f, 0.0f, bass, false, true,
                          [NSString stringWithFormat:@"%+.1f dB", bass],
                          [self](float v) { _core->setParam(epno::kParamEqBassDb, v); }});
        _knobs.push_back({NSMakeRect(106, 410, 68, 116), @"MID GAIN", -15.0f, 15.0f, 0.0f, midG, false, true,
                          [NSString stringWithFormat:@"%+.1f dB", midG],
                          [self](float v) { _core->setParam(epno::kParamEqMidDb, v); }});
        _knobs.push_back({NSMakeRect(178, 410, 68, 116), @"MID FREQ", 200.0f, 5000.0f, 1000.0f, midF, false, true,
                          midF >= 1000.0f ? [NSString stringWithFormat:@"%.1fk", midF / 1000.0f]
                                          : [NSString stringWithFormat:@"%.0fHz", midF],
                          [self](float v) { _core->setParam(epno::kParamEqMidFreqHz, v); }});
        _knobs.push_back({NSMakeRect(250, 410, 68, 116), @"TREBLE", -15.0f, 15.0f, 0.0f, treb, false, true,
                          [NSString stringWithFormat:@"%+.1f dB", treb],
                          [self](float v) { _core->setParam(epno::kParamEqTrebleDb, v); }});

        bool drvOn = eng.driveEnabled();
        float drvAmt = eng.driveAmount() * 100.0f;
        _buttons.push_back({NSMakeRect(328, 424, 92, 26), drvOn ? @"DRIVE ON" : @"DRIVE OFF", drvOn, 2,
                            [self, drvOn]() { _core->engine().setDriveEnabled(!drvOn); }});
        _buttons.push_back({NSMakeRect(328, 460, 92, 26), @"EQ FLAT", false, 0,
                            [self]() {
                                _core->setParam(epno::kParamEqBassDb, 0.0f);
                                _core->setParam(epno::kParamEqMidDb, 0.0f);
                                _core->setParam(epno::kParamEqMidFreqHz, 1000.0f);
                                _core->setParam(epno::kParamEqTrebleDb, 0.0f);
                            }});
        _knobs.push_back({NSMakeRect(428, 410, 68, 116), @"DRIVE", 0.0f, 100.0f, 25.0f, drvAmt, false, drvOn,
                          [NSString stringWithFormat:@"%.0f%%", drvAmt],
                          [self](float v) { _core->engine().setDriveAmount(v / 100.0f); }});

        // MOD 1 e MOD 2
        const char* targets[4] = {"VOL", "FILTER", "PITCH", "PAN"};
        const char* waves[5] = {"SINE", "TRI", "SAW", "SQUARE", "ENV"};
        for (int m = 0; m < 2; ++m) {
            CGFloat mx = 526.0 + m * 290.0;
            npno::ModulatorParams mp = eng.modulatorParams(m);
            _buttons.push_back({NSMakeRect(mx, 414, 116, 24),
                                [NSString stringWithFormat:@"MOD %d %s", m + 1, mp.enabled ? "ON" : "OFF"],
                                mp.enabled, 1,
                                [self, m]() {
                                    auto p = _core->engine().modulatorParams(m);
                                    p.enabled = !p.enabled;
                                    _core->engine().setModulatorParams(m, p);
                                }});
            _buttons.push_back({NSMakeRect(mx, 444, 116, 24),
                                [NSString stringWithFormat:@"DEST: %s", targets[std::clamp(mp.target, 0, 3)]],
                                true, 3,
                                [self, m]() {
                                    auto p = _core->engine().modulatorParams(m);
                                    p.target = (p.target + 1) % 4;
                                    _core->engine().setModulatorParams(m, p);
                                }});
            _buttons.push_back({NSMakeRect(mx, 474, 116, 24),
                                [NSString stringWithFormat:@"WAVE: %s", waves[std::clamp(mp.wave, 0, 4)]],
                                true, 4,
                                [self, m]() {
                                    auto p = _core->engine().modulatorParams(m);
                                    p.wave = (p.wave + 1) % 5;
                                    _core->engine().setModulatorParams(m, p);
                                }});
            _knobs.push_back({NSMakeRect(mx + 124, 410, 68, 116), @"RATE", 0.1f, 20.0f, 4.5f, mp.rateHz, false, mp.enabled,
                              [NSString stringWithFormat:@"%.1f Hz", mp.rateHz],
                              [self, m](float v) {
                                  auto p = _core->engine().modulatorParams(m);
                                  p.rateHz = v;
                                  _core->engine().setModulatorParams(m, p);
                              }});
            float dPct = mp.depth * 100.0f;
            _knobs.push_back({NSMakeRect(mx + 196, 410, 68, 116), @"DEPTH", 0.0f, 100.0f, 35.0f, dPct, false, mp.enabled,
                              [NSString stringWithFormat:@"%.0f%%", dPct],
                              [self, m](float v) {
                                  auto p = _core->engine().modulatorParams(m);
                                  p.depth = v / 100.0f;
                                  _core->engine().setModulatorParams(m, p);
                              }});
        }

    } else {
        // --- ABA 5: DELAY & REVERB ---
        npno::DelayParams dly = eng.delayParams();
        npno::ReverbParams rev = eng.reverbParams();

        _buttons.push_back({NSMakeRect(36, 412, 110, 24), dly.enabled ? @"DELAY ON" : @"DELAY OFF", dly.enabled, 1,
                            [self]() {
                                auto d = _core->engine().delayParams();
                                d.enabled = !d.enabled;
                                _core->engine().setDelayParams(d);
                            }});
        _buttons.push_back({NSMakeRect(36, 442, 110, 24), @"PING PONG", dly.pingPong, 3,
                            [self]() {
                                auto d = _core->engine().delayParams();
                                d.pingPong = !d.pingPong;
                                _core->engine().setDelayParams(d);
                            }});
        _buttons.push_back({NSMakeRect(36, 472, 110, 24), @"SYNC BPM", dly.syncToHost, 4,
                            [self]() {
                                auto d = _core->engine().delayParams();
                                d.syncToHost = !d.syncToHost;
                                _core->engine().setDelayParams(d);
                            }});
        _buttons.push_back({NSMakeRect(36, 502, 110, 24), @"TAP DELAY", false, 0,
                            [self]() {
                                double now = std::chrono::duration<double>(
                                                 std::chrono::steady_clock::now().time_since_epoch())
                                                 .count();
                                _core->engine().tapDelay(now);
                            }});

        float dAmt = dly.amount * 100.0f;
        _knobs.push_back({NSMakeRect(160, 410, 72, 116), @"DLY AMT", 0.0f, 100.0f, 25.0f, dAmt, false, true,
                          [NSString stringWithFormat:@"%.0f%%", dAmt],
                          [self](float v) {
                              auto d = _core->engine().delayParams();
                              d.amount = v / 100.0f;
                              _core->engine().setDelayParams(d);
                          }});
        float dFb = dly.feedback * 100.0f;
        _knobs.push_back({NSMakeRect(238, 410, 72, 116), @"FEEDBACK", 0.0f, 92.0f, 35.0f, dFb, false, true,
                          [NSString stringWithFormat:@"%.0f%%", dFb],
                          [self](float v) {
                              auto d = _core->engine().delayParams();
                              d.feedback = v / 100.0f;
                              _core->engine().setDelayParams(d);
                          }});
        _knobs.push_back({NSMakeRect(316, 410, 72, 116), @"TEMPO MS", 20.0f, 2000.0f, 360.0f, dly.timeMs, false, !dly.syncToHost,
                          [NSString stringWithFormat:@"%.0f ms", dly.timeMs],
                          [self](float v) {
                              auto d = _core->engine().delayParams();
                              d.timeMs = v;
                              _core->engine().setDelayParams(d);
                          }});
        _knobs.push_back({NSMakeRect(394, 410, 72, 116), @"HOST BPM", 40.0f, 240.0f, 120.0f, dly.hostBpm, false, dly.syncToHost,
                          [NSString stringWithFormat:@"%.0f BPM", dly.hostBpm],
                          [self](float v) {
                              auto d = _core->engine().delayParams();
                              d.hostBpm = v;
                              _core->engine().setDelayParams(d);
                          }});

        // Reverb
        _buttons.push_back({NSMakeRect(566, 424, 110, 26), rev.enabled ? @"REVERB ON" : @"REVERB OFF", rev.enabled, 1,
                            [self]() {
                                auto r = _core->engine().reverbParams();
                                r.enabled = !r.enabled;
                                _core->engine().setReverbParams(r);
                            }});

        float rAmt = rev.amount * 100.0f;
        _knobs.push_back({NSMakeRect(688, 410, 74, 116), @"REV AMT", 0.0f, 100.0f, 22.0f, rAmt, false, true,
                          [NSString stringWithFormat:@"%.0f%%", rAmt],
                          [self](float v) {
                              auto r = _core->engine().reverbParams();
                              r.amount = v / 100.0f;
                              _core->engine().setReverbParams(r);
                          }});
        float rSz = rev.size * 100.0f;
        _knobs.push_back({NSMakeRect(768, 410, 74, 116), @"SIZE", 10.0f, 100.0f, 65.0f, rSz, false, true,
                          [NSString stringWithFormat:@"%.0f%%", rSz],
                          [self](float v) {
                              auto r = _core->engine().reverbParams();
                              r.size = v / 100.0f;
                              _core->engine().setReverbParams(r);
                          }});
        float rDec = rev.decay * 100.0f;
        _knobs.push_back({NSMakeRect(848, 410, 74, 116), @"DECAY", 10.0f, 100.0f, 55.0f, rDec, false, true,
                          [NSString stringWithFormat:@"%.0f%%", rDec],
                          [self](float v) {
                              auto r = _core->engine().reverbParams();
                              r.decay = v / 100.0f;
                              _core->engine().setReverbParams(r);
                          }});
        float rDmp = rev.damping * 100.0f;
        _knobs.push_back({NSMakeRect(928, 410, 74, 116), @"DAMPING", 0.0f, 100.0f, 45.0f, rDmp, false, true,
                          [NSString stringWithFormat:@"%.0f%%", rDmp],
                          [self](float v) {
                              auto r = _core->engine().reverbParams();
                              r.damping = v / 100.0f;
                              _core->engine().setReverbParams(r);
                          }});
        _knobs.push_back({NSMakeRect(1008, 410, 74, 116), @"PRE-DLY", 0.0f, 120.0f, 18.0f, rev.preDelayMs, false, true,
                          [NSString stringWithFormat:@"%.0f ms", rev.preDelayMs],
                          [self](float v) {
                              auto r = _core->engine().reverbParams();
                              r.preDelayMs = v;
                              _core->engine().setReverbParams(r);
                          }});
    }
}

- (void)mouseDown:(NSEvent*)event {
    NSPoint pt = [self logicalPointFromEvent:event];

    for (size_t i = 0; i < _knobs.size(); ++i) {
        if (NSPointInRect(pt, _knobs[i].rect) && _knobs[i].enabled) {
            if (event.clickCount >= 2) {
                _knobs[i].onChange(_knobs[i].defaultVal);
                if (_core) _core->notifyStateChanged();
                [self rebuildLayout];
                [self setNeedsDisplay:YES];
                return;
            }
            _activeKnobIdx = (int)i;
            _dragStartY = pt.y;
            _dragStartVal = _knobs[i].currentVal;
            return;
        }
    }

    for (size_t i = 0; i < _buttons.size(); ++i) {
        if (NSPointInRect(pt, _buttons[i].rect)) {
            if (_buttons[i].onClick) _buttons[i].onClick();
            if (_core) _core->notifyStateChanged();
            [self rebuildLayout];
            [self setNeedsDisplay:YES];
            return;
        }
    }
}

- (void)mouseDragged:(NSEvent*)event {
    if (_activeKnobIdx < 0 || size_t(_activeKnobIdx) >= _knobs.size()) return;
    NSPoint pt = [self logicalPointFromEvent:event];
    CGFloat dy = _dragStartY - pt.y; // Flip: menor Y = mais alto
    auto& kw = _knobs[size_t(_activeKnobIdx)];
    float span = kw.maxVal - kw.minVal;
    if (span <= 0.0f) return;
    bool fine = (event.modifierFlags & NSEventModifierFlagShift) != 0;
    CGFloat basePx = kw.stepped ? std::clamp<CGFloat>(span * 6.5, 160.0, 780.0) : 240.0;
    CGFloat fullTurnPx = fine ? basePx * 4.0 : basePx;
    float next = std::clamp(_dragStartVal + float(dy / fullTurnPx) * span, kw.minVal, kw.maxVal);
    if (kw.stepped) next = std::round(next);
    kw.currentVal = next;
    if (kw.onChange) kw.onChange(next);
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent*)event {
    (void)event;
    if (_activeKnobIdx >= 0) {
        _activeKnobIdx = -1;
        if (_core) _core->notifyStateChanged();
        [self rebuildLayout];
        [self setNeedsDisplay:YES];
    }
}

- (void)drawKnob:(const DynamicKnob&)kw ctx:(CGContextRef)ctx {
    const CGFloat W = kw.rect.size.width;
    const CGFloat H = kw.rect.size.height;
    const bool compact = (H < 70.0);
    const CGFloat radius = compact ? 15.0 : 20.0;
    const CGFloat cx = kw.rect.origin.x + W * 0.5;
    const CGFloat cy = kw.rect.origin.y + (compact ? 27.0 : 41.0);

    NSDictionary* titleAttrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:(compact ? 8.0 : 8.8) weight:NSFontWeightHeavy],
        NSForegroundColorAttributeName : [NSColor colorWithWhite:1.0 alpha:(kw.enabled ? 0.92 : 0.40)]
    };
    NSSize tSz = [kw.title sizeWithAttributes:titleAttrs];
    [kw.title drawAtPoint:NSMakePoint(cx - tSz.width * 0.5, kw.rect.origin.y + 1.0) withAttributes:titleAttrs];

    float span = kw.maxVal - kw.minVal;
    float norm = (span > 0.0f) ? std::clamp((kw.currentVal - kw.minVal) / span, 0.0f, 1.0f) : 0.0f;
    float originNorm = (kw.minVal < 0.0f && kw.maxVal > 0.0f && span > 0.0f) ? (-kw.minVal / span) : 0.0f;

    // Trilha de fundo + arco colorido de valor
    CGFloat arcR = radius + 3.2;
    CGContextSetLineCap(ctx, kCGLineCapRound);
    CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:1.0 alpha:0.14].CGColor);
    CGContextSetLineWidth(ctx, 2.4);
    CGContextAddArc(ctx, cx, cy, arcR, (-225.0) * M_PI / 180.0, (45.0) * M_PI / 180.0, 0);
    CGContextStrokePath(ctx);

    if (kw.enabled && std::fabs(norm - originNorm) > 0.003f) {
        double a0 = (-225.0 + std::min(originNorm, norm) * 270.0) * M_PI / 180.0;
        double a1 = (-225.0 + std::max(originNorm, norm) * 270.0) * M_PI / 180.0;
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithRed:1.0 green:0.74 blue:0.18 alpha:0.95].CGColor);
        CGContextSetLineWidth(ctx, 2.6);
        CGContextAddArc(ctx, cx, cy, arcR, a0, a1, 0);
        CGContextStrokePath(ctx);
    }

    // Corpo do knob
    CGContextSetFillColorWithColor(ctx, [NSColor colorWithWhite:0.07 alpha:1.0].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - radius, cy - radius, radius * 2.0, radius * 2.0));
    CGContextSetStrokeColorWithColor(ctx, [NSColor blackColor].CGColor);
    CGContextSetLineWidth(ctx, 1.3);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - radius, cy - radius, radius * 2.0, radius * 2.0));

    CGFloat capR = radius * 0.76;
    CGContextSetFillColorWithColor(ctx, [NSColor colorWithWhite:0.17 alpha:1.0].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - capR, cy - capR, capR * 2.0, capR * 2.0));

    double deg = -135.0 + double(norm) * 270.0;
    double rad = (deg - 90.0) * M_PI / 180.0;
    CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:1.0 alpha:(kw.enabled ? 1.0 : 0.35)].CGColor);
    CGContextSetLineWidth(ctx, 2.3);
    CGContextMoveToPoint(ctx, cx + std::cos(rad) * (capR * 0.22), cy + std::sin(rad) * (capR * 0.22));
    CGContextAddLineToPoint(ctx, cx + std::cos(rad) * (capR * 0.88), cy + std::sin(rad) * (capR * 0.88));
    CGContextStrokePath(ctx);

    NSRect badgeRect = NSMakeRect(kw.rect.origin.x + 2.0, cy + radius + (compact ? 3.0 : 5.0), W - 4.0, 14.0);
    NSBezierPath* bp = [NSBezierPath bezierPathWithRoundedRect:badgeRect xRadius:3 yRadius:3];
    [[NSColor colorWithWhite:0.04 alpha:0.88] setFill];
    [bp fill];

    NSDictionary* valAttrs = @{
        NSFontAttributeName : [NSFont monospacedSystemFontOfSize:(compact ? 7.8 : 8.6) weight:NSFontWeightBold],
        NSForegroundColorAttributeName : [NSColor colorWithRed:1.0 green:0.76 blue:0.22 alpha:(kw.enabled ? 1.0 : 0.4)]
    };
    NSSize vSz = [kw.valueText sizeWithAttributes:valAttrs];
    [kw.valueText drawAtPoint:NSMakePoint(cx - vSz.width * 0.5, badgeRect.origin.y + 1.0) withAttributes:valAttrs];
}

- (void)drawButton:(const DynamicButton&)bw {
    NSBezierPath* bp = [NSBezierPath bezierPathWithRoundedRect:bw.rect xRadius:4.5 yRadius:4.5];
    [[NSColor colorWithWhite:(bw.ledOn ? 0.23 : 0.13) alpha:0.96] setFill];
    [bp fill];
    [[NSColor colorWithWhite:(bw.ledOn ? 0.42 : 0.05) alpha:0.95] setStroke];
    [bp setLineWidth:1.2];
    [bp stroke];

    if (bw.ledColorType > 0) {
        NSColor* ledC = [NSColor colorWithWhite:0.25 alpha:1.0];
        if (bw.ledOn) {
            if (bw.ledColorType == 1) ledC = [NSColor colorWithRed:0.20 green:0.92 blue:0.40 alpha:1.0];
            else if (bw.ledColorType == 2) ledC = [NSColor colorWithRed:1.00 green:0.22 blue:0.22 alpha:1.0];
            else if (bw.ledColorType == 3) ledC = [NSColor colorWithRed:1.00 green:0.76 blue:0.22 alpha:1.0];
            else ledC = [NSColor colorWithRed:0.25 green:0.85 blue:1.00 alpha:1.0];
        }
        [ledC setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(bw.rect.origin.x + 6, bw.rect.origin.y + (bw.rect.size.height - 6) * 0.5, 6, 6)] fill];
    }

    NSDictionary* attrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:9.0 weight:NSFontWeightHeavy],
        NSForegroundColorAttributeName : [NSColor colorWithWhite:(bw.ledOn ? 1.0 : 0.86) alpha:1.0]
    };
    NSSize sz = [bw.label sizeWithAttributes:attrs];
    CGFloat offsetLeft = (bw.ledColorType > 0) ? 7.0 : 0.0;
    [bw.label drawAtPoint:NSMakePoint(bw.rect.origin.x + offsetLeft + (bw.rect.size.width - offsetLeft - sz.width) * 0.5,
                                      bw.rect.origin.y + (bw.rect.size.height - sz.height) * 0.5)
           withAttributes:attrs];
}

- (double)evalVelocityCurveY:(double)x curve:(int)curve fixedVel:(bool)fixedVel {
    if (fixedVel) return 1.0;
    double cx = std::clamp(x, 0.0, 1.0);
    switch (curve) {
        case 1: return std::pow(cx, 0.58); // SOFT
        case 2: return cx;                 // LINEAR
        case 3: return std::pow(cx, 1.65); // HARD
        case 4: return std::pow(cx, 2.25); // EXP
        case 5: return std::pow(cx, 0.42); // LOG
        default: return std::pow(cx, 0.90); // NORMAL
    }
}

- (void)drawVelocityCurveGraph:(CGContextRef)ctx rect:(NSRect)r layer:(const npno::LayerParams&)lp {
    NSBezierPath* box = [NSBezierPath bezierPathWithRoundedRect:r xRadius:6 yRadius:6];
    [[NSColor colorWithWhite:0.04 alpha:0.96] setFill];
    [box fill];
    [[NSColor colorWithWhite:1.0 alpha:0.18] setStroke];
    [box stroke];

    // Grade 4x4
    CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:1.0 alpha:0.07].CGColor);
    CGContextSetLineWidth(ctx, 1.0);
    for (int i = 1; i <= 3; ++i) {
        CGFloat gx = r.origin.x + r.size.width * (CGFloat(i) / 4.0);
        CGFloat gy = r.origin.y + r.size.height * (CGFloat(i) / 4.0);
        CGContextMoveToPoint(ctx, gx, r.origin.y);
        CGContextAddLineToPoint(ctx, gx, r.origin.y + r.size.height);
        CGContextMoveToPoint(ctx, r.origin.x, gy);
        CGContextAddLineToPoint(ctx, r.origin.x + r.size.width, gy);
    }
    CGContextStrokePath(ctx);

    // Curva ativa
    CGFloat pad = 10.0;
    CGFloat gw = r.size.width - pad * 2.0;
    CGFloat gh = r.size.height - pad * 2.0;
    CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithRed:1.0 green:0.74 blue:0.18 alpha:0.96].CGColor);
    CGContextSetLineWidth(ctx, 2.4);
    for (int s = 0; s <= 40; ++s) {
        double t = double(s) / 40.0;
        double y = [self evalVelocityCurveY:t curve:lp.velocityCurve fixedVel:lp.fixedVelocity];
        CGFloat px = r.origin.x + pad + CGFloat(t) * gw;
        CGFloat py = r.origin.y + pad + CGFloat(1.0 - y) * gh;
        if (s == 0) CGContextMoveToPoint(ctx, px, py);
        else CGContextAddLineToPoint(ctx, px, py);
    }
    CGContextStrokePath(ctx);

    NSDictionary* lblAttr = @{
        NSFontAttributeName : [NSFont monospacedSystemFontOfSize:8.0 weight:NSFontWeightBold],
        NSForegroundColorAttributeName : [NSColor colorWithWhite:0.62 alpha:1.0]
    };
    [@"SAÍDA ↑" drawAtPoint:NSMakePoint(r.origin.x + 6, r.origin.y + 4) withAttributes:lblAttr];
    [@"FORÇA →" drawAtPoint:NSMakePoint(r.origin.x + r.size.width - 54, r.origin.y + r.size.height - 14) withAttributes:lblAttr];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSGraphicsContext* gc = [NSGraphicsContext currentContext];
    CGContextRef ctx = gc.CGContext;

    // Fundo escuro nas bordas caso o host force janela com aspect ratio diferente
    [[NSColor colorWithRed:0.06 green:0.06 blue:0.08 alpha:1.0] setFill];
    NSRectFill(self.bounds);

    CGFloat scale = 1.0, offX = 0.0, offY = 0.0;
    [self computeCanvasTransform:&scale offsetX:&offX offsetY:&offY];

    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, offX, offY);
    CGContextScaleCTM(ctx, scale, scale);

    const CGFloat W = kPluginBaseWidth;
    const CGFloat H = kPluginBaseHeight;
    const NSRect logicalBounds = NSMakeRect(0, 0, W, H);

    // 1. Chassi Vermelho Metálico Nord
    NSGradient* redChassis = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithRed:0.74 green:0.09 blue:0.13 alpha:1.0]
                                                           endingColor:[NSColor colorWithRed:0.50 green:0.05 blue:0.08 alpha:1.0]];
    [redChassis drawInRect:logicalBounds angle:90.0];

    // Laterais de madeira Nord
    [[NSColor colorWithRed:0.28 green:0.04 blue:0.05 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(0, 0, 12, H));
    NSRectFill(NSMakeRect(W - 12, 0, 12, H));

    // Cabeçalho Global Escuro (Seção 1)
    NSBezierPath* hdrBox = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(16, 4, W - 32, 56) xRadius:7 yRadius:7];
    [[NSColor colorWithRed:0.08 green:0.09 blue:0.11 alpha:0.94] setFill];
    [hdrBox fill];
    [[NSColor colorWithWhite:1.0 alpha:0.18] setStroke];
    [hdrBox stroke];

    NSDictionary* brandAttrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:15 weight:NSFontWeightBlack],
        NSForegroundColorAttributeName : [NSColor whiteColor]
    };
    [@"NORD ELECTRO PRO" drawAtPoint:NSMakePoint(24, 9) withAttributes:brandAttrs];

    NSDictionary* secSubAttrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:8.5 weight:NSFontWeightHeavy],
        NSForegroundColorAttributeName : [NSColor colorWithWhite:0.72 alpha:1.0]
    };
    [@"TRANSPOSE (ST)" drawAtPoint:NSMakePoint(202, 11) withAttributes:secSubAttrs];
    [@"ZOOM UI" drawAtPoint:NSMakePoint(722, 15) withAttributes:secSubAttrs];

    // Medidor de Nível Estéreo L/R (Seção 1)
    float pkL = _core ? _core->peakL() : 0.0f;
    float pkR = _core ? _core->peakR() : 0.0f;
    for (int ch = 0; ch < 2; ++ch) {
        CGFloat my = 16.0 + ch * 16.0;
        [[NSColor colorWithWhite:0.04 alpha:0.9] setFill];
        NSRectFill(NSMakeRect(490, my, 98, 11));
        int lit = (int)std::ceil(std::clamp(ch == 0 ? pkL : pkR, 0.0f, 1.0f) * 12.0f);
        for (int s = 0; s < 12; ++s) {
            NSColor* c = (s >= 10) ? [NSColor redColor] : (s >= 8 ? [NSColor orangeColor] : [NSColor greenColor]);
            if (s >= lit) c = [NSColor colorWithWhite:0.18 alpha:1.0];
            [c setFill];
            NSRectFill(NSMakeRect(493 + s * 8, my + 2, 6, 7));
        }
    }

    // Visor OLED Global (Voices/Max & Memory RAM)
    NSBezierPath* globOled = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(594, 10, 122, 44) xRadius:5 yRadius:5];
    [[NSColor colorWithWhite:0.04 alpha:1.0] setFill];
    [globOled fill];
    NSDictionary* oledMono = @{
        NSFontAttributeName : [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightBold],
        NSForegroundColorAttributeName : [NSColor colorWithRed:1.0 green:0.76 blue:0.22 alpha:1.0]
    };
    int actV = _core ? _core->activeVoices() : 0;
    int maxV = _core ? _core->engine().maxVoices() : 256;
    double curMB = _core ? double(_core->totalMemoryBytes()) / 1048576.0 : 0.0;
    double totMB = _core ? double(_core->totalUnpurgedBytes()) / 1048576.0 : 0.0;
    [[NSString stringWithFormat:@"VOZES: %d/%d", actV, maxV] drawAtPoint:NSMakePoint(602, 14) withAttributes:oledMono];
    [[NSString stringWithFormat:@"RAM: %.0f/%.0fM", curMB, totMB] drawAtPoint:NSMakePoint(602, 32) withAttributes:oledMono];

    // 4 Camadas A / B / C / D (Seção 2)
    const char* lNames[4] = {"A", "B", "C", "D"};
    for (int l = 0; l < 4; ++l) {
        CGFloat cx = 22.0 + l * 276.0;
        NSRect cardR = NSMakeRect(cx, 66, 268, 268);
        NSBezierPath* cardBox = [NSBezierPath bezierPathWithRoundedRect:cardR xRadius:8 yRadius:8];
        [[NSColor colorWithRed:0.08 green:0.09 blue:0.11 alpha:(_selectedLayer == l ? 0.94 : 0.86)] setFill];
        [cardBox fill];
        [[NSColor colorWithRed:1.0 green:(_selectedLayer == l ? 0.74 : 1.0) blue:(_selectedLayer == l ? 0.18 : 1.0)
                         alpha:(_selectedLayer == l ? 0.92 : 0.20)] setStroke];
        [cardBox setLineWidth:(_selectedLayer == l ? 2.0 : 1.1)];
        [cardBox stroke];

        // OLED da Camada
        NSRect oledR = NSMakeRect(cx + 8, 100, 252, 74);
        NSBezierPath* lOled = [NSBezierPath bezierPathWithRoundedRect:oledR xRadius:5 yRadius:5];
        [[NSColor colorWithWhite:0.03 alpha:1.0] setFill];
        [lOled fill];

        auto sum = _core ? _core->getLayerSummary(l) : epno::ElectroPianoCore::BankSummary{};
        auto lp = _core ? _core->engine().layerParams(l) : npno::LayerParams{};
        [[NSString stringWithFormat:@"SLOT %s • #%02d   %.0f MiB", lNames[l], std::max(1, sum.bankIndex), sum.memoryMB]
            drawAtPoint:NSMakePoint(cx + 14, 104)
         withAttributes:oledMono];

        NSString* title = _core && _core->isLoading(l)
                              ? [NSString stringWithFormat:@"Carregando... %.0f%%", _core->loadProgress(l) * 100.0f]
                              : [NSString stringWithUTF8String:sum.title.c_str()];
        NSDictionary* tAttr = @{
            NSFontAttributeName : [NSFont monospacedSystemFontOfSize:12.5 weight:NSFontWeightBlack],
            NSForegroundColorAttributeName : [NSColor colorWithWhite:1.0 alpha:(lp.enabled ? 1.0 : 0.45)]
        };
        [title drawInRect:NSMakeRect(cx + 14, 122, 240, 20) withAttributes:tAttr];

        NSString* zoneStr = [NSString stringWithFormat:@"%s  •  %@..%@",
                                                       sum.subtitle.c_str(),
                                                       formatMidiNote(lp.keyLow),
                                                       formatMidiNote(lp.keyHigh)];
        NSDictionary* subAttr = @{
            NSFontAttributeName : [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName : [NSColor colorWithWhite:0.72 alpha:1.0]
        };
        [zoneStr drawInRect:NSMakeRect(cx + 14, 148, 240, 18) withAttributes:subAttr];
    }

    // Moldura Escura da Aba Ativa (Seções Inferiores)
    NSRect inspR = NSMakeRect(22, 376, W - 44, 224);
    NSBezierPath* inspBox = [NSBezierPath bezierPathWithRoundedRect:inspR xRadius:8 yRadius:8];
    [[NSColor colorWithRed:0.08 green:0.09 blue:0.11 alpha:0.93] setFill];
    [inspBox fill];
    [[NSColor colorWithWhite:1.0 alpha:0.20] setStroke];
    [inspBox stroke];

    if (_selectedTab == 1 && _core) {
        auto slp = _core->engine().layerParams(_selectedLayer);
        [@"ZONAS DE TECLA & VELOCIDADE" drawAtPoint:NSMakePoint(36, 386) withAttributes:secSubAttrs];
        [@"PITCH BEND & PORTAMENTO" drawAtPoint:NSMakePoint(320, 386) withAttributes:secSubAttrs];
        [@"SENSIBILIDADE DAS TECLAS (CURVA DE RESPOSTA & TOQUE)" drawAtPoint:NSMakePoint(552, 386) withAttributes:secSubAttrs];
        [self drawVelocityCurveGraph:ctx rect:NSMakeRect(552, 410, 158, 150) layer:slp];
    }

    // Desenha Botões e Knobs
    for (const auto& bw : _buttons) [self drawButton:bw];
    for (const auto& kw : _knobs) [self drawKnob:kw ctx:ctx];

    // Rodapé
    NSBezierPath* footBox = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(22, 608, W - 44, 30) xRadius:5 yRadius:5];
    [[NSColor colorWithRed:0.06 green:0.07 blue:0.09 alpha:0.90] setFill];
    [footBox fill];
    [@"Nord Stage Workstation (.npno / .nsmp4) • Layout fixo com ZOOM (-/+) • Arraste os knobs (Shift = fino • Duplo-clique = padrão)"
        drawAtPoint:NSMakePoint(34, 616)
     withAttributes:oledMono];

    CGContextRestoreGState(ctx);
}

@end

NSView* CreateElectroPianoPluginView(epno::ElectroPianoCore* core, NSSize preferredSize) {
    (void)preferredSize;
    return [[ElectroPianoPluginMainView alloc] initWithFrame:NSMakeRect(0, 0, kPluginBaseWidth, kPluginBaseHeight) core:core];
}
