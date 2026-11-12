#include "PluginShared.hpp"

#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AUCocoaUIView.h>
#import <AudioUnit/AudioUnit.h>
#import <Cocoa/Cocoa.h>
#import <CoreMIDI/CoreMIDI.h>
#include <dlfcn.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <mutex>
#include <vector>

namespace {

constexpr OSType kPluginType = 'aumu';
constexpr OSType kPluginSubtype = 'Epno';
constexpr OSType kPluginManufacturer = 'ElPr';
constexpr AudioUnitPropertyID kElectroPianoProperty_CorePtr = 64000;

struct PropListener {
    AudioUnitPropertyID id;
    AudioUnitPropertyListenerProc proc;
    void* userData;
};

struct RenderNotifyEntry {
    AURenderCallback proc;
    void* userData;
};

struct ElectroPianoAUInstance {
    AudioComponentPlugInInterface iface;
    AudioComponentInstance componentInstance = nullptr;

    epno::ElectroPianoCore core;

    bool initialized = false;
    Float64 sampleRate = 44100.0;
    UInt32 maxFramesPerSlice = 1156;
    UInt32 renderQuality = 127;
    UInt32 inPlaceProcessing = 0;
    UInt32 offlineRender = 0;
    UInt32 shouldAllocateBuffer = 1;
    OSStatus lastRenderError = noErr;

    AudioStreamBasicDescription outputFormat{};
    HostCallbackInfo hostCallbacks{};
    CFStringRef contextName = nullptr;
    AUPreset currentPreset{-1, CFSTR("Astoria Grand XL")};

    std::mutex propMtx;
    std::vector<PropListener> propListeners;
    std::vector<RenderNotifyEntry> renderNotifies;

    std::vector<float> scratchL;
    std::vector<float> scratchR;
    NoteInstanceID nextNoteID = 1000;

    ElectroPianoAUInstance() {
        CFRetain(currentPreset.presetName);
        updateStreamFormat(44100.0);
        scratchL.resize(4096, 0.0f);
        scratchR.resize(4096, 0.0f);
    }

    ~ElectroPianoAUInstance() {
        if (contextName) CFRelease(contextName);
        if (currentPreset.presetName) CFRelease(currentPreset.presetName);
    }

    void updateStreamFormat(Float64 sr) {
        sampleRate = sr;
        std::memset(&outputFormat, 0, sizeof(outputFormat));
        outputFormat.mSampleRate = sr;
        outputFormat.mFormatID = kAudioFormatLinearPCM;
        outputFormat.mFormatFlags = static_cast<AudioFormatFlags>(kAudioFormatFlagsNativeFloatPacked) |
                                    static_cast<AudioFormatFlags>(kAudioFormatFlagIsNonInterleaved);
        outputFormat.mBytesPerPacket = sizeof(Float32);
        outputFormat.mFramesPerPacket = 1;
        outputFormat.mBytesPerFrame = sizeof(Float32);
        outputFormat.mChannelsPerFrame = 2;
        outputFormat.mBitsPerChannel = 32;
        outputFormat.mReserved = 0;
    }

    void notifyPropertyChanged(AudioUnitPropertyID propID, AudioUnitScope scope, AudioUnitElement elem) {
        std::vector<PropListener> copy;
        {
            std::lock_guard<std::mutex> lk(propMtx);
            for (const auto& l : propListeners) {
                if (l.id == propID && l.proc) copy.push_back(l);
            }
        }
        for (const auto& l : copy) {
            l.proc(l.userData, componentInstance, propID, scope, elem);
        }
    }
};

static ElectroPianoAUInstance* Self(void* inStorage) {
    return reinterpret_cast<ElectroPianoAUInstance*>(inStorage);
}

static bool IsScopeElementValid(AudioUnitScope inScope, AudioUnitElement inElement, OSStatus* outErr) {
    switch (inScope) {
        case kAudioUnitScope_Global:
            if (inElement != 0) {
                *outErr = kAudioUnitErr_InvalidElement;
                return false;
            }
            return true;
        case kAudioUnitScope_Input:
            *outErr = kAudioUnitErr_InvalidScope;
            return false;
        case kAudioUnitScope_Output:
            if (inElement != 0) {
                *outErr = kAudioUnitErr_InvalidElement;
                return false;
            }
            return true;
        case kAudioUnitScope_Group:
        case kAudioUnitScope_Part:
        case kAudioUnitScope_Note:
            return true;
        default:
            *outErr = kAudioUnitErr_InvalidScope;
            return false;
    }
}

// ============================================================================
// Implementação dos Seletores AudioUnit v2
// ============================================================================

static OSStatus AU_Initialize(void* inStorage) {
    auto* au = Self(inStorage);
    if (!au) return kAudio_ParamError;
    au->core.setSampleRate(au->sampleRate);
    size_t cap = std::max<size_t>(4096, au->maxFramesPerSlice);
    au->scratchL.assign(cap, 0.0f);
    au->scratchR.assign(cap, 0.0f);
    au->initialized = true;
    return noErr;
}

static OSStatus AU_Uninitialize(void* inStorage) {
    auto* au = Self(inStorage);
    if (!au) return kAudio_ParamError;
    au->core.panic();
    au->initialized = false;
    return noErr;
}

static OSStatus AU_Reset(void* inStorage, AudioUnitScope inScope, AudioUnitElement inElement) {
    (void)inScope;
    (void)inElement;
    auto* au = Self(inStorage);
    if (!au) return kAudio_ParamError;
    au->core.panic();
    return noErr;
}

static OSStatus AU_GetPropertyInfo(void* inStorage,
                                   AudioUnitPropertyID inID,
                                   AudioUnitScope inScope,
                                   AudioUnitElement inElement,
                                   UInt32* outDataSize,
                                   Boolean* outWritable) {
    auto* au = Self(inStorage);
    if (!au) return kAudio_ParamError;

    UInt32 size = 0;
    Boolean writable = false;

    switch (inID) {
        case kAudioUnitProperty_ElementCount:
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            if (inScope > kAudioUnitScope_Note) return kAudioUnitErr_InvalidScope;
            size = sizeof(UInt32);
            writable = false;
            break;

        case kAudioUnitProperty_StreamFormat:
            if (inScope != kAudioUnitScope_Output) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            size = sizeof(AudioStreamBasicDescription);
            writable = true;
            break;

        case kAudioUnitProperty_SampleRate:
            if (inScope != kAudioUnitScope_Global && inScope != kAudioUnitScope_Output)
                return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            size = sizeof(Float64);
            writable = true;
            break;

        case kAudioUnitProperty_SupportedNumChannels:
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            size = sizeof(AUChannelInfo);
            writable = false;
            break;

        case kAudioUnitProperty_MaximumFramesPerSlice:
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            size = sizeof(UInt32);
            writable = true;
            break;

        case kAudioUnitProperty_Latency:
        case kAudioUnitProperty_TailTime:
        case kAudioUnitProperty_CPULoad:
        case kAudioUnitProperty_PresentationLatency:
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            size = sizeof(Float64);
            writable = false;
            break;

        case kAudioUnitProperty_ParameterList:
            if (inScope == kAudioUnitScope_Global) {
                if (inElement != 0) return kAudioUnitErr_InvalidElement;
                size = epno::kNumParams * sizeof(AudioUnitParameterID);
            } else if (inScope == kAudioUnitScope_Input || inScope == kAudioUnitScope_Output ||
                       inScope == kAudioUnitScope_Group) {
                size = 0;
            } else {
                return kAudioUnitErr_InvalidScope;
            }
            writable = false;
            break;

        case kAudioUnitProperty_ParameterInfo:
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement >= epno::kNumParams) return kAudioUnitErr_InvalidParameter;
            size = sizeof(AudioUnitParameterInfo);
            writable = false;
            break;

        case kAudioUnitProperty_ParameterValueStrings:
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != epno::kParamVelocityCurve) return kAudioUnitErr_InvalidProperty;
            size = sizeof(CFArrayRef);
            writable = false;
            break;

        case kAudioUnitProperty_ClassInfo:
        case kAudioUnitProperty_ClassInfoFromDocument:
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            size = sizeof(CFPropertyListRef);
            writable = true;
            break;

        case kAudioUnitProperty_PresentPreset:
        case kAudioUnitProperty_CurrentPreset:
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            size = sizeof(AUPreset);
            writable = true;
            break;

        case kAudioUnitProperty_FactoryPresets:
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            size = sizeof(CFArrayRef);
            writable = false;
            break;

        case kAudioUnitProperty_RenderQuality:
        case kAudioUnitProperty_InPlaceProcessing:
        case kAudioUnitProperty_OfflineRender:
        case kAudioUnitProperty_ShouldAllocateBuffer:
            if (inScope != kAudioUnitScope_Global && inScope != kAudioUnitScope_Output)
                return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            size = sizeof(UInt32);
            writable = true;
            break;

        case kAudioUnitProperty_LastRenderError:
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            size = sizeof(OSStatus);
            writable = false;
            break;

        case kAudioUnitProperty_HostCallbacks:
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            size = sizeof(HostCallbackInfo);
            writable = true;
            break;

        case kAudioUnitProperty_ContextName:
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            size = sizeof(CFStringRef);
            writable = true;
            break;

        case kAudioUnitProperty_CocoaUI:
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            size = sizeof(AudioUnitCocoaViewInfo);
            writable = false;
            break;

        case kMusicDeviceProperty_InstrumentCount:
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            size = sizeof(UInt32);
            writable = false;
            break;

        case kElectroPianoProperty_CorePtr:
            size = sizeof(void*);
            writable = false;
            break;

        default: {
            OSStatus err = noErr;
            if (!IsScopeElementValid(inScope, inElement, &err)) return err;
            return kAudioUnitErr_InvalidProperty;
        }
    }

    if (outDataSize) *outDataSize = size;
    if (outWritable) *outWritable = writable;
    return noErr;
}

static CFArrayRef CreateFactoryPresetsArray() {
    static AUPreset sPreset = {0, CFSTR("Astoria Grand XL")};
    const void* values[1] = {&sPreset};
    CFArrayCallBacks cbs = {0, nullptr, nullptr, nullptr, nullptr};
    return CFArrayCreate(kCFAllocatorDefault, values, 1, &cbs);
}

static OSStatus AU_GetProperty(void* inStorage,
                               AudioUnitPropertyID inID,
                               AudioUnitScope inScope,
                               AudioUnitElement inElement,
                               void* outData,
                               UInt32* ioDataSize) {
    auto* au = Self(inStorage);
    if (!au || !ioDataSize) return kAudio_ParamError;

    UInt32 reqSize = 0;
    Boolean writable = false;
    OSStatus infoErr = AU_GetPropertyInfo(inStorage, inID, inScope, inElement, &reqSize, &writable);
    if (infoErr != noErr) return infoErr;

    if (!outData) {
        *ioDataSize = reqSize;
        return noErr;
    }
    if (*ioDataSize < reqSize) return kAudio_ParamError;

    switch (inID) {
        case kAudioUnitProperty_ElementCount: {
            UInt32 count = 0;
            if (inScope == kAudioUnitScope_Global) count = 1;
            else if (inScope == kAudioUnitScope_Input) count = 0;
            else if (inScope == kAudioUnitScope_Output) count = 1;
            else if (inScope == kAudioUnitScope_Group) count = 16;
            else if (inScope == kAudioUnitScope_Part) count = 1;
            else if (inScope == kAudioUnitScope_Note) count = 128;
            *reinterpret_cast<UInt32*>(outData) = count;
            *ioDataSize = sizeof(UInt32);
            return noErr;
        }

        case kAudioUnitProperty_StreamFormat:
            *reinterpret_cast<AudioStreamBasicDescription*>(outData) = au->outputFormat;
            *ioDataSize = sizeof(AudioStreamBasicDescription);
            return noErr;

        case kAudioUnitProperty_SampleRate:
            *reinterpret_cast<Float64*>(outData) = au->sampleRate;
            *ioDataSize = sizeof(Float64);
            return noErr;

        case kAudioUnitProperty_SupportedNumChannels: {
            AUChannelInfo info{0, 2};
            *reinterpret_cast<AUChannelInfo*>(outData) = info;
            *ioDataSize = sizeof(AUChannelInfo);
            return noErr;
        }

        case kAudioUnitProperty_MaximumFramesPerSlice:
            *reinterpret_cast<UInt32*>(outData) = au->maxFramesPerSlice;
            *ioDataSize = sizeof(UInt32);
            return noErr;

        case kAudioUnitProperty_Latency:
        case kAudioUnitProperty_CPULoad:
        case kAudioUnitProperty_PresentationLatency:
            *reinterpret_cast<Float64*>(outData) = 0.0;
            *ioDataSize = sizeof(Float64);
            return noErr;

        case kAudioUnitProperty_TailTime:
            *reinterpret_cast<Float64*>(outData) = 2.0;
            *ioDataSize = sizeof(Float64);
            return noErr;

        case kAudioUnitProperty_ParameterList: {
            if (inScope == kAudioUnitScope_Global) {
                auto* dst = reinterpret_cast<AudioUnitParameterID*>(outData);
                for (UInt32 i = 0; i < epno::kNumParams; ++i) dst[i] = i;
                *ioDataSize = epno::kNumParams * sizeof(AudioUnitParameterID);
            } else {
                *ioDataSize = 0;
            }
            return noErr;
        }

        case kAudioUnitProperty_ParameterInfo: {
            if (inElement >= epno::kNumParams) return kAudioUnitErr_InvalidParameter;
            const auto& spec = epno::kParamSpecs[inElement];
            auto* info = reinterpret_cast<AudioUnitParameterInfo*>(outData);
            std::memset(info, 0, sizeof(AudioUnitParameterInfo));
            std::strncpy(info->name, spec.name, sizeof(info->name) - 1);
            info->cfNameString = CFStringCreateWithCString(kCFAllocatorDefault, spec.name, kCFStringEncodingUTF8);
            info->minValue = spec.minVal;
            info->maxValue = spec.maxVal;
            info->defaultValue = spec.defaultVal;
            info->flags = kAudioUnitParameterFlag_IsReadable | kAudioUnitParameterFlag_IsWritable |
                          kAudioUnitParameterFlag_HasCFNameString | kAudioUnitParameterFlag_CFNameRelease;
            if (inElement == epno::kParamMasterGainDb ||
                inElement == epno::kParamEqBassDb ||
                inElement == epno::kParamEqMidDb ||
                inElement == epno::kParamEqTrebleDb) {
                info->unit = kAudioUnitParameterUnit_Decibels;
            } else if (inElement == epno::kParamVelocityCurve) {
                info->unit = kAudioUnitParameterUnit_Indexed;
            } else if (inElement == epno::kParamTranspose) {
                info->unit = kAudioUnitParameterUnit_RelativeSemiTones;
            } else if (inElement == epno::kParamTuningHz || inElement == epno::kParamEqMidFreqHz) {
                info->unit = kAudioUnitParameterUnit_Hertz;
            } else if (inElement == epno::kParamReleaseSamples || inElement == epno::kParamReleaseTime) {
                info->unit = kAudioUnitParameterUnit_Percent;
            } else {
                info->unit = kAudioUnitParameterUnit_Boolean;
            }
            *ioDataSize = sizeof(AudioUnitParameterInfo);
            return noErr;
        }

        case kAudioUnitProperty_ParameterValueStrings: {
            if (inElement != epno::kParamVelocityCurve) return kAudioUnitErr_InvalidProperty;
            CFStringRef labels[3] = {CFSTR("Leve"), CFSTR("Normal"), CFSTR("Pesada")};
            CFArrayRef arr = CFArrayCreate(kCFAllocatorDefault, (const void**)labels, 3, &kCFTypeArrayCallBacks);
            *reinterpret_cast<CFArrayRef*>(outData) = arr;
            *ioDataSize = sizeof(CFArrayRef);
            return noErr;
        }

        case kAudioUnitProperty_ClassInfo:
        case kAudioUnitProperty_ClassInfoFromDocument: {
            CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
                kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

            SInt32 ver = 0;
            SInt32 type = kPluginType;
            SInt32 sub = kPluginSubtype;
            SInt32 manu = kPluginManufacturer;

            CFNumberRef nVer = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &ver);
            CFNumberRef nType = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &type);
            CFNumberRef nSub = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &sub);
            CFNumberRef nManu = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &manu);

            CFDictionarySetValue(dict, CFSTR(kAUPresetVersionKey), nVer);
            CFDictionarySetValue(dict, CFSTR(kAUPresetTypeKey), nType);
            CFDictionarySetValue(dict, CFSTR(kAUPresetSubtypeKey), nSub);
            CFDictionarySetValue(dict, CFSTR(kAUPresetManufacturerKey), nManu);
            if (au->currentPreset.presetName) {
                CFDictionarySetValue(dict, CFSTR(kAUPresetNameKey), au->currentPreset.presetName);
            }

            CFRelease(nVer);
            CFRelease(nType);
            CFRelease(nSub);
            CFRelease(nManu);

            float paramData[epno::kNumParams];
            for (UInt32 i = 0; i < epno::kNumParams; ++i) {
                paramData[i] = au->core.getParam(i);
            }
            CFDataRef dRef = CFDataCreate(kCFAllocatorDefault, reinterpret_cast<const UInt8*>(paramData), sizeof(paramData));
            if (dRef) {
                CFDictionarySetValue(dict, CFSTR(kAUPresetDataKey), dRef);
                CFRelease(dRef);
            }

            auto fullBlob = au->core.serializeState();
            if (!fullBlob.empty()) {
                CFDataRef fullRef = CFDataCreate(kCFAllocatorDefault, fullBlob.data(), static_cast<CFIndex>(fullBlob.size()));
                if (fullRef) {
                    CFDictionarySetValue(dict, CFSTR("ElectroPianoFullState"), fullRef);
                    CFRelease(fullRef);
                }
            }

            auto sum = au->core.getBankSummary();
            if (!sum.path.empty()) {
                CFStringRef pStr = CFStringCreateWithCString(kCFAllocatorDefault, sum.path.c_str(), kCFStringEncodingUTF8);
                if (pStr) {
                    CFDictionarySetValue(dict, CFSTR("npnoPath"), pStr);
                    CFRelease(pStr);
                }
            }

            *reinterpret_cast<CFPropertyListRef*>(outData) = dict;
            *ioDataSize = sizeof(CFPropertyListRef);
            return noErr;
        }

        case kAudioUnitProperty_PresentPreset:
        case kAudioUnitProperty_CurrentPreset: {
            auto* dst = reinterpret_cast<AUPreset*>(outData);
            *dst = au->currentPreset;
            if (inID == kAudioUnitProperty_PresentPreset && dst->presetName) {
                CFRetain(dst->presetName);
            }
            *ioDataSize = sizeof(AUPreset);
            return noErr;
        }

        case kAudioUnitProperty_FactoryPresets: {
            *reinterpret_cast<CFArrayRef*>(outData) = CreateFactoryPresetsArray();
            *ioDataSize = sizeof(CFArrayRef);
            return noErr;
        }

        case kAudioUnitProperty_RenderQuality:
            *reinterpret_cast<UInt32*>(outData) = au->renderQuality;
            *ioDataSize = sizeof(UInt32);
            return noErr;

        case kAudioUnitProperty_InPlaceProcessing:
            *reinterpret_cast<UInt32*>(outData) = au->inPlaceProcessing;
            *ioDataSize = sizeof(UInt32);
            return noErr;

        case kAudioUnitProperty_OfflineRender:
            *reinterpret_cast<UInt32*>(outData) = au->offlineRender;
            *ioDataSize = sizeof(UInt32);
            return noErr;

        case kAudioUnitProperty_ShouldAllocateBuffer:
            *reinterpret_cast<UInt32*>(outData) = au->shouldAllocateBuffer;
            *ioDataSize = sizeof(UInt32);
            return noErr;

        case kAudioUnitProperty_LastRenderError:
            *reinterpret_cast<OSStatus*>(outData) = au->lastRenderError;
            au->lastRenderError = noErr;
            *ioDataSize = sizeof(OSStatus);
            return noErr;

        case kAudioUnitProperty_HostCallbacks:
            *reinterpret_cast<HostCallbackInfo*>(outData) = au->hostCallbacks;
            *ioDataSize = sizeof(HostCallbackInfo);
            return noErr;

        case kAudioUnitProperty_ContextName:
            if (au->contextName) CFRetain(au->contextName);
            *reinterpret_cast<CFStringRef*>(outData) = au->contextName;
            *ioDataSize = sizeof(CFStringRef);
            return noErr;

        case kAudioUnitProperty_CocoaUI: {
            auto* viewInfo = reinterpret_cast<AudioUnitCocoaViewInfo*>(outData);
            Dl_info dlInfo{};
            CFURLRef bundleURL = nullptr;
            if (dladdr((const void*)&AU_GetProperty, &dlInfo) && dlInfo.dli_fname) {
                @autoreleasepool {
                    NSString* execPath = [NSString stringWithUTF8String:dlInfo.dli_fname];
                    NSString* bundlePath = [[[execPath stringByDeletingLastPathComponent]
                        stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
                    NSURL* url = [NSURL fileURLWithPath:bundlePath isDirectory:YES];
                    bundleURL = (__bridge_retained CFURLRef)url;
                }
            }
            viewInfo->mCocoaAUViewBundleLocation = bundleURL;
            viewInfo->mCocoaAUViewClass[0] = CFStringCreateWithCString(
                kCFAllocatorDefault, "ElectroPianoAUCocoaViewFactory", kCFStringEncodingUTF8);
            *ioDataSize = sizeof(AudioUnitCocoaViewInfo);
            return noErr;
        }

        case kMusicDeviceProperty_InstrumentCount:
            *reinterpret_cast<UInt32*>(outData) = 1;
            *ioDataSize = sizeof(UInt32);
            return noErr;

        case kElectroPianoProperty_CorePtr:
            *reinterpret_cast<void**>(outData) = &au->core;
            *ioDataSize = sizeof(void*);
            return noErr;

        default:
            return kAudioUnitErr_InvalidProperty;
    }
}

static OSStatus AU_SetProperty(void* inStorage,
                               AudioUnitPropertyID inID,
                               AudioUnitScope inScope,
                               AudioUnitElement inElement,
                               const void* inData,
                               UInt32 inDataSize) {
    auto* au = Self(inStorage);
    if (!au) return kAudio_ParamError;

    switch (inID) {
        case kAudioUnitProperty_StreamFormat: {
            if (inScope != kAudioUnitScope_Output) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            if (!inData || inDataSize < sizeof(AudioStreamBasicDescription)) return kAudio_ParamError;
            const auto* asbd = reinterpret_cast<const AudioStreamBasicDescription*>(inData);
            if (asbd->mFormatID != kAudioFormatLinearPCM) return kAudioUnitErr_FormatNotSupported;
            if (asbd->mChannelsPerFrame != 2) return kAudioUnitErr_FormatNotSupported;
            if (asbd->mBitsPerChannel != 32 ||
                (asbd->mFormatFlags & kAudioFormatFlagIsFloat) == 0 ||
                (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0 ||
                (asbd->mFormatFlags & kAudioFormatFlagIsBigEndian) != 0) {
                return kAudioUnitErr_FormatNotSupported;
            }
            if (asbd->mSampleRate <= 0.0) return kAudioUnitErr_FormatNotSupported;
            au->updateStreamFormat(asbd->mSampleRate);
            au->core.setSampleRate(asbd->mSampleRate);
            au->notifyPropertyChanged(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0);
            return noErr;
        }

        case kAudioUnitProperty_SampleRate: {
            if (inScope != kAudioUnitScope_Global && inScope != kAudioUnitScope_Output)
                return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            if (!inData || inDataSize < sizeof(Float64)) return kAudio_ParamError;
            Float64 sr = *reinterpret_cast<const Float64*>(inData);
            if (sr <= 0.0) return kAudioUnitErr_InvalidPropertyValue;
            au->updateStreamFormat(sr);
            au->core.setSampleRate(sr);
            au->notifyPropertyChanged(kAudioUnitProperty_SampleRate, inScope, 0);
            return noErr;
        }

        case kAudioUnitProperty_MaximumFramesPerSlice: {
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            if (!inData || inDataSize < sizeof(UInt32)) return kAudio_ParamError;
            UInt32 frames = *reinterpret_cast<const UInt32*>(inData);
            if (frames == 0) return kAudioUnitErr_InvalidPropertyValue;
            au->maxFramesPerSlice = frames;
            size_t cap = std::max<size_t>(4096, frames);
            au->scratchL.resize(cap, 0.0f);
            au->scratchR.resize(cap, 0.0f);
            au->notifyPropertyChanged(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0);
            return noErr;
        }

        case kAudioUnitProperty_ClassInfo:
        case kAudioUnitProperty_ClassInfoFromDocument: {
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            if (!inData || inDataSize < sizeof(CFPropertyListRef)) return kAudio_ParamError;
            CFPropertyListRef plist = *reinterpret_cast<const CFPropertyListRef*>(inData);
            if (!plist || CFGetTypeID(plist) != CFDictionaryGetTypeID()) {
                return kAudioUnitErr_InvalidPropertyValue;
            }
            auto dict = reinterpret_cast<CFDictionaryRef>(plist);
            auto checkIntKey = [&](CFStringRef key, SInt32 expected) -> bool {
                CFTypeRef val = CFDictionaryGetValue(dict, key);
                if (!val || CFGetTypeID(val) != CFNumberGetTypeID()) return false;
                SInt32 v = 0;
                CFNumberGetValue(reinterpret_cast<CFNumberRef>(val), kCFNumberSInt32Type, &v);
                return v == expected;
            };
            if (!checkIntKey(CFSTR(kAUPresetVersionKey), 0) ||
                !checkIntKey(CFSTR(kAUPresetTypeKey), kPluginType) ||
                !checkIntKey(CFSTR(kAUPresetSubtypeKey), kPluginSubtype) ||
                !checkIntKey(CFSTR(kAUPresetManufacturerKey), kPluginManufacturer)) {
                return kAudioUnitErr_InvalidPropertyValue;
            }

            CFTypeRef nameVal = CFDictionaryGetValue(dict, CFSTR(kAUPresetNameKey));
            if (nameVal && CFGetTypeID(nameVal) == CFStringGetTypeID()) {
                CFRetain(nameVal);
                if (au->currentPreset.presetName) CFRelease(au->currentPreset.presetName);
                au->currentPreset.presetName = reinterpret_cast<CFStringRef>(nameVal);
                au->currentPreset.presetNumber = -1;
            }

            CFTypeRef fullVal = CFDictionaryGetValue(dict, CFSTR("ElectroPianoFullState"));
            if (fullVal && CFGetTypeID(fullVal) == CFDataGetTypeID()) {
                auto fullRef = reinterpret_cast<CFDataRef>(fullVal);
                if (CFDataGetLength(fullRef) > 8 &&
                    au->core.deserializeState(CFDataGetBytePtr(fullRef), static_cast<size_t>(CFDataGetLength(fullRef)))) {
                    return noErr;
                }
            }

            CFTypeRef dataVal = CFDictionaryGetValue(dict, CFSTR(kAUPresetDataKey));
            if (dataVal && CFGetTypeID(dataVal) == CFDataGetTypeID()) {
                auto dRef = reinterpret_cast<CFDataRef>(dataVal);
                if (CFDataGetLength(dRef) >= CFIndex(sizeof(float) * epno::kNumParams)) {
                    const auto* ptr = reinterpret_cast<const float*>(CFDataGetBytePtr(dRef));
                    for (UInt32 i = 0; i < epno::kNumParams; ++i) {
                        au->core.setParam(i, ptr[i]);
                    }
                }
            }

            CFTypeRef pathVal = CFDictionaryGetValue(dict, CFSTR("npnoPath"));
            if (pathVal && CFGetTypeID(pathVal) == CFStringGetTypeID()) {
                char buf[2048];
                if (CFStringGetCString(reinterpret_cast<CFStringRef>(pathVal), buf, sizeof(buf), kCFStringEncodingUTF8)) {
                    auto sum = au->core.getBankSummary();
                    if (sum.path != buf) {
                        au->core.loadBankAsync(buf);
                    }
                }
            }
            return noErr;
        }

        case kAudioUnitProperty_PresentPreset:
        case kAudioUnitProperty_CurrentPreset: {
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            if (!inData || inDataSize < sizeof(AUPreset)) return kAudio_ParamError;
            const auto* preset = reinterpret_cast<const AUPreset*>(inData);
            if (preset->presetNumber >= 0) {
                if (preset->presetNumber != 0) return kAudioUnitErr_InvalidPropertyValue;
                if (au->currentPreset.presetName) CFRelease(au->currentPreset.presetName);
                au->currentPreset.presetNumber = 0;
                au->currentPreset.presetName = CFSTR("Astoria Grand XL");
                CFRetain(au->currentPreset.presetName);
            } else {
                if (!preset->presetName) return kAudioUnitErr_InvalidPropertyValue;
                CFRetain(preset->presetName);
                if (au->currentPreset.presetName) CFRelease(au->currentPreset.presetName);
                au->currentPreset.presetNumber = preset->presetNumber;
                au->currentPreset.presetName = preset->presetName;
            }
            au->notifyPropertyChanged(kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0);
            au->notifyPropertyChanged(kAudioUnitProperty_CurrentPreset, kAudioUnitScope_Global, 0);
            return noErr;
        }

        case kAudioUnitProperty_RenderQuality:
            if (!inData || inDataSize < sizeof(UInt32)) return kAudio_ParamError;
            au->renderQuality = *reinterpret_cast<const UInt32*>(inData);
            return noErr;

        case kAudioUnitProperty_InPlaceProcessing:
            if (!inData || inDataSize < sizeof(UInt32)) return kAudio_ParamError;
            au->inPlaceProcessing = *reinterpret_cast<const UInt32*>(inData);
            return noErr;

        case kAudioUnitProperty_OfflineRender:
            if (!inData || inDataSize < sizeof(UInt32)) return kAudio_ParamError;
            au->offlineRender = *reinterpret_cast<const UInt32*>(inData);
            return noErr;

        case kAudioUnitProperty_ShouldAllocateBuffer:
            if (!inData || inDataSize < sizeof(UInt32)) return kAudio_ParamError;
            au->shouldAllocateBuffer = *reinterpret_cast<const UInt32*>(inData);
            return noErr;

        case kAudioUnitProperty_HostCallbacks:
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            if (!inData) {
                std::memset(&au->hostCallbacks, 0, sizeof(HostCallbackInfo));
                return noErr;
            }
            if (inDataSize < sizeof(HostCallbackInfo)) return kAudio_ParamError;
            au->hostCallbacks = *reinterpret_cast<const HostCallbackInfo*>(inData);
            return noErr;

        case kAudioUnitProperty_ContextName: {
            if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
            if (inElement != 0) return kAudioUnitErr_InvalidElement;
            if (au->contextName) {
                CFRelease(au->contextName);
                au->contextName = nullptr;
            }
            if (inData && inDataSize >= sizeof(CFStringRef)) {
                CFStringRef str = *reinterpret_cast<const CFStringRef*>(inData);
                if (str) {
                    CFRetain(str);
                    au->contextName = str;
                }
            }
            return noErr;
        }

        default: {
            UInt32 sz = 0;
            Boolean wr = false;
            OSStatus st = AU_GetPropertyInfo(inStorage, inID, inScope, inElement, &sz, &wr);
            if (st != noErr) return st;
            if (!wr) return kAudioUnitErr_PropertyNotWritable;
            return kAudioUnitErr_InvalidProperty;
        }
    }
}

static OSStatus AU_AddPropertyListener(void* inStorage,
                                       AudioUnitPropertyID inID,
                                       AudioUnitPropertyListenerProc inProc,
                                       void* inProcUserData) {
    auto* au = Self(inStorage);
    if (!au || !inProc) return kAudio_ParamError;
    std::lock_guard<std::mutex> lk(au->propMtx);
    au->propListeners.push_back({inID, inProc, inProcUserData});
    return noErr;
}

static OSStatus AU_RemovePropertyListener(void* inStorage,
                                          AudioUnitPropertyID inID,
                                          AudioUnitPropertyListenerProc inProc) {
    auto* au = Self(inStorage);
    if (!au || !inProc) return kAudio_ParamError;
    std::lock_guard<std::mutex> lk(au->propMtx);
    au->propListeners.erase(
        std::remove_if(au->propListeners.begin(), au->propListeners.end(),
                       [&](const PropListener& l) { return l.id == inID && l.proc == inProc; }),
        au->propListeners.end());
    return noErr;
}

static OSStatus AU_RemovePropertyListenerWithUserData(void* inStorage,
                                                      AudioUnitPropertyID inID,
                                                      AudioUnitPropertyListenerProc inProc,
                                                      void* inProcUserData) {
    auto* au = Self(inStorage);
    if (!au || !inProc) return kAudio_ParamError;
    std::lock_guard<std::mutex> lk(au->propMtx);
    au->propListeners.erase(
        std::remove_if(au->propListeners.begin(), au->propListeners.end(),
                       [&](const PropListener& l) {
                           return l.id == inID && l.proc == inProc && l.userData == inProcUserData;
                       }),
        au->propListeners.end());
    return noErr;
}

static OSStatus AU_AddRenderNotify(void* inStorage, AURenderCallback inProc, void* inProcUserData) {
    auto* au = Self(inStorage);
    if (!au || !inProc) return kAudio_ParamError;
    std::lock_guard<std::mutex> lk(au->propMtx);
    au->renderNotifies.push_back({inProc, inProcUserData});
    return noErr;
}

static OSStatus AU_RemoveRenderNotify(void* inStorage, AURenderCallback inProc, void* inProcUserData) {
    auto* au = Self(inStorage);
    if (!au || !inProc) return kAudio_ParamError;
    std::lock_guard<std::mutex> lk(au->propMtx);
    au->renderNotifies.erase(
        std::remove_if(au->renderNotifies.begin(), au->renderNotifies.end(),
                       [&](const RenderNotifyEntry& r) {
                           return r.proc == inProc && r.userData == inProcUserData;
                       }),
        au->renderNotifies.end());
    return noErr;
}

static OSStatus AU_GetParameter(void* inStorage,
                                AudioUnitParameterID inID,
                                AudioUnitScope inScope,
                                AudioUnitElement inElement,
                                AudioUnitParameterValue* outValue) {
    auto* au = Self(inStorage);
    if (!au || !outValue) return kAudio_ParamError;
    if (inScope == kAudioUnitScope_Group) {
        *outValue = 0.0f;
        return noErr;
    }
    if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
    if (inElement != 0) return kAudioUnitErr_InvalidElement;
    if (inID >= epno::kNumParams) return kAudioUnitErr_InvalidParameter;
    *outValue = au->core.getParam(inID);
    return noErr;
}

static OSStatus AU_SetParameter(void* inStorage,
                                AudioUnitParameterID inID,
                                AudioUnitScope inScope,
                                AudioUnitElement inElement,
                                AudioUnitParameterValue inValue,
                                UInt32 inBufferOffsetInFrames) {
    (void)inBufferOffsetInFrames;
    auto* au = Self(inStorage);
    if (!au) return kAudio_ParamError;
    if (std::isnan(inValue) || std::isinf(inValue)) return kAudioUnitErr_InvalidParameter;
    if (inScope == kAudioUnitScope_Group) {
        return noErr;
    }
    if (inScope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
    if (inElement != 0) return kAudioUnitErr_InvalidElement;
    if (inID >= epno::kNumParams) return kAudioUnitErr_InvalidParameter;
    au->core.setParam(inID, inValue);
    return noErr;
}

static OSStatus AU_ScheduleParameters(void* inStorage,
                                      const AudioUnitParameterEvent* inParameterEvent,
                                      UInt32 inNumParamEvents) {
    auto* au = Self(inStorage);
    if (!au || (!inParameterEvent && inNumParamEvents > 0)) return kAudio_ParamError;
    for (UInt32 i = 0; i < inNumParamEvents; ++i) {
        const auto& ev = inParameterEvent[i];
        float val = (ev.eventType == kParameterEvent_Immediate)
                        ? ev.eventValues.immediate.value
                        : ev.eventValues.ramp.endValue;
        AU_SetParameter(inStorage, ev.parameter, ev.scope, ev.element, val, 0);
    }
    return noErr;
}

static OSStatus AU_Render(void* inStorage,
                          AudioUnitRenderActionFlags* ioActionFlags,
                          const AudioTimeStamp* inTimeStamp,
                          UInt32 inOutputBusNumber,
                          UInt32 inNumberFrames,
                          AudioBufferList* ioData) {
    auto* au = Self(inStorage);
    if (!au || !inTimeStamp || !ioData) return kAudio_ParamError;
    if (!au->initialized) {
        au->lastRenderError = kAudioUnitErr_Uninitialized;
        return kAudioUnitErr_Uninitialized;
    }
    if (inOutputBusNumber != 0) {
        return kAudioUnitErr_InvalidElement;
    }
    if (inNumberFrames > au->maxFramesPerSlice) {
        au->lastRenderError = kAudioUnitErr_TooManyFramesToProcess;
        return kAudioUnitErr_TooManyFramesToProcess;
    }
    if (ioData->mNumberBuffers < 2) {
        return kAudio_ParamError;
    }

    AudioUnitRenderActionFlags localFlags = ioActionFlags ? *ioActionFlags : 0;

    if (!au->renderNotifies.empty()) {
        AudioUnitRenderActionFlags preFlags = localFlags | kAudioUnitRenderAction_PreRender;
        for (const auto& rn : au->renderNotifies) {
            rn.proc(rn.userData, &preFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);
        }
    }

    const UInt32 byteSize = inNumberFrames * sizeof(Float32);
    if (!ioData->mBuffers[0].mData) {
        ioData->mBuffers[0].mData = au->scratchL.data();
    }
    if (!ioData->mBuffers[1].mData) {
        ioData->mBuffers[1].mData = au->scratchR.data();
    }
    ioData->mBuffers[0].mDataByteSize = byteSize;
    ioData->mBuffers[1].mDataByteSize = byteSize;

    auto* outL = reinterpret_cast<float*>(ioData->mBuffers[0].mData);
    auto* outR = reinterpret_cast<float*>(ioData->mBuffers[1].mData);

    au->core.render(outL, outR, int(inNumberFrames));

    if (!au->renderNotifies.empty()) {
        AudioUnitRenderActionFlags postFlags = localFlags | kAudioUnitRenderAction_PostRender;
        for (const auto& rn : au->renderNotifies) {
            rn.proc(rn.userData, &postFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);
        }
    }

    return noErr;
}

// ============================================================================
// Seletores MusicDevice (MIDI / StartNote / StopNote)
// ============================================================================

static OSStatus AU_MIDIEvent(void* inStorage,
                             UInt32 inStatus,
                             UInt32 inData1,
                             UInt32 inData2,
                             UInt32 inOffsetSampleFrame) {
    (void)inOffsetSampleFrame;
    auto* au = Self(inStorage);
    if (!au) return kAudio_ParamError;
    au->core.handleMidiEvent(uint8_t(inStatus & 0xFF), uint8_t(inData1 & 0x7F), uint8_t(inData2 & 0x7F));
    return noErr;
}

static OSStatus AU_SysEx(void* inStorage, const UInt8* inData, UInt32 inLength) {
    (void)inData;
    (void)inLength;
    auto* au = Self(inStorage);
    if (!au) return kAudio_ParamError;
    return noErr;
}

static OSStatus AU_PrepareInstrument(void* inStorage, MusicDeviceInstrumentID inInstrument) {
    (void)inInstrument;
    return Self(inStorage) ? OSStatus(noErr) : OSStatus(kAudio_ParamError);
}

static OSStatus AU_ReleaseInstrument(void* inStorage, MusicDeviceInstrumentID inInstrument) {
    (void)inInstrument;
    return Self(inStorage) ? OSStatus(noErr) : OSStatus(kAudio_ParamError);
}

static OSStatus AU_StartNote(void* inStorage,
                             MusicDeviceInstrumentID inInstrument,
                             MusicDeviceGroupID inGroupID,
                             NoteInstanceID* outNoteInstanceID,
                             UInt32 inOffsetSampleFrame,
                             const MusicDeviceNoteParams* inParams) {
    (void)inInstrument;
    (void)inGroupID;
    (void)inOffsetSampleFrame;
    auto* au = Self(inStorage);
    if (!au || !inParams) return kAudio_ParamError;
    int note = std::clamp(int(std::round(inParams->mPitch)), 0, 127);
    int vel = std::clamp(int(std::round(inParams->mVelocity)), 1, 127);
    au->core.noteOn(note, uint8_t(vel));
    if (outNoteInstanceID) {
        *outNoteInstanceID = NoteInstanceID(1000 + note);
    }
    return noErr;
}

static OSStatus AU_StopNote(void* inStorage,
                            MusicDeviceGroupID inGroupID,
                            NoteInstanceID inNoteInstanceID,
                            UInt32 inOffsetSampleFrame) {
    (void)inGroupID;
    (void)inOffsetSampleFrame;
    auto* au = Self(inStorage);
    if (!au) return kAudio_ParamError;
    if (inNoteInstanceID >= 1000 && inNoteInstanceID < 1128) {
        au->core.noteOff(int(inNoteInstanceID - 1000));
    }
    return noErr;
}

static OSStatus AU_MIDIEventList(void* inStorage,
                                 UInt32 inOffsetSampleFrame,
                                 const struct MIDIEventList* evtList) {
    (void)inOffsetSampleFrame;
    auto* au = Self(inStorage);
    if (!au || !evtList) return kAudio_ParamError;
    const MIDIEventPacket* pkt = &evtList->packet[0];
    for (UInt32 i = 0; i < evtList->numPackets; ++i) {
        for (UInt32 w = 0; w < pkt->wordCount; ++w) {
            uint32_t word = pkt->words[w];
            uint8_t mt = (word >> 28) & 0x0F;
            if (mt == 0x2) { // MIDI 1.0 Channel Voice Message
                uint8_t status = (word >> 16) & 0xFF;
                uint8_t d1 = (word >> 8) & 0x7F;
                uint8_t d2 = word & 0x7F;
                au->core.handleMidiEvent(status, d1, d2);
            } else if (mt == 0x4 && w + 1 < pkt->wordCount) { // MIDI 2.0 Channel Voice Message
                uint8_t status = (word >> 16) & 0xF0;
                uint8_t note = (word >> 8) & 0x7F;
                uint32_t w2 = pkt->words[++w];
                if (status == 0x90) {
                    uint8_t vel7 = uint8_t((w2 >> 25) & 0x7F);
                    if (vel7 == 0 && (w2 >> 16) != 0) vel7 = 1;
                    au->core.noteOn(note, vel7);
                } else if (status == 0x80) {
                    au->core.noteOff(note);
                } else if (status == 0xB0) {
                    uint8_t cc = note;
                    uint8_t val7 = uint8_t((w2 >> 25) & 0x7F);
                    au->core.handleMidiEvent(0xB0, cc, val7);
                }
            }
        }
        pkt = MIDIEventPacketNext(pkt);
    }
    return noErr;
}

// ============================================================================
// AudioComponentPlugInInterface (Open / Close / Lookup)
// ============================================================================

static OSStatus AU_Open(void* self, AudioComponentInstance mInstance) {
    if (!self || !mInstance) return kAudio_ParamError;
    auto* au = Self(self);
    au->componentInstance = mInstance;
    return noErr;
}

static OSStatus AU_Close(void* self) {
    if (!self) return kAudio_ParamError;
    auto* au = Self(self);
    delete au;
    return noErr;
}

static AudioComponentMethod AU_Lookup(SInt16 selector) {
    switch (selector) {
        case kAudioUnitInitializeSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_Initialize);
        case kAudioUnitUninitializeSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_Uninitialize);
        case kAudioUnitGetPropertyInfoSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_GetPropertyInfo);
        case kAudioUnitGetPropertySelect:
            return reinterpret_cast<AudioComponentMethod>(AU_GetProperty);
        case kAudioUnitSetPropertySelect:
            return reinterpret_cast<AudioComponentMethod>(AU_SetProperty);
        case kAudioUnitAddPropertyListenerSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_AddPropertyListener);
        case kAudioUnitRemovePropertyListenerSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_RemovePropertyListener);
        case kAudioUnitRemovePropertyListenerWithUserDataSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_RemovePropertyListenerWithUserData);
        case kAudioUnitAddRenderNotifySelect:
            return reinterpret_cast<AudioComponentMethod>(AU_AddRenderNotify);
        case kAudioUnitRemoveRenderNotifySelect:
            return reinterpret_cast<AudioComponentMethod>(AU_RemoveRenderNotify);
        case kAudioUnitGetParameterSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_GetParameter);
        case kAudioUnitSetParameterSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_SetParameter);
        case kAudioUnitScheduleParametersSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_ScheduleParameters);
        case kAudioUnitRenderSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_Render);
        case kAudioUnitResetSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_Reset);

        case kMusicDeviceMIDIEventSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_MIDIEvent);
        case kMusicDeviceSysExSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_SysEx);
        case kMusicDevicePrepareInstrumentSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_PrepareInstrument);
        case kMusicDeviceReleaseInstrumentSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_ReleaseInstrument);
        case kMusicDeviceStartNoteSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_StartNote);
        case kMusicDeviceStopNoteSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_StopNote);
        case kMusicDeviceMIDIEventListSelect:
            return reinterpret_cast<AudioComponentMethod>(AU_MIDIEventList);
        default:
            return nullptr;
    }
}

}  // namespace

extern "C" __attribute__((visibility("default"))) AudioComponentPlugInInterface* ElectroPianoAUFactory(
    const AudioComponentDescription* inDesc) {
    if (!inDesc) return nullptr;
    if (inDesc->componentType != kPluginType) return nullptr;
    auto* au = new ElectroPianoAUInstance();
    au->iface.Open = AU_Open;
    au->iface.Close = AU_Close;
    au->iface.Lookup = AU_Lookup;
    au->iface.reserved = nullptr;
    return &au->iface;
}

// ============================================================================
// Fábrica da View Cocoa (<AUCocoaUIBase>) para MainStage / Logic Pro
// ============================================================================

@interface ElectroPianoAUCocoaViewFactory : NSObject <AUCocoaUIBase>
@end

@implementation ElectroPianoAUCocoaViewFactory

- (unsigned)interfaceVersion {
    return 0;
}

- (NSString*)description {
    return @"Electro Piano";
}

- (NSView*)uiViewForAudioUnit:(AudioUnit)inAudioUnit withSize:(NSSize)inPreferredSize {
    epno::ElectroPianoCore* core = nullptr;
    UInt32 dataSize = sizeof(core);
    AudioUnitGetProperty(inAudioUnit, kElectroPianoProperty_CorePtr, kAudioUnitScope_Global, 0, &core, &dataSize);
    return CreateElectroPianoPluginView(core, inPreferredSize);
}

@end
