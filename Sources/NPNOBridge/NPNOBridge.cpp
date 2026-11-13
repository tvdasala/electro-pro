#include "NPNOBridge.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMIDI/CoreMIDI.h>
#include <dispatch/dispatch.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cmath>
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
    std::unique_ptr<npno::Engine> ownedEngine;
    npno::Engine* enginePtr = nullptr;
    bool isPlugin = false;
    NPNOPluginCallbacks pluginCallbacks{};

    npno::Engine& eng() noexcept { return *enginePtr; }
    const npno::Engine& eng() const noexcept { return *enginePtr; }
    void notifyPluginState() {
        if (isPlugin && pluginCallbacks.notifyStateChanged) {
            pluginCallbacks.notifyStateChanged(pluginCallbacks.pluginCtx);
        }
    }

    std::array<std::shared_ptr<npno::Instrument>, npno::Engine::kNumLayers> layerInstruments;
    std::array<std::vector<std::string>, npno::Engine::kNumLayers> layerBankFiles;
    std::array<int, npno::Engine::kNumLayers> layerBankIndex{-1, -1, -1, -1};

    // Instrumentos substituídos: só são destruídos (fora da thread de áudio) depois que vários ciclos de
    // render terminaram e um tempo mínimo passou, garantindo que nenhum callback em andamento ainda lê o ponteiro.
    struct RetiredInstrument {
        std::shared_ptr<npno::Instrument> inst;
        uint64_t renderCountAtRetire = 0;
        std::chrono::steady_clock::time_point when;
    };
    std::vector<RetiredInstrument> retiredInstruments;
    std::mutex instMutex;

    // CoreAudio
    std::recursive_mutex audioMutex;
    AudioComponentInstance audioUnit = nullptr;
    AudioDeviceID selectedAudioDeviceID = 0; // 0 = Saída Padrão do Sistema
    AudioDeviceID listenedDeviceID = 0;      // dispositivo físico atualmente em uso (com listeners registrados)
    double sampleRate = 48000.0;
    std::atomic<bool> audioRunning{false};
    bool wantAudio = false;                  // o usuário/app quer áudio rodando (false durante sleep)
    int preferredBufferSize = 0;             // 0 = padrão do dispositivo
    std::vector<float> scratchL;
    std::vector<float> scratchR;

    // Telemetria de confiabilidade (escrita pela thread de áudio / HAL, lida pela UI)
    std::atomic<float> cpuEma{0.0f};
    std::atomic<uint32_t> underrunCount{0};
    std::atomic<int32_t> currentBufferSize{0};
    std::atomic<float> estimatedLatencyMs{0.0f};
    std::atomic<uint32_t> routeChangeSeq{0};
    std::mutex deviceNameMutex;
    std::string activeDeviceName;

    dispatch_queue_t routeQueue = nullptr;
    std::atomic<bool> routeCheckPending{false};
    std::atomic<bool> shuttingDown{false};

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
        const auto t0 = std::chrono::steady_clock::now();

        const int frames = int(std::min<UInt32>(inNumberFrames, UInt32(self->scratchL.size())));
        if (ioData->mNumberBuffers >= 2 && ioData->mBuffers[0].mData && ioData->mBuffers[1].mData) {
            auto* outL = static_cast<float*>(ioData->mBuffers[0].mData);
            auto* outR = static_cast<float*>(ioData->mBuffers[1].mData);
            self->eng().render(outL, outR, frames);
        } else if (ioData->mBuffers[0].mData) {
            float* L = self->scratchL.data();
            float* R = self->scratchR.data();
            self->eng().render(L, R, frames);
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

        // Medição de carga do callback (sem alocação, sem lock, sem log)
        const double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        const double budget = double(inNumberFrames) / std::max(8000.0, self->sampleRate);
        if (budget > 0.0) {
            const float pct = float(elapsed / budget * 100.0);
            const float prev = self->cpuEma.load(std::memory_order_relaxed);
            self->cpuEma.store(prev + 0.08f * (pct - prev), std::memory_order_relaxed);
            if (elapsed > budget) self->underrunCount.fetch_add(1, std::memory_order_relaxed);
        }
        return noErr;
    }

    // ---------------------------------------------------------------------------------------------
    // CoreAudio helpers
    // ---------------------------------------------------------------------------------------------
    static AudioDeviceID systemDefaultOutputDevice() {
        AudioObjectPropertyAddress a = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
        AudioDeviceID dev = 0;
        UInt32 sz = sizeof(dev);
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, nullptr, &sz, &dev) != noErr) return 0;
        return dev;
    }

    static bool deviceIsAlive(AudioDeviceID dev) {
        if (dev == 0) return false;
        AudioObjectPropertyAddress a = {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
        UInt32 alive = 0;
        UInt32 sz = sizeof(alive);
        if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &sz, &alive) != noErr) return false;
        return alive != 0;
    }

    static double deviceNominalRate(AudioDeviceID dev) {
        if (dev == 0) return 0.0;
        AudioObjectPropertyAddress a = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
        Float64 rate = 0.0;
        UInt32 sz = sizeof(rate);
        if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &sz, &rate) != noErr) return 0.0;
        return rate;
    }

    static UInt32 deviceUInt32(AudioDeviceID dev, AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
        if (dev == 0) return 0;
        AudioObjectPropertyAddress a = {sel, scope, kAudioObjectPropertyElementMain};
        UInt32 v = 0;
        UInt32 sz = sizeof(v);
        if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &sz, &v) != noErr) return 0;
        return v;
    }

    static std::string deviceName(AudioDeviceID dev) {
        std::string result = "Audio Output";
        if (dev == 0) return result;
        AudioObjectPropertyAddress a = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                        kAudioObjectPropertyElementMain};
        CFStringRef cfName = nullptr;
        UInt32 sz = sizeof(cfName);
        if (AudioObjectGetPropertyData(dev, &a, 0, nullptr, &sz, &cfName) == noErr && cfName) {
            char buf[192] = {};
            if (CFStringGetCString(cfName, buf, sizeof(buf), kCFStringEncodingUTF8)) result = buf;
            CFRelease(cfName);
        }
        return result;
    }

    static OSStatus hwListenerProc(AudioObjectID /*obj*/, UInt32 numAddresses,
                                   const AudioObjectPropertyAddress* addresses, void* clientData) {
        auto* self = static_cast<NPNOHost*>(clientData);
        if (!self || self->shuttingDown.load(std::memory_order_acquire)) return noErr;
        bool needCheck = false;
        for (UInt32 i = 0; i < numAddresses; ++i) {
            if (addresses[i].mSelector == kAudioDeviceProcessorOverload) {
                self->underrunCount.fetch_add(1, std::memory_order_relaxed);
            } else {
                needCheck = true;
            }
        }
        if (needCheck) self->scheduleRouteCheck();
        return noErr;
    }

    static constexpr AudioObjectPropertySelector kSystemSelectors[2] = {
        kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices};
    static constexpr AudioObjectPropertySelector kDeviceSelectors[4] = {
        kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive, kAudioDeviceProcessorOverload,
        kAudioDevicePropertyBufferFrameSize};

    void registerSystemListeners() {
        for (auto sel : kSystemSelectors) {
            AudioObjectPropertyAddress a = {sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            AudioObjectAddPropertyListener(kAudioObjectSystemObject, &a, &NPNOHost::hwListenerProc, this);
        }
    }

    void unregisterSystemListeners() {
        for (auto sel : kSystemSelectors) {
            AudioObjectPropertyAddress a = {sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &a, &NPNOHost::hwListenerProc, this);
        }
    }

    void registerDeviceListeners(AudioDeviceID dev) {
        if (dev == 0) return;
        for (auto sel : kDeviceSelectors) {
            AudioObjectPropertyAddress a = {sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            AudioObjectAddPropertyListener(dev, &a, &NPNOHost::hwListenerProc, this);
        }
        listenedDeviceID = dev;
    }

    void unregisterDeviceListeners() {
        if (listenedDeviceID == 0) return;
        for (auto sel : kDeviceSelectors) {
            AudioObjectPropertyAddress a = {sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            AudioObjectRemovePropertyListener(listenedDeviceID, &a, &NPNOHost::hwListenerProc, this);
        }
        listenedDeviceID = 0;
    }

    AudioDeviceID resolveTargetDevice() const {
        return selectedAudioDeviceID != 0 ? selectedAudioDeviceID : systemDefaultOutputDevice();
    }

    void refreshDeviceMetricsLocked() {
        AudioDeviceID dev = listenedDeviceID;
        if (dev == 0) return;
        UInt32 bufFrames = deviceUInt32(dev, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal);
        if (audioUnit) {
            UInt32 auFrames = 0;
            UInt32 sz = sizeof(auFrames);
            if (AudioUnitGetProperty(audioUnit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                                     &auFrames, &sz) == noErr && auFrames > 0) {
                bufFrames = auFrames;
            }
        }
        const UInt32 devLatency = deviceUInt32(dev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput);
        const UInt32 safety = deviceUInt32(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput);
        currentBufferSize.store(int32_t(bufFrames), std::memory_order_relaxed);
        const double totalFrames = double(bufFrames) + double(devLatency) + double(safety);
        estimatedLatencyMs.store(float(totalFrames / std::max(8000.0, sampleRate) * 1000.0),
                                 std::memory_order_relaxed);
    }

    void scheduleRouteCheck() {
        if (!routeQueue || shuttingDown.load(std::memory_order_acquire)) return;
        if (routeCheckPending.exchange(true)) return;
        // Pequeno debounce: o HAL costuma emitir várias notificações em sequência numa troca de rota.
        dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, int64_t(150) * NSEC_PER_MSEC), routeQueue, this,
                         &NPNOHost::routeCheckTrampoline);
    }

    static void routeCheckTrampoline(void* ctx) {
        auto* self = static_cast<NPNOHost*>(ctx);
        if (self->shuttingDown.load(std::memory_order_acquire)) {
            self->routeCheckPending.store(false);
            return;
        }
        self->handleRouteCheck();
        self->routeCheckPending.store(false);
    }

    void handleRouteCheck() {
        enumerateAudioOutputDevices();
        std::lock_guard<std::recursive_mutex> lock(audioMutex);
        if (!wantAudio) return;

        if (selectedAudioDeviceID != 0 && !deviceIsAlive(selectedAudioDeviceID)) {
            // Dispositivo escolhido foi removido: volta para a saída padrão do sistema.
            selectedAudioDeviceID = 0;
        }
        const AudioDeviceID target = resolveTargetDevice();
        const double targetRate = deviceNominalRate(target);
        const bool rateChanged = targetRate > 0.0 && std::fabs(targetRate - sampleRate) > 0.5;
        const bool deviceChanged = target != listenedDeviceID;
        const bool deadDevice = listenedDeviceID != 0 && !deviceIsAlive(listenedDeviceID);

        if (!audioRunning.load() || deviceChanged || rateChanged || deadDevice) {
            stopAudioLocked();
            if (startAudioLocked()) {
                routeChangeSeq.fetch_add(1, std::memory_order_relaxed);
            }
        } else {
            refreshDeviceMetricsLocked();
        }
    }

    bool startAudioLocked() {
        if (audioRunning.load()) return true;

        AudioComponentDescription desc{};
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType =
            (selectedAudioDeviceID == 0) ? kAudioUnitSubType_DefaultOutput : kAudioUnitSubType_HALOutput;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;

        AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
        if (!comp) return false;
        if (AudioComponentInstanceNew(comp, &audioUnit) != noErr || !audioUnit) {
            audioUnit = nullptr;
            return false;
        }

        auto fail = [this]() {
            AudioComponentInstanceDispose(audioUnit);
            audioUnit = nullptr;
            return false;
        };

        if (selectedAudioDeviceID != 0) {
            AudioDeviceID devID = selectedAudioDeviceID;
            if (AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                     &devID, sizeof(devID)) != noErr) {
                fail();
                selectedAudioDeviceID = 0;
                return startAudioLocked();
            }
        }

        AudioDeviceID actualDevice = 0;
        {
            UInt32 sz = sizeof(actualDevice);
            if (AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                     &actualDevice, &sz) != noErr || actualDevice == 0) {
                actualDevice = resolveTargetDevice();
            }
        }

        if (preferredBufferSize > 0) {
            UInt32 frames = UInt32(preferredBufferSize);
            AudioUnitSetProperty(audioUnit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames,
                                 sizeof(frames));
        }
        {
            UInt32 maxFrames = 4096;
            AudioUnitSetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                 &maxFrames, sizeof(maxFrames));
        }

        Float64 hwRate = deviceNominalRate(actualDevice);
        if (hwRate < 8000.0) {
            UInt32 propSize = sizeof(hwRate);
            if (AudioUnitGetProperty(audioUnit, kAudioUnitProperty_SampleRate, kAudioUnitScope_Output, 0, &hwRate,
                                     &propSize) != noErr ||
                hwRate < 8000.0) {
                hwRate = 48000.0;
            }
        }
        sampleRate = hwRate;
        eng().prepare(hwRate);

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

        if (AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd,
                                 sizeof(asbd)) != noErr) {
            return fail();
        }

        AURenderCallbackStruct cb{};
        cb.inputProc = &NPNOHost::renderCallback;
        cb.inputProcRefCon = this;
        if (AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb,
                                 sizeof(cb)) != noErr) {
            return fail();
        }

        if (AudioUnitInitialize(audioUnit) != noErr) {
            return fail();
        }
        if (AudioOutputUnitStart(audioUnit) != noErr) {
            AudioUnitUninitialize(audioUnit);
            return fail();
        }

        audioRunning.store(true);
        cpuEma.store(0.0f, std::memory_order_relaxed);
        registerDeviceListeners(actualDevice);
        refreshDeviceMetricsLocked();
        {
            std::lock_guard<std::mutex> nameLock(deviceNameMutex);
            activeDeviceName = deviceName(actualDevice);
        }
        return true;
    }

    void stopAudioLocked() {
        unregisterDeviceListeners();
        if (!audioUnit) {
            audioRunning.store(false);
            return;
        }
        if (audioRunning.load()) {
            AudioOutputUnitStop(audioUnit);
            audioRunning.store(false);
        }
        AudioUnitUninitialize(audioUnit);
        AudioComponentInstanceDispose(audioUnit);
        audioUnit = nullptr;
    }

    /// Espera até `cycles` callbacks de render completos (ou timeout). Sem efeito se o áudio estiver parado.
    void waitForRenderCycles(int cycles) {
        if (!audioRunning.load()) return;
        const uint64_t start = eng().renderCount();
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(400);
        while (eng().renderCount() < start + uint64_t(cycles) && std::chrono::steady_clock::now() < deadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        }
    }

    /// Libera instrumentos aposentados em uma thread de fundo (nunca na thread de áudio nem na UI).
    void collectRetiredLocked(bool force = false) {
        if (retiredInstruments.empty()) return;
        const auto now = std::chrono::steady_clock::now();
        const uint64_t rc = eng().renderCount();
        const bool running = audioRunning.load();
        std::vector<std::shared_ptr<npno::Instrument>> toFree;
        for (auto it = retiredInstruments.begin(); it != retiredInstruments.end();) {
            const bool oldEnough = (now - it->when) >= std::chrono::milliseconds(500);
            const bool cyclesPassed = !running || rc >= it->renderCountAtRetire + 4;
            if (force || (oldEnough && cyclesPassed)) {
                toFree.push_back(std::move(it->inst));
                it = retiredInstruments.erase(it);
            } else {
                ++it;
            }
        }
        if (!toFree.empty()) {
            std::thread([victims = std::move(toFree)]() mutable { victims.clear(); }).detach();
        }
    }

    /// Solta todas as notas e pedais suavemente (usado quando um controlador MIDI é desconectado).
    void releaseAllNotes() {
        eng().pushEvent(npno::Engine::EventType::ControlChange, 64, 0.0f, 0);
        eng().pushEvent(npno::Engine::EventType::ControlChange, 66, 0.0f, 0);
        eng().pushEvent(npno::Engine::EventType::Sustain, 0, 0.0f, 0);
        for (int n = 0; n < 128; ++n) {
            eng().pushEvent(npno::Engine::EventType::NoteOff, n, 0.0f, 0);
        }
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
                            self->eng().pushEvent(npno::Engine::EventType::NoteOn, d1, float(d2) / 127.0f, msgChan);
                        else
                            self->eng().pushEvent(npno::Engine::EventType::NoteOff, d1, 0.0f, msgChan);
                    } else if (type == 0x80) {
                        self->eng().pushEvent(npno::Engine::EventType::NoteOff, d1, 0.0f, msgChan);
                    } else if (type == 0xB0) {
                        if (self->midiCcCallback) {
                            self->midiCcCallback(d1, d2, msgChan, self->midiCcContext);
                        }
                        if (d1 == 120 || d1 == 123) {
                            self->eng().pushEvent(npno::Engine::EventType::Panic, 0, 0.0f, msgChan);
                        } else {
                            self->eng().pushEvent(npno::Engine::EventType::ControlChange, d1, float(d2), msgChan);
                        }
                    } else if (type == 0xE0) {
                        const int bend = (int(d2) << 7) | int(d1);
                        const float norm = float(bend - 8192) / 8192.0f;
                        self->eng().pushEvent(npno::Engine::EventType::PitchBend, 0, norm, msgChan);
                    }
                }
            }
            packet = MIDIPacketNext(packet);
        }
    }

    static void midiNotifyProc(const MIDINotification* message, void* refCon) {
        auto* self = static_cast<NPNOHost*>(refCon);
        if (!self || !message) return;
        if (message->messageID == kMIDIMsgObjectRemoved) {
            // Um controlador sumiu: nenhuma nota pode ficar presa.
            self->releaseAllNotes();
        }
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
        const int prevConnected = midiSourceCount;
        midiSourceCount = connected;
        midiSourcesSummary = connected > 0 ? names : "No MIDI controller detected";
        if (connected < prevConnected) releaseAllNotes();
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
    host->ownedEngine = std::make_unique<npno::Engine>();
    host->enginePtr = host->ownedEngine.get();
    host->scratchL.resize(8192, 0.0f);
    host->scratchR.resize(8192, 0.0f);
    host->routeQueue = dispatch_queue_create("com.electropro.audio-route", DISPATCH_QUEUE_SERIAL);
    host->enumerateAudioOutputDevices();
    host->registerSystemListeners();
    host->initMidi();
    return host;
}

NPNOHost* npno_host_create_plugin(const NPNOPluginCallbacks* callbacks) {
    if (!callbacks || !callbacks->enginePtr) return nullptr;
    auto* host = new NPNOHost();
    host->isPlugin = true;
    host->pluginCallbacks = *callbacks;
    host->enginePtr = static_cast<npno::Engine*>(callbacks->enginePtr);
    host->audioRunning.store(true);
    return host;
}

bool npno_host_is_plugin(NPNOHost* host) {
    return host ? host->isPlugin : false;
}

void npno_host_destroy(NPNOHost* host) {
    if (!host) return;
    if (host->isPlugin) {
        delete host;
        return;
    }
    host->shuttingDown.store(true, std::memory_order_release);
    host->unregisterSystemListeners();
    // Aguarda qualquer verificação de rota agendada terminar antes de destruir o host.
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(600);
    while (host->routeCheckPending.load() && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    npno_host_stop_audio(host);
    if (host->midiInPort) MIDIPortDispose(host->midiInPort);
    if (host->midiClient) MIDIClientDispose(host->midiClient);
    {
        std::lock_guard<std::mutex> lock(host->instMutex);
        host->retiredInstruments.clear();
    }
    if (host->routeQueue) {
        dispatch_release(host->routeQueue);
        host->routeQueue = nullptr;
    }
    delete host;
}

bool npno_host_start_audio(NPNOHost* host) {
    if (!host) return false;
    if (host->isPlugin) return true;
    std::lock_guard<std::recursive_mutex> lock(host->audioMutex);
    host->wantAudio = true;
    return host->startAudioLocked();
}

void npno_host_stop_audio(NPNOHost* host) {
    if (!host || host->isPlugin) return;
    std::lock_guard<std::recursive_mutex> lock(host->audioMutex);
    host->wantAudio = false;
    host->stopAudioLocked();
}

void npno_host_reset_clip_indicator(NPNOHost* host) {
    if (host) host->eng().resetClipIndicator();
}

bool npno_host_set_buffer_size(NPNOHost* host, int32_t buffer_size) {
    if (!host) return false;
    std::lock_guard<std::recursive_mutex> lock(host->audioMutex);
    const int clamped = buffer_size <= 0 ? 0 : std::clamp<int>(buffer_size, 32, 2048);
    if (clamped == host->preferredBufferSize && host->audioRunning.load()) return true;
    host->preferredBufferSize = clamped;
    if (!host->audioRunning.load()) return true;
    host->stopAudioLocked();
    return host->startAudioLocked();
}

int32_t npno_host_get_buffer_size(NPNOHost* host) {
    return host ? host->currentBufferSize.load(std::memory_order_relaxed) : 0;
}

void npno_host_reset_underrun_count(NPNOHost* host) {
    if (host) host->underrunCount.store(0, std::memory_order_relaxed);
}

bool npno_host_load_layer_instrument(NPNOHost* host, int32_t layer, const char* path,
                                     void (*progress_cb)(float progress, void* ctx), void* ctx,
                                     char* err_buf, int32_t err_buf_len) {
    if (!host || !path || layer < 0 || layer >= npno::Engine::kNumLayers) return false;
    if (host->isPlugin) {
        if (!host->pluginCallbacks.loadLayerInstrument) return false;
        if (progress_cb) progress_cb(0.15f, ctx);
        bool ok = host->pluginCallbacks.loadLayerInstrument(host->pluginCallbacks.pluginCtx, layer, path, err_buf, err_buf_len);
        if (progress_cb) progress_cb(1.0f, ctx);
        return ok;
    }
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
        host->eng().setLayerInstrument(layer, inst.get());
        auto lp = host->eng().layerParams(layer);
        lp.enabled = true;
        host->eng().setLayerParams(layer, lp);
        if (host->layerInstruments[layer]) {
            host->retiredInstruments.push_back(
                {std::move(host->layerInstruments[layer]), host->eng().renderCount(), std::chrono::steady_clock::now()});
        }
        host->layerInstruments[layer] = std::move(inst);
        host->layerBankFiles[layer] = std::move(bankFiles);
        host->layerBankIndex[layer] = idx;
        host->collectRetiredLocked();
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
    if (host->isPlugin) {
        if (!host->pluginCallbacks.stepLayerInstrument) return false;
        if (progress_cb) progress_cb(0.2f, ctx);
        bool ok = host->pluginCallbacks.stepLayerInstrument(host->pluginCallbacks.pluginCtx, layer, delta);
        if (progress_cb) progress_cb(1.0f, ctx);
        return ok;
    }
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
    if (host->isPlugin) {
        if (host->pluginCallbacks.getLayerInstrumentInfo) {
            host->pluginCallbacks.getLayerInstrumentInfo(host->pluginCallbacks.pluginCtx, layer, out_info);
        }
        return;
    }

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

    const npno::LayerParams lp = host->eng().layerParams(layer);
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
    host->eng().setLayerParams(layer, lp);
}

void npno_host_start_midi_learn(NPNOHost* host, int32_t layer, int32_t slot) {
    if (host) host->eng().startMidiLearn(layer, slot);
}

void npno_host_cancel_midi_learn(NPNOHost* host) {
    if (host) host->eng().cancelMidiLearn();
}

namespace {
// Silencia suavemente todas as camadas, desconecta os ponteiros de instrumento da engine e espera
// a thread de áudio confirmar (ciclos de render completos) antes de mutar buffers PCM.
std::array<const npno::Instrument*, npno::Engine::kNumLayers> detachInstrumentsForMaintenance(NPNOHost* host) {
    std::array<const npno::Instrument*, npno::Engine::kNumLayers> saved{};
    for (int l = 0; l < npno::Engine::kNumLayers; ++l) {
        host->eng().pushEvent(npno::Engine::EventType::KillLayer, l, 0.0f, 0);
    }
    if (host->audioRunning.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(12)); // rampa de 6 ms + margem
        host->waitForRenderCycles(2);
    }
    for (int l = 0; l < npno::Engine::kNumLayers; ++l) {
        saved[size_t(l)] = host->eng().layerInstrument(l);
        host->eng().setLayerInstrumentPointer(l, nullptr);
    }
    host->waitForRenderCycles(2);
    return saved;
}

void reattachInstruments(NPNOHost* host, const std::array<const npno::Instrument*, npno::Engine::kNumLayers>& saved) {
    for (int l = 0; l < npno::Engine::kNumLayers; ++l) {
        host->eng().setLayerInstrumentPointer(l, saved[size_t(l)]);
    }
}
}  // namespace

uint64_t npno_host_purge_unused(NPNOHost* host) {
    if (!host) return 0;
    if (host->isPlugin) {
        return host->pluginCallbacks.purgeUnused ? host->pluginCallbacks.purgeUnused(host->pluginCallbacks.pluginCtx) : 0;
    }
    std::lock_guard<std::mutex> lock(host->instMutex);
    const auto saved = detachInstrumentsForMaintenance(host);
    uint64_t freed = 0;
    for (int l = 0; l < npno::Engine::kNumLayers; ++l) {
        if (host->layerInstruments[l]) {
            freed += host->layerInstruments[l]->purgeUnusedSamples();
        }
    }
    reattachInstruments(host, saved);
    return freed;
}

bool npno_host_reload_purged(NPNOHost* host) {
    if (!host) return false;
    if (host->isPlugin) {
        return host->pluginCallbacks.reloadPurged ? host->pluginCallbacks.reloadPurged(host->pluginCallbacks.pluginCtx) : false;
    }
    std::lock_guard<std::mutex> lock(host->instMutex);
    const auto saved = detachInstrumentsForMaintenance(host);
    bool ok = true;
    for (int l = 0; l < npno::Engine::kNumLayers; ++l) {
        if (host->layerInstruments[l]) {
            if (!host->layerInstruments[l]->reloadPurgedSamples()) ok = false;
        }
    }
    reattachInstruments(host, saved);
    return ok;
}

void npno_host_get_telemetry(NPNOHost* host, NPNOTelemetry* out_telemetry) {
    if (!out_telemetry) return;
    std::memset(out_telemetry, 0, sizeof(*out_telemetry));
    if (!host) return;

    out_telemetry->activeVoices = host->eng().activeVoices();
    out_telemetry->maxVoices = host->eng().maxVoices();
    for (int l = 0; l < 4; ++l) {
        out_telemetry->layerActiveVoices[l] = host->eng().layerActiveVoices(l);
    }
    out_telemetry->midiLearnLayer = host->eng().midiLearnLayer();
    out_telemetry->midiLearnSlot = host->eng().midiLearnSlot();
    out_telemetry->sustainDown = host->eng().isSustainDown();
    out_telemetry->peakL = host->eng().peakLeft();
    out_telemetry->peakR = host->eng().peakRight();
    host->eng().decayPeaks(0.84f);
    if (host->isPlugin && host->pluginCallbacks.getSampleRate) {
        out_telemetry->sampleRate = host->pluginCallbacks.getSampleRate(host->pluginCallbacks.pluginCtx);
    } else {
        out_telemetry->sampleRate = host->sampleRate;
    }

    out_telemetry->clipped = host->eng().isClipped();
    out_telemetry->callbackCpuPercent = host->cpuEma.load(std::memory_order_relaxed);
    out_telemetry->underrunCount = host->underrunCount.load(std::memory_order_relaxed);
    out_telemetry->bufferSize = host->currentBufferSize.load(std::memory_order_relaxed);
    out_telemetry->estimatedLatencyMs = host->estimatedLatencyMs.load(std::memory_order_relaxed);
    out_telemetry->audioRouteChangeSeq = host->routeChangeSeq.load(std::memory_order_relaxed);
    out_telemetry->audioRunning = host->audioRunning.load();
    if (host->isPlugin) {
        std::snprintf(out_telemetry->activeAudioDeviceName, sizeof(out_telemetry->activeAudioDeviceName), "DAW Host");
    } else {
        std::lock_guard<std::mutex> nameLock(host->deviceNameMutex);
        std::snprintf(out_telemetry->activeAudioDeviceName, sizeof(out_telemetry->activeAudioDeviceName), "%s",
                      host->activeDeviceName.c_str());
    }

    if (host->isPlugin) {
        out_telemetry->totalMemoryBytes = host->pluginCallbacks.getTotalMemoryBytes
            ? host->pluginCallbacks.getTotalMemoryBytes(host->pluginCallbacks.pluginCtx) : 0;
        out_telemetry->totalUnpurgedBytes = host->pluginCallbacks.getTotalUnpurgedBytes
            ? host->pluginCallbacks.getTotalUnpurgedBytes(host->pluginCallbacks.pluginCtx) : 0;
    } else {
        std::lock_guard<std::mutex> lock(host->instMutex);
        host->collectRetiredLocked();
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
        out_telemetry->keyVelocities[n] = host->eng().keyVelocity(n);
    }
}

void npno_host_note_on(NPNOHost* host, int32_t note, float velocity) {
    if (!host) return;
    host->eng().pushEvent(npno::Engine::EventType::NoteOn, note, velocity, 0);
}

void npno_host_note_off(NPNOHost* host, int32_t note) {
    if (!host) return;
    host->eng().pushEvent(npno::Engine::EventType::NoteOff, note, 0.0f, 0);
}

void npno_host_sustain(NPNOHost* host, bool down) {
    if (!host) return;
    host->eng().pushEvent(npno::Engine::EventType::Sustain, 0, down ? 1.0f : 0.0f, 0);
}

void npno_host_panic(NPNOHost* host) {
    if (!host) return;
    host->eng().pushEvent(npno::Engine::EventType::Panic, 0, 0.0f, 0);
}

void npno_host_set_master_gain(NPNOHost* host, float gain) {
    if (host) host->eng().setMasterGain(gain);
}

float npno_host_get_master_gain(NPNOHost* host) {
    return host ? host->eng().masterGain() : 1.0f;
}

void npno_host_set_master_pan(NPNOHost* host, float pan) {
    if (host) host->eng().setMasterPan(pan);
}

float npno_host_get_master_pan(NPNOHost* host) {
    return host ? host->eng().masterPan() : 0.0f;
}

void npno_host_set_fine_tune_cents(NPNOHost* host, float cents) {
    if (host) host->eng().setFineTuneCents(cents);
}

float npno_host_get_fine_tune_cents(NPNOHost* host) {
    return host ? host->eng().fineTuneCents() : 0.0f;
}

void npno_host_set_base_tuning_hz(NPNOHost* host, float hz) {
    if (host) host->eng().setBaseTuningHz(hz);
}

float npno_host_get_base_tuning_hz(NPNOHost* host) {
    return host ? host->eng().baseTuningHz() : 440.0f;
}

void npno_host_set_max_voices(NPNOHost* host, int32_t max_voices) {
    if (host) host->eng().setMaxVoices(max_voices);
}

int32_t npno_host_get_max_voices(NPNOHost* host) {
    return host ? host->eng().maxVoices() : 256;
}

void npno_host_set_transpose(NPNOHost* host, int32_t semitones) {
    if (host) host->eng().setTransposeSemitones(semitones);
}

int32_t npno_host_get_transpose(NPNOHost* host) {
    return host ? host->eng().transposeSemitones() : 0;
}

void npno_host_set_velocity_curve(NPNOHost* host, int32_t curve) {
    if (host) host->eng().setVelocityCurve(curve);
}

int32_t npno_host_get_velocity_curve(NPNOHost* host) {
    return host ? host->eng().velocityCurve() : 0;
}

void npno_host_set_release_samples_enabled(NPNOHost* host, bool enabled) {
    if (host) host->eng().setReleaseSamplesEnabled(enabled);
}

bool npno_host_get_release_samples_enabled(NPNOHost* host) {
    return host ? host->eng().releaseSamplesEnabled() : true;
}

void npno_host_set_release_sample_gain(NPNOHost* host, float gain) {
    if (host) host->eng().setReleaseSampleGain(gain);
}

float npno_host_get_release_sample_gain(NPNOHost* host) {
    return host ? host->eng().releaseSampleGain() : 1.0f;
}

void npno_host_set_release_scale(NPNOHost* host, float scale) {
    if (host) host->eng().setReleaseScale(scale);
}

float npno_host_get_release_scale(NPNOHost* host) {
    return host ? host->eng().releaseScale() : 1.0f;
}

void npno_host_set_eq_bass_db(NPNOHost* host, float db) {
    if (host) host->eng().setEqBassDb(db);
}

float npno_host_get_eq_bass_db(NPNOHost* host) {
    return host ? host->eng().eqBassDb() : 0.0f;
}

void npno_host_set_eq_mid_db(NPNOHost* host, float db) {
    if (host) host->eng().setEqMidDb(db);
}

float npno_host_get_eq_mid_db(NPNOHost* host) {
    return host ? host->eng().eqMidDb() : 0.0f;
}

void npno_host_set_eq_mid_freq_hz(NPNOHost* host, float hz) {
    if (host) host->eng().setEqMidFreqHz(hz);
}

float npno_host_get_eq_mid_freq_hz(NPNOHost* host) {
    return host ? host->eng().eqMidFreqHz() : 1000.0f;
}

void npno_host_set_eq_treble_db(NPNOHost* host, float db) {
    if (host) host->eng().setEqTrebleDb(db);
}

float npno_host_get_eq_treble_db(NPNOHost* host) {
    return host ? host->eng().eqTrebleDb() : 0.0f;
}

void npno_host_set_drive_enabled(NPNOHost* host, bool enabled) {
    if (host) host->eng().setDriveEnabled(enabled);
}

bool npno_host_get_drive_enabled(NPNOHost* host) {
    return host ? host->eng().driveEnabled() : false;
}

void npno_host_set_drive_amount(NPNOHost* host, float amount) {
    if (host) host->eng().setDriveAmount(amount);
}

float npno_host_get_drive_amount(NPNOHost* host) {
    return host ? host->eng().driveAmount() : 0.25f;
}

void npno_host_get_modulator_params(NPNOHost* host, int32_t index, NPNOModulatorParams* out_params) {
    if (!out_params) return;
    std::memset(out_params, 0, sizeof(*out_params));
    if (!host || index < 0 || index > 1) return;
    const auto m = host->eng().modulatorParams(index);
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
    host->eng().setModulatorParams(index, m);
}

void npno_host_get_delay_params(NPNOHost* host, NPNODelayParams* out_params) {
    if (!out_params) return;
    std::memset(out_params, 0, sizeof(*out_params));
    if (!host) return;
    const auto d = host->eng().delayParams();
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
    host->eng().setDelayParams(d);
}

void npno_host_tap_delay(NPNOHost* host) {
    if (!host) return;
    const double nowSec = std::chrono::duration<double>(
                              std::chrono::steady_clock::now().time_since_epoch())
                              .count();
    host->eng().tapDelay(nowSec);
}

void npno_host_get_reverb_params(NPNOHost* host, NPNOReverbParams* out_params) {
    if (!out_params) return;
    std::memset(out_params, 0, sizeof(*out_params));
    if (!host) return;
    const auto r = host->eng().reverbParams();
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
    host->eng().setReverbParams(r);
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
    std::lock_guard<std::recursive_mutex> lock(host->audioMutex);
    if (host->selectedAudioDeviceID == device_id && host->audioRunning.load()) return true;
    host->stopAudioLocked();
    host->selectedAudioDeviceID = device_id;
    host->wantAudio = true;
    return host->startAudioLocked();
}

uint32_t npno_host_get_current_audio_output_device(NPNOHost* host) {
    if (!host) return 0;
    std::lock_guard<std::recursive_mutex> lock(host->audioMutex);
    return host->selectedAudioDeviceID;
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
    host->eng().setGlobalMidiChannel(ch);
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
        host->eng().pushEvent(npno::Engine::EventType::Panic, 0, 0.0f, clampedCh);
    } else {
        host->eng().pushEvent(npno::Engine::EventType::ControlChange, clampedCC, float(clampedVal), clampedCh);
    }
}

void npno_host_render_offline(NPNOHost* host, float* out_l, float* out_r, int32_t num_frames) {
    if (!host || !out_l || !out_r || num_frames <= 0) return;
    host->eng().render(out_l, out_r, int(num_frames));
}

bool npno_host_load_test_tone(NPNOHost* host, int32_t layer, float amplitude) {
    if (!host || layer < 0 || layer >= npno::Engine::kNumLayers) return false;
    auto inst = std::make_shared<npno::Instrument>();
    inst->name = "Test Tone";
    inst->model = "Synthetic";
    inst->channels = 2;
    inst->lowestNote = 0;
    inst->highestNote = 127;
    inst->damperBoundary = 127;

    npno::Sample s{};
    s.sampleIndex = 0;
    s.root = 60;
    s.keyLow = 0;
    s.keyHigh = 127;
    s.velLow = 0;
    s.velHigh = 127;
    s.rate = 48000.0;
    s.channels = 2;
    s.frames = 4096;
    s.originalFrames = 4096;
    s.loopStart = 0;
    s.loopLength = 4096;
    s.originalLoopLength = 4096;
    s.loopDecayDb = 0.0;
    s.releaseMs = 200.0f;
    s.gain = 1.0f / 32768.0f;
    s.peak = int(std::clamp(int(std::lround(amplitude * 32767.0f)), 1, 32767));
    s.pcm.resize(size_t(s.frames) * 2 + 16, int16_t(s.peak));
    inst->samples.push_back(std::move(s));
    inst->sampleUsed.assign(1, 0);
    inst->samplePurged.assign(1, 0);
    inst->keymap.fill(60);
    inst->cents.fill(0);
    inst->trim.fill(0);
    inst->noteGainLinear.fill(1.0f);
    inst->normalByRoot[60] = {0};

    std::lock_guard<std::mutex> lock(host->instMutex);
    host->eng().setLayerInstrument(layer, inst.get());
    auto lp = host->eng().layerParams(layer);
    lp.enabled = true;
    host->eng().setLayerParams(layer, lp);
    if (host->layerInstruments[layer]) {
        host->retiredInstruments.push_back(
            {std::move(host->layerInstruments[layer]), host->eng().renderCount(), std::chrono::steady_clock::now()});
    }
    host->layerInstruments[layer] = std::move(inst);
    return true;
}

}  // extern "C"
