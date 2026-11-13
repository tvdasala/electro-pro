#include "NPNOBridge.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMIDI/CoreMIDI.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "npno/Engine.hpp"
#include "npno/Instrument.hpp"

namespace {

std::vector<std::string> scanNpnoFilesInDir(const std::string& fileOrDirPath) {
    std::vector<std::string> result;
    try {
        std::filesystem::path p(fileOrDirPath);
        std::filesystem::path dir = std::filesystem::is_directory(p) ? p : p.parent_path();
        if (dir.empty() || !std::filesystem::exists(dir)) return result;
        for (const auto& entry : std::filesystem::directory_iterator(dir)) {
            if (!entry.is_regular_file()) continue;
            std::string ext = entry.path().extension().string();
            for (char& c : ext) c = char(std::tolower(static_cast<unsigned char>(c)));
            if (ext == ".npno" || ext == ".nsmp4") {
                result.push_back(entry.path().string());
            }
        }
        std::sort(result.begin(), result.end());
    } catch (...) {
    }
    return result;
}

}  // namespace

struct NPNOHost {
    npno::Engine engine;
    std::array<std::shared_ptr<npno::Instrument>, npno::Engine::kNumLayers> layerInstruments;
    std::array<std::vector<std::string>, npno::Engine::kNumLayers> layerBankFiles;
    std::array<int, npno::Engine::kNumLayers> layerBankIndex{-1, -1, -1, -1};
    std::vector<std::shared_ptr<npno::Instrument>> retiredInstruments;
    std::mutex instMutex;

    // CoreAudio
    AudioComponentInstance audioUnit = nullptr;
    AudioDeviceID selectedAudioDeviceID = 0; // 0 = Saída Padrão do Sistema
    double sampleRate = 48000.0;
    bool audioRunning = false;
    std::vector<float> scratchL;
    std::vector<float> scratchR;

    struct AudioOutputEntry {
        AudioDeviceID deviceID = 0;
        std::string name;
    };
    std::mutex audioDevMutex;
    std::vector<AudioOutputEntry> audioOutputDevices;

    // CoreMIDI
    MIDIClientRef midiClient = 0;
    MIDIPortRef midiInPort = 0;
    std::mutex midiMutex;
    int midiSourceCount = 0;
    std::string midiSourcesSummary = "No MIDI controller detected";
    std::atomic<int> midiChannelFilter{0}; // 0 = Omni, 1..16 = Canal específico

    struct MidiInputEntry {
        MIDIEndpointRef endpoint = 0;
        std::string name;
        bool enabled = true;
    };
    std::vector<MidiInputEntry> midiInputs;
    NPNOMidiCCCallback midiCcCallback = nullptr;
    void* midiCcContext = nullptr;
    NPNOMidiEventCallback midiEventCallback = nullptr;
    void* midiEventContext = nullptr;

    static OSStatus renderCallback(void* inRefCon, AudioUnitRenderActionFlags* /*ioActionFlags*/,
                                   const AudioTimeStamp* /*inTimeStamp*/, UInt32 /*inBusNumber*/,
                                   UInt32 inNumberFrames, AudioBufferList* ioData) noexcept {
        auto* self = static_cast<NPNOHost*>(inRefCon);
        if (!ioData || ioData->mNumberBuffers == 0) return noErr;

        const int frames = int(std::min<UInt32>(inNumberFrames, UInt32(self->scratchL.size())));
        if (ioData->mNumberBuffers >= 2 && ioData->mBuffers[0].mData && ioData->mBuffers[1].mData) {
            auto* outL = static_cast<float*>(ioData->mBuffers[0].mData);
            auto* outR = static_cast<float*>(ioData->mBuffers[1].mData);
            self->engine.render(outL, outR, frames);
        } else if (ioData->mBuffers[0].mData) {
            float* L = self->scratchL.data();
            float* R = self->scratchR.data();
            self->engine.render(L, R, frames);
            const UInt32 ch = ioData->mBuffers[0].mNumberChannels;
            auto* dst = static_cast<float*>(ioData->mBuffers[0].mData);
            if (ch >= 2) {
                for (int i = 0; i < frames; ++i) {
                    dst[i * ch] = L[i];
                    dst[i * ch + 1] = R[i];
                }
            } else {
                for (int i = 0; i < frames; ++i) dst[i] = 0.5f * (L[i] + R[i]);
            }
        }
        return noErr;
    }

    static void midiReadProc(const MIDIPacketList* pktlist, void* readProcRefCon, void* /*srcConnRefCon*/) {
        auto* self = static_cast<NPNOHost*>(readProcRefCon);
        if (!self || !pktlist) return;

        const int chanFilter = self->midiChannelFilter.load(std::memory_order_relaxed);
        const MIDIPacket* packet = &pktlist->packet[0];
        for (UInt32 p = 0; p < pktlist->numPackets; ++p) {
            const Byte* d = packet->data;
            const UInt16 len = packet->length;
            uint8_t runningStatus = 0;
            UInt16 i = 0;
            while (i < len) {
                uint8_t b = d[i];
                if (b >= 0xF8) {
                    ++i;
                    continue;
                }
                if (b & 0x80) {
                    runningStatus = b;
                    ++i;
                    if (b >= 0xF0) {
                        while (i < len && !(d[i] & 0x80)) ++i;
                        runningStatus = 0;
                        continue;
                    }
                }
                if (runningStatus == 0) {
                    ++i;
                    continue;
                }
                const uint8_t type = runningStatus & 0xF0;
                const int msgChan = int(runningStatus & 0x0F) + 1;
                const bool passChan = (chanFilter == 0 || chanFilter == msgChan);

                if (type == 0xC0 || type == 0xD0) {
                    if (i + 1 > len) break;
                    const uint8_t d1 = d[i] & 0x7F;
                    i += 1;
                    if (!passChan) continue;
                    if (self->midiEventCallback) {
                        self->midiEventCallback(type, d1, 0, msgChan, self->midiEventContext);
                    }
                } else {
                    if (i + 2 > len) break;
                    const uint8_t d1 = d[i] & 0x7F;
                    const uint8_t d2 = d[i + 1] & 0x7F;
                    i += 2;
                    if (!passChan) continue;

                    if (self->midiEventCallback) {
                        self->midiEventCallback(type, d1, d2, msgChan, self->midiEventContext);
                    }

                    if (type == 0x90) {
                        if (d2 > 0)
                            self->engine.pushEvent(npno::Engine::EventType::NoteOn, d1, float(d2) / 127.0f, msgChan);
                        else
                            self->engine.pushEvent(npno::Engine::EventType::NoteOff, d1, 0.0f, msgChan);
                    } else if (type == 0x80) {
                        self->engine.pushEvent(npno::Engine::EventType::NoteOff, d1, 0.0f, msgChan);
                    } else if (type == 0xB0) {
                        if (self->midiCcCallback) {
                            self->midiCcCallback(d1, d2, msgChan, self->midiCcContext);
                        }
                        if (d1 == 120 || d1 == 123) {
                            self->engine.pushEvent(npno::Engine::EventType::Panic, 0, 0.0f, msgChan);
                        } else {
                            self->engine.pushEvent(npno::Engine::EventType::ControlChange, d1, float(d2), msgChan);
                        }
                    } else if (type == 0xE0) {
                        const int bend = (int(d2) << 7) | int(d1);
                        const float norm = float(bend - 8192) / 8192.0f;
                        self->engine.pushEvent(npno::Engine::EventType::PitchBend, 0, norm, msgChan);
                    }
                }
            }
            packet = MIDIPacketNext(packet);
        }
    }

    static void midiNotifyProc(const MIDINotification* message, void* refCon) {
        auto* self = static_cast<NPNOHost*>(refCon);
        if (!self || !message) return;
        if (message->messageID == kMIDIMsgSetupChanged || message->messageID == kMIDIMsgObjectAdded ||
            message->messageID == kMIDIMsgObjectRemoved) {
            self->connectAllMidiSources();
        }
    }

    void initMidi() {
        if (midiClient != 0) return;
        if (MIDIClientCreate(CFSTR("ElectroPianoMIDIClient"), &NPNOHost::midiNotifyProc, this, &midiClient) != noErr) {
            return;
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (MIDIInputPortCreate(midiClient, CFSTR("ElectroPianoMIDIIn"), &NPNOHost::midiReadProc, this, &midiInPort) !=
            noErr) {
            return;
        }
#pragma clang diagnostic pop
        connectAllMidiSources();
    }

    void connectAllMidiSources() {
        if (midiInPort == 0) return;
        std::lock_guard<std::mutex> lock(midiMutex);

        for (const auto& old : midiInputs) {
            if (old.endpoint && old.enabled) {
                MIDIPortDisconnectSource(midiInPort, old.endpoint);
            }
        }

        const ItemCount n = MIDIGetNumberOfSources();
        std::vector<MidiInputEntry> updated;
        std::string names;
        int connected = 0;

        for (ItemCount i = 0; i < n; ++i) {
            MIDIEndpointRef src = MIDIGetSource(i);
            if (!src) continue;

            std::string epName = "MIDI Device";
            CFStringRef cfName = nullptr;
            if (MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &cfName) != noErr || !cfName) {
                MIDIObjectGetStringProperty(src, kMIDIPropertyName, &cfName);
            }
            if (cfName) {
                char buf[128] = {};
                if (CFStringGetCString(cfName, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                    epName = buf;
                }
                CFRelease(cfName);
            }

            bool wasEnabled = true;
            for (const auto& prev : midiInputs) {
                if (prev.name == epName) {
                    wasEnabled = prev.enabled;
                    break;
                }
            }

            if (wasEnabled) {
                MIDIPortConnectSource(midiInPort, src, nullptr);
                ++connected;
                if (!names.empty()) names += ", ";
                names += epName;
            }
            updated.push_back({src, epName, wasEnabled});
        }

        midiInputs = std::move(updated);
        midiSourceCount = connected;
        midiSourcesSummary = connected > 0 ? names : "No MIDI controller detected";
    }

    void updateMidiSummaryLocked() {
        std::string names;
        int connected = 0;
        for (const auto& item : midiInputs) {
            if (item.enabled) {
                ++connected;
                if (!names.empty()) names += ", ";
                names += item.name;
            }
        }
        midiSourceCount = connected;
        midiSourcesSummary = connected > 0 ? names : "No MIDI controller detected";
    }

    void enumerateAudioOutputDevices() {
        std::lock_guard<std::mutex> lock(audioDevMutex);
        audioOutputDevices.clear();
        audioOutputDevices.push_back({0, "System Default"});

        AudioObjectPropertyAddress addr = {
            kAudioHardwarePropertyDevices,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        UInt32 dataSize = 0;
        if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, nullptr, &dataSize) != noErr ||
            dataSize == 0) {
            return;
        }

        const size_t count = dataSize / sizeof(AudioDeviceID);
        std::vector<AudioDeviceID> devIDs(count, 0);
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &dataSize, devIDs.data()) != noErr) {
            return;
        }

        for (AudioDeviceID devID : devIDs) {
            AudioObjectPropertyAddress streamAddr = {
                kAudioDevicePropertyStreamConfiguration,
                kAudioObjectPropertyScopeOutput,
                kAudioObjectPropertyElementMain
            };
            UInt32 cfgSize = 0;
            if (AudioObjectGetPropertyDataSize(devID, &streamAddr, 0, nullptr, &cfgSize) != noErr || cfgSize == 0) {
                continue;
            }
            std::vector<uint8_t> buf(cfgSize, 0);
            auto* abl = reinterpret_cast<AudioBufferList*>(buf.data());
            if (AudioObjectGetPropertyData(devID, &streamAddr, 0, nullptr, &cfgSize, abl) != noErr) {
                continue;
            }
            UInt32 outChannels = 0;
            for (UInt32 b = 0; b < abl->mNumberBuffers; ++b) {
                outChannels += abl->mBuffers[b].mNumberChannels;
            }
            if (outChannels == 0) continue;

            AudioObjectPropertyAddress nameAddr = {
                kAudioObjectPropertyName,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            CFStringRef cfName = nullptr;
            UInt32 nameSize = sizeof(cfName);
            std::string devName = "Audio Output";
            if (AudioObjectGetPropertyData(devID, &nameAddr, 0, nullptr, &nameSize, &cfName) == noErr && cfName) {
                char cbuf[192] = {};
                if (CFStringGetCString(cfName, cbuf, sizeof(cbuf), kCFStringEncodingUTF8)) {
                    devName = cbuf;
                }
                CFRelease(cfName);
            }
            audioOutputDevices.push_back({devID, devName});
        }
    }
};

extern "C" {

NPNOHost* npno_host_create(void) {
    auto* host = new NPNOHost();
    host->scratchL.resize(8192, 0.0f);
    host->scratchR.resize(8192, 0.0f);
    host->enumerateAudioOutputDevices();
    host->initMidi();
    return host;
}

void npno_host_destroy(NPNOHost* host) {
    if (!host) return;
    npno_host_stop_audio(host);
    if (host->midiInPort) MIDIPortDispose(host->midiInPort);
    if (host->midiClient) MIDIClientDispose(host->midiClient);
    delete host;
}

bool npno_host_start_audio(NPNOHost* host) {
    if (!host) return false;
    if (host->audioRunning) return true;

    AudioComponentDescription desc{};
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType =
        (host->selectedAudioDeviceID == 0) ? kAudioUnitSubType_DefaultOutput : kAudioUnitSubType_HALOutput;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
    if (!comp) return false;
    if (AudioComponentInstanceNew(comp, &host->audioUnit) != noErr || !host->audioUnit) return false;

    if (host->selectedAudioDeviceID != 0) {
        AudioDeviceID devID = host->selectedAudioDeviceID;
        if (AudioUnitSetProperty(host->audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &devID, sizeof(devID)) != noErr) {
            AudioComponentInstanceDispose(host->audioUnit);
            host->audioUnit = nullptr;
            host->selectedAudioDeviceID = 0;
            return npno_host_start_audio(host);
        }
    }

    Float64 hwRate = 48000.0;
    UInt32 propSize = sizeof(hwRate);
    if (AudioUnitGetProperty(host->audioUnit, kAudioUnitProperty_SampleRate, kAudioUnitScope_Output, 0, &hwRate,
                             &propSize) != noErr ||
        hwRate < 8000.0) {
        hwRate = 48000.0;
    }
    host->sampleRate = hwRate;
    host->engine.prepare(hwRate);

    AudioStreamBasicDescription asbd{};
    asbd.mSampleRate = hwRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags =
        AudioFormatFlags(kAudioFormatFlagsNativeFloatPacked) | AudioFormatFlags(kAudioFormatFlagIsNonInterleaved);
    asbd.mBytesPerPacket = sizeof(float);
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = sizeof(float);
    asbd.mChannelsPerFrame = 2;
    asbd.mBitsPerChannel = 32;

    if (AudioUnitSetProperty(host->audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd,
                             sizeof(asbd)) != noErr) {
        AudioComponentInstanceDispose(host->audioUnit);
        host->audioUnit = nullptr;
        return false;
    }

    AURenderCallbackStruct cb{};
    cb.inputProc = &NPNOHost::renderCallback;
    cb.inputProcRefCon = host;
    if (AudioUnitSetProperty(host->audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb,
                             sizeof(cb)) != noErr) {
        AudioComponentInstanceDispose(host->audioUnit);
        host->audioUnit = nullptr;
        return false;
    }

    if (AudioUnitInitialize(host->audioUnit) != noErr) {
        AudioComponentInstanceDispose(host->audioUnit);
        host->audioUnit = nullptr;
        return false;
    }
    if (AudioOutputUnitStart(host->audioUnit) != noErr) {
        AudioUnitUninitialize(host->audioUnit);
        AudioComponentInstanceDispose(host->audioUnit);
        host->audioUnit = nullptr;
        return false;
    }

    host->audioRunning = true;
    return true;
}

void npno_host_stop_audio(NPNOHost* host) {
    if (!host || !host->audioUnit) return;
    if (host->audioRunning) {
        AudioOutputUnitStop(host->audioUnit);
        host->audioRunning = false;
    }
    AudioUnitUninitialize(host->audioUnit);
    AudioComponentInstanceDispose(host->audioUnit);
    host->audioUnit = nullptr;
}

bool npno_host_load_layer_instrument(NPNOHost* host, int32_t layer, const char* path,
                                     void (*progress_cb)(float progress, void* ctx), void* ctx,
                                     char* err_buf, int32_t err_buf_len) {
    if (!host || !path || layer < 0 || layer >= npno::Engine::kNumLayers) return false;
    try {
        // Verifica se outra camada já possui exatamente o mesmo arquivo carregado para economizar RAM,
        // ou carrega um novo Instrument.
        auto uniqueInst = npno::Instrument::load(
            path,
            [&](float p) {
                if (progress_cb) progress_cb(p, ctx);
            },
            nullptr);
        std::shared_ptr<npno::Instrument> inst(std::move(uniqueInst));

        auto bankFiles = scanNpnoFilesInDir(path);
        int idx = -1;
        for (size_t i = 0; i < bankFiles.size(); ++i) {
            if (bankFiles[i] == path) {
                idx = int(i);
                break;
            }
        }

        std::lock_guard<std::mutex> lock(host->instMutex);
        host->engine.setLayerInstrument(layer, inst.get());
        auto lp = host->engine.layerParams(layer);
        lp.enabled = true;
        host->engine.setLayerParams(layer, lp);
        if (host->layerInstruments[layer]) {
            host->retiredInstruments.push_back(std::move(host->layerInstruments[layer]));
        }
        host->layerInstruments[layer] = std::move(inst);
        host->layerBankFiles[layer] = std::move(bankFiles);
        host->layerBankIndex[layer] = idx;
        if (host->retiredInstruments.size() > 4) {
            host->retiredInstruments.erase(host->retiredInstruments.begin());
        }
        return true;
    } catch (const std::exception& e) {
        if (err_buf && err_buf_len > 0) {
            std::snprintf(err_buf, size_t(err_buf_len), "%s", e.what());
        }
        return false;
    }
}

bool npno_host_load_instrument(NPNOHost* host, const char* path,
                               void (*progress_cb)(float progress, void* ctx), void* ctx,
                               char* err_buf, int32_t err_buf_len) {
    return npno_host_load_layer_instrument(host, 0, path, progress_cb, ctx, err_buf, err_buf_len);
}

bool npno_host_step_layer_instrument(NPNOHost* host, int32_t layer, int32_t delta,
                                     void (*progress_cb)(float progress, void* ctx), void* ctx,
                                     char* err_buf, int32_t err_buf_len) {
    if (!host || layer < 0 || layer >= npno::Engine::kNumLayers) return false;
    std::string targetPath;
    {
        std::lock_guard<std::mutex> lock(host->instMutex);
        auto& files = host->layerBankFiles[layer];
        if (files.empty()) {
            // Tenta herdar lista de arquivos da Camada A
            files = host->layerBankFiles[0];
        }
        if (files.empty()) return false;
        int idx = host->layerBankIndex[layer];
        if (idx < 0) idx = 0;
        const int n = int(files.size());
        idx = ((idx + delta) % n + n) % n;
        targetPath = files[size_t(idx)];
    }
    return npno_host_load_layer_instrument(host, layer, targetPath.c_str(), progress_cb, ctx, err_buf, err_buf_len);
}

void npno_host_get_layer_instrument_info(NPNOHost* host, int32_t layer, NPNOInstrumentInfo* out_info) {
    if (!out_info) return;
    std::memset(out_info, 0, sizeof(*out_info));
    if (!host || layer < 0 || layer >= npno::Engine::kNumLayers) return;

    std::lock_guard<std::mutex> lock(host->instMutex);
    const npno::Instrument* inst = host->layerInstruments[layer].get();
    out_info->bankIndex = host->layerBankIndex[layer] >= 0 ? (host->layerBankIndex[layer] + 1) : 1;
    out_info->bankCount = int32_t(host->layerBankFiles[layer].size());
    if (!inst) return;

    std::snprintf(out_info->name, sizeof(out_info->name), "%s", inst->name.c_str());
    std::snprintf(out_info->model, sizeof(out_info->model), "%s", inst->model.c_str());
    std::snprintf(out_info->path, sizeof(out_info->path), "%s", inst->path.c_str());
    std::string sum = inst->summary();
    std::snprintf(out_info->summary, sizeof(out_info->summary), "%s", sum.c_str());
    out_info->fileVersion = inst->fileVersion;
    out_info->channels = inst->channels;
    out_info->recordCount = inst->recordCount;

    uint32_t normalCount = 0, relCount = 0;
    for (const auto& s : inst->samples) {
        if (s.release) ++relCount;
        else ++normalCount;
    }
    out_info->normalSampleCount = normalCount;
    out_info->releaseSampleCount = relCount;
    out_info->residentSampleCount = uint32_t(inst->residentSampleCount());
    out_info->decodedBytes = inst->decodedBytes;
    out_info->totalDecodedBytes = inst->totalDecodedBytes;
    out_info->lowestNote = inst->lowestNote;
    out_info->highestNote = inst->highestNote;
    out_info->damperBoundary = inst->damperBoundary;
    out_info->extendedEdgeKeys = inst->extendedEdgeKeys;
    out_info->loaded = true;
}

void npno_host_get_instrument_info(NPNOHost* host, NPNOInstrumentInfo* out_info) {
    npno_host_get_layer_instrument_info(host, 0, out_info);
}

void npno_host_get_layer_params(NPNOHost* host, int32_t layer, NPNOLayerParams* out_params) {
    if (!out_params) return;
    std::memset(out_params, 0, sizeof(*out_params));
    if (!host || layer < 0 || layer >= npno::Engine::kNumLayers) return;

    const npno::LayerParams lp = host->engine.layerParams(layer);
    out_params->enabled = lp.enabled;
    out_params->volume = lp.volume;
    out_params->filter = lp.filter;
    out_params->fxaAmount = lp.fxaAmount;
    out_params->fxaRelease = lp.fxaRelease;

    out_params->ccVolume = lp.ccVolume;
    out_params->ccFilter = lp.ccFilter;
    out_params->ccFxaAmount = lp.ccFxaAmount;
    out_params->ccFxaRelease = lp.ccFxaRelease;
    out_params->keyLow = lp.keyLow;
    out_params->keyHigh = lp.keyHigh;
    out_params->velLow = lp.velLow;
    out_params->velHigh = lp.velHigh;
    out_params->midiChannel = lp.midiChannel;
    out_params->velocityCurve = lp.velocityCurve;
    out_params->pitchBendDown = lp.pitchBendDown;
    out_params->pitchBendUp = lp.pitchBendUp;
    out_params->portamentoOn = lp.portamentoOn;
    out_params->portamentoTimeMs = lp.portamentoTimeMs;
    out_params->fixedVelocity = lp.fixedVelocity;
    out_params->fixedVelocityValue = lp.fixedVelocityValue;
    out_params->legatoMono = lp.legatoMono;

    out_params->timbreMode = lp.timbreMode;
    out_params->sustainPedalOn = lp.sustainPedalOn;
    out_params->undampedOn = lp.undampedOn;
    out_params->compOn = lp.compOn;
    out_params->compAmount = lp.compAmount;
    out_params->compFast = lp.compFast;
    out_params->octaveShift = lp.octaveShift;
    out_params->originalEnvelope = lp.originalEnvelope;
    out_params->attackMs = lp.attackMs;
    out_params->releaseMs = lp.releaseMs;
}

void npno_host_set_layer_params(NPNOHost* host, int32_t layer, const NPNOLayerParams* params) {
    if (!host || !params || layer < 0 || layer >= npno::Engine::kNumLayers) return;
    npno::LayerParams lp{};
    lp.enabled = params->enabled;
    lp.volume = params->volume;
    lp.filter = params->filter;
    lp.fxaAmount = params->fxaAmount;
    lp.fxaRelease = params->fxaRelease;

    lp.ccVolume = params->ccVolume;
    lp.ccFilter = params->ccFilter;
    lp.ccFxaAmount = params->ccFxaAmount;
    lp.ccFxaRelease = params->ccFxaRelease;
    lp.keyLow = params->keyLow;
    lp.keyHigh = params->keyHigh;
    lp.velLow = params->velLow;
    lp.velHigh = params->velHigh;
    lp.midiChannel = params->midiChannel;
    lp.velocityCurve = params->velocityCurve;
    lp.pitchBendDown = params->pitchBendDown;
    lp.pitchBendUp = params->pitchBendUp;
    lp.portamentoOn = params->portamentoOn;
    lp.portamentoTimeMs = params->portamentoTimeMs;
    lp.fixedVelocity = params->fixedVelocity;
    lp.fixedVelocityValue = params->fixedVelocityValue;
    lp.legatoMono = params->legatoMono;

    lp.timbreMode = params->timbreMode;
    lp.sustainPedalOn = params->sustainPedalOn;
    lp.undampedOn = params->undampedOn;
    lp.compOn = params->compOn;
    lp.compAmount = params->compAmount;
    lp.compFast = params->compFast;
    lp.octaveShift = params->octaveShift;
    lp.originalEnvelope = params->originalEnvelope;
    lp.attackMs = params->attackMs;
    lp.releaseMs = params->releaseMs;
    host->engine.setLayerParams(layer, lp);
}

void npno_host_start_midi_learn(NPNOHost* host, int32_t layer, int32_t slot) {
    if (host) host->engine.startMidiLearn(layer, slot);
}

void npno_host_cancel_midi_learn(NPNOHost* host) {
    if (host) host->engine.cancelMidiLearn();
}

uint64_t npno_host_purge_unused(NPNOHost* host) {
    if (!host) return 0;
    host->engine.panic();
    std::lock_guard<std::mutex> lock(host->instMutex);
    uint64_t freed = 0;
    for (int l = 0; l < npno::Engine::kNumLayers; ++l) {
        if (host->layerInstruments[l]) {
            freed += host->layerInstruments[l]->purgeUnusedSamples();
        }
    }
    return freed;
}

bool npno_host_reload_purged(NPNOHost* host) {
    if (!host) return false;
    host->engine.panic();
    std::lock_guard<std::mutex> lock(host->instMutex);
    bool ok = true;
    for (int l = 0; l < npno::Engine::kNumLayers; ++l) {
        if (host->layerInstruments[l]) {
            if (!host->layerInstruments[l]->reloadPurgedSamples()) ok = false;
        }
    }
    return ok;
}

void npno_host_get_telemetry(NPNOHost* host, NPNOTelemetry* out_telemetry) {
    if (!out_telemetry) return;
    std::memset(out_telemetry, 0, sizeof(*out_telemetry));
    if (!host) return;

    out_telemetry->activeVoices = host->engine.activeVoices();
    out_telemetry->maxVoices = host->engine.maxVoices();
    for (int l = 0; l < 4; ++l) {
        out_telemetry->layerActiveVoices[l] = host->engine.layerActiveVoices(l);
    }
    out_telemetry->midiLearnLayer = host->engine.midiLearnLayer();
    out_telemetry->midiLearnSlot = host->engine.midiLearnSlot();
    out_telemetry->sustainDown = host->engine.isSustainDown();
    out_telemetry->peakL = host->engine.peakLeft();
    out_telemetry->peakR = host->engine.peakRight();
    host->engine.decayPeaks(0.84f);
    out_telemetry->sampleRate = host->sampleRate;

    {
        std::lock_guard<std::mutex> lock(host->instMutex);
        uint64_t memBytes = 0, unpurgedBytes = 0;
        for (int l = 0; l < npno::Engine::kNumLayers; ++l) {
            if (host->layerInstruments[l]) {
                memBytes += host->layerInstruments[l]->decodedBytes;
                unpurgedBytes += host->layerInstruments[l]->totalDecodedBytes;
            }
        }
        out_telemetry->totalMemoryBytes = memBytes;
        out_telemetry->totalUnpurgedBytes = unpurgedBytes;
    }

    {
        std::lock_guard<std::mutex> lock(host->midiMutex);
        out_telemetry->midiSourceCount = host->midiSourceCount;
        std::snprintf(out_telemetry->midiSources, sizeof(out_telemetry->midiSources), "%s",
                      host->midiSourcesSummary.c_str());
    }
    for (int n = 0; n < 128; ++n) {
        out_telemetry->keyVelocities[n] = host->engine.keyVelocity(n);
    }
}

void npno_host_note_on(NPNOHost* host, int32_t note, float velocity) {
    if (!host) return;
    host->engine.pushEvent(npno::Engine::EventType::NoteOn, note, velocity, 0);
}

void npno_host_note_off(NPNOHost* host, int32_t note) {
    if (!host) return;
    host->engine.pushEvent(npno::Engine::EventType::NoteOff, note, 0.0f, 0);
}

void npno_host_sustain(NPNOHost* host, bool down) {
    if (!host) return;
    host->engine.pushEvent(npno::Engine::EventType::Sustain, 0, down ? 1.0f : 0.0f, 0);
}

void npno_host_panic(NPNOHost* host) {
    if (!host) return;
    host->engine.pushEvent(npno::Engine::EventType::Panic, 0, 0.0f, 0);
}

void npno_host_set_master_gain(NPNOHost* host, float gain) {
    if (host) host->engine.setMasterGain(gain);
}

float npno_host_get_master_gain(NPNOHost* host) {
    return host ? host->engine.masterGain() : 1.0f;
}

void npno_host_set_master_pan(NPNOHost* host, float pan) {
    if (host) host->engine.setMasterPan(pan);
}

float npno_host_get_master_pan(NPNOHost* host) {
    return host ? host->engine.masterPan() : 0.0f;
}

void npno_host_set_fine_tune_cents(NPNOHost* host, float cents) {
    if (host) host->engine.setFineTuneCents(cents);
}

float npno_host_get_fine_tune_cents(NPNOHost* host) {
    return host ? host->engine.fineTuneCents() : 0.0f;
}

void npno_host_set_base_tuning_hz(NPNOHost* host, float hz) {
    if (host) host->engine.setBaseTuningHz(hz);
}

float npno_host_get_base_tuning_hz(NPNOHost* host) {
    return host ? host->engine.baseTuningHz() : 440.0f;
}

void npno_host_set_max_voices(NPNOHost* host, int32_t max_voices) {
    if (host) host->engine.setMaxVoices(max_voices);
}

int32_t npno_host_get_max_voices(NPNOHost* host) {
    return host ? host->engine.maxVoices() : 256;
}

void npno_host_set_transpose(NPNOHost* host, int32_t semitones) {
    if (host) host->engine.setTransposeSemitones(semitones);
}

int32_t npno_host_get_transpose(NPNOHost* host) {
    return host ? host->engine.transposeSemitones() : 0;
}

void npno_host_set_velocity_curve(NPNOHost* host, int32_t curve) {
    if (host) host->engine.setVelocityCurve(curve);
}

int32_t npno_host_get_velocity_curve(NPNOHost* host) {
    return host ? host->engine.velocityCurve() : 0;
}

void npno_host_set_release_samples_enabled(NPNOHost* host, bool enabled) {
    if (host) host->engine.setReleaseSamplesEnabled(enabled);
}

bool npno_host_get_release_samples_enabled(NPNOHost* host) {
    return host ? host->engine.releaseSamplesEnabled() : true;
}

void npno_host_set_release_sample_gain(NPNOHost* host, float gain) {
    if (host) host->engine.setReleaseSampleGain(gain);
}

float npno_host_get_release_sample_gain(NPNOHost* host) {
    return host ? host->engine.releaseSampleGain() : 1.0f;
}

void npno_host_set_release_scale(NPNOHost* host, float scale) {
    if (host) host->engine.setReleaseScale(scale);
}

float npno_host_get_release_scale(NPNOHost* host) {
    return host ? host->engine.releaseScale() : 1.0f;
}

void npno_host_set_eq_bass_db(NPNOHost* host, float db) {
    if (host) host->engine.setEqBassDb(db);
}

float npno_host_get_eq_bass_db(NPNOHost* host) {
    return host ? host->engine.eqBassDb() : 0.0f;
}

void npno_host_set_eq_mid_db(NPNOHost* host, float db) {
    if (host) host->engine.setEqMidDb(db);
}

float npno_host_get_eq_mid_db(NPNOHost* host) {
    return host ? host->engine.eqMidDb() : 0.0f;
}

void npno_host_set_eq_mid_freq_hz(NPNOHost* host, float hz) {
    if (host) host->engine.setEqMidFreqHz(hz);
}

float npno_host_get_eq_mid_freq_hz(NPNOHost* host) {
    return host ? host->engine.eqMidFreqHz() : 1000.0f;
}

void npno_host_set_eq_treble_db(NPNOHost* host, float db) {
    if (host) host->engine.setEqTrebleDb(db);
}

float npno_host_get_eq_treble_db(NPNOHost* host) {
    return host ? host->engine.eqTrebleDb() : 0.0f;
}

void npno_host_set_drive_enabled(NPNOHost* host, bool enabled) {
    if (host) host->engine.setDriveEnabled(enabled);
}

bool npno_host_get_drive_enabled(NPNOHost* host) {
    return host ? host->engine.driveEnabled() : false;
}

void npno_host_set_drive_amount(NPNOHost* host, float amount) {
    if (host) host->engine.setDriveAmount(amount);
}

float npno_host_get_drive_amount(NPNOHost* host) {
    return host ? host->engine.driveAmount() : 0.25f;
}

void npno_host_get_modulator_params(NPNOHost* host, int32_t index, NPNOModulatorParams* out_params) {
    if (!out_params) return;
    std::memset(out_params, 0, sizeof(*out_params));
    if (!host || index < 0 || index > 1) return;
    const auto m = host->engine.modulatorParams(index);
    out_params->enabled = m.enabled;
    out_params->target = m.target;
    out_params->wave = m.wave;
    out_params->rateHz = m.rateHz;
    out_params->depth = m.depth;
}

void npno_host_set_modulator_params(NPNOHost* host, int32_t index, const NPNOModulatorParams* params) {
    if (!host || !params || index < 0 || index > 1) return;
    npno::ModulatorParams m{};
    m.enabled = params->enabled;
    m.target = params->target;
    m.wave = params->wave;
    m.rateHz = params->rateHz;
    m.depth = params->depth;
    host->engine.setModulatorParams(index, m);
}

void npno_host_get_delay_params(NPNOHost* host, NPNODelayParams* out_params) {
    if (!out_params) return;
    std::memset(out_params, 0, sizeof(*out_params));
    if (!host) return;
    const auto d = host->engine.delayParams();
    out_params->enabled = d.enabled;
    out_params->amount = d.amount;
    out_params->feedback = d.feedback;
    out_params->timeMs = d.timeMs;
    out_params->syncToHost = d.syncToHost;
    out_params->hostBpm = d.hostBpm;
    out_params->syncDivision = d.syncDivision;
    out_params->pingPong = d.pingPong;
}

void npno_host_set_delay_params(NPNOHost* host, const NPNODelayParams* params) {
    if (!host || !params) return;
    npno::DelayParams d{};
    d.enabled = params->enabled;
    d.amount = params->amount;
    d.feedback = params->feedback;
    d.timeMs = params->timeMs;
    d.syncToHost = params->syncToHost;
    d.hostBpm = params->hostBpm;
    d.syncDivision = params->syncDivision;
    d.pingPong = params->pingPong;
    host->engine.setDelayParams(d);
}

void npno_host_tap_delay(NPNOHost* host) {
    if (!host) return;
    const double nowSec = std::chrono::duration<double>(
                              std::chrono::steady_clock::now().time_since_epoch())
                              .count();
    host->engine.tapDelay(nowSec);
}

void npno_host_get_reverb_params(NPNOHost* host, NPNOReverbParams* out_params) {
    if (!out_params) return;
    std::memset(out_params, 0, sizeof(*out_params));
    if (!host) return;
    const auto r = host->engine.reverbParams();
    out_params->enabled = r.enabled;
    out_params->amount = r.amount;
    out_params->size = r.size;
    out_params->decay = r.decay;
    out_params->damping = r.damping;
    out_params->preDelayMs = r.preDelayMs;
}

void npno_host_set_reverb_params(NPNOHost* host, const NPNOReverbParams* params) {
    if (!host || !params) return;
    npno::ReverbParams r{};
    r.enabled = params->enabled;
    r.amount = params->amount;
    r.size = params->size;
    r.decay = params->decay;
    r.damping = params->damping;
    r.preDelayMs = params->preDelayMs;
    host->engine.setReverbParams(r);
}

void npno_host_refresh_audio_devices(NPNOHost* host) {
    if (host) host->enumerateAudioOutputDevices();
}

int32_t npno_host_get_audio_output_device_count(NPNOHost* host) {
    if (!host) return 0;
    std::lock_guard<std::mutex> lock(host->audioDevMutex);
    return int32_t(host->audioOutputDevices.size());
}

bool npno_host_get_audio_output_device_info(NPNOHost* host, int32_t index,
                                            uint32_t* out_device_id,
                                            char* out_name, int32_t name_len) {
    if (!host || index < 0) return false;
    std::lock_guard<std::mutex> lock(host->audioDevMutex);
    if (size_t(index) >= host->audioOutputDevices.size()) return false;
    const auto& entry = host->audioOutputDevices[size_t(index)];
    if (out_device_id) *out_device_id = entry.deviceID;
    if (out_name && name_len > 0) {
        std::snprintf(out_name, size_t(name_len), "%s", entry.name.c_str());
    }
    return true;
}

bool npno_host_set_audio_output_device(NPNOHost* host, uint32_t device_id) {
    if (!host) return false;
    if (host->selectedAudioDeviceID == device_id && host->audioRunning) return true;
    npno_host_stop_audio(host);
    host->selectedAudioDeviceID = device_id;
    return npno_host_start_audio(host);
}

uint32_t npno_host_get_current_audio_output_device(NPNOHost* host) {
    return host ? host->selectedAudioDeviceID : 0;
}

void npno_host_rescan_midi(NPNOHost* host) {
    if (host) host->connectAllMidiSources();
}

int32_t npno_host_get_midi_input_count(NPNOHost* host) {
    if (!host) return 0;
    std::lock_guard<std::mutex> lock(host->midiMutex);
    return int32_t(host->midiInputs.size());
}

bool npno_host_get_midi_input_info(NPNOHost* host, int32_t index,
                                   char* out_name, int32_t name_len,
                                   bool* out_enabled) {
    if (!host || index < 0) return false;
    std::lock_guard<std::mutex> lock(host->midiMutex);
    if (size_t(index) >= host->midiInputs.size()) return false;
    const auto& item = host->midiInputs[size_t(index)];
    if (out_name && name_len > 0) {
        std::snprintf(out_name, size_t(name_len), "%s", item.name.c_str());
    }
    if (out_enabled) *out_enabled = item.enabled;
    return true;
}

void npno_host_set_midi_input_enabled(NPNOHost* host, int32_t index, bool enabled) {
    if (!host || index < 0 || host->midiInPort == 0) return;
    std::lock_guard<std::mutex> lock(host->midiMutex);
    if (size_t(index) >= host->midiInputs.size()) return;
    auto& item = host->midiInputs[size_t(index)];
    if (item.enabled == enabled) return;
    item.enabled = enabled;
    if (item.endpoint) {
        if (enabled) {
            MIDIPortConnectSource(host->midiInPort, item.endpoint, nullptr);
        } else {
            MIDIPortDisconnectSource(host->midiInPort, item.endpoint);
        }
    }
    host->updateMidiSummaryLocked();
}

void npno_host_set_midi_channel(NPNOHost* host, int32_t channel) {
    if (!host) return;
    const int ch = std::clamp<int>(channel, 0, 16);
    host->midiChannelFilter.store(ch, std::memory_order_relaxed);
    host->engine.setGlobalMidiChannel(ch);
}

int32_t npno_host_get_midi_channel(NPNOHost* host) {
    return host ? host->midiChannelFilter.load(std::memory_order_relaxed) : 0;
}

void npno_host_set_midi_cc_callback(NPNOHost* host, NPNOMidiCCCallback cb, void* ctx) {
    if (!host) return;
    host->midiCcCallback = cb;
    host->midiCcContext = ctx;
}

void npno_host_set_midi_event_callback(NPNOHost* host, NPNOMidiEventCallback cb, void* ctx) {
    if (!host) return;
    host->midiEventCallback = cb;
    host->midiEventContext = ctx;
}

void npno_host_send_midi_cc(NPNOHost* host, int32_t cc, int32_t value, int32_t channel) {
    if (!host) return;
    const int clampedCC = std::clamp<int>(cc, 0, 127);
    const int clampedVal = std::clamp<int>(value, 0, 127);
    const int clampedCh = std::clamp<int>(channel, 0, 16);
    if (host->midiEventCallback) {
        host->midiEventCallback(0xB0, clampedCC, clampedVal, clampedCh > 0 ? clampedCh : 1, host->midiEventContext);
    }
    if (host->midiCcCallback) {
        host->midiCcCallback(clampedCC, clampedVal, clampedCh > 0 ? clampedCh : 1, host->midiCcContext);
    }
    if (clampedCC == 120 || clampedCC == 123) {
        host->engine.pushEvent(npno::Engine::EventType::Panic, 0, 0.0f, clampedCh);
    } else {
        host->engine.pushEvent(npno::Engine::EventType::ControlChange, clampedCC, float(clampedVal), clampedCh);
    }
}

}  // extern "C"
