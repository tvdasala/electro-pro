#import <Cocoa/Cocoa.h>
#import <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <string>

#include "PluginShared.hpp"

// ============================================================================
// Definições compatíveis com a ABI binária C++ COM do Steinberg VST3 SDK 3.7
// (macOS arm64 / x86_64, COM_COMPATIBLE = 0)
// ============================================================================

namespace Steinberg {

using int8 = int8_t;
using uint8 = uint8_t;
using int16 = int16_t;
using uint16 = uint16_t;
using int32 = int32_t;
using uint32 = uint32_t;
using int64 = int64_t;
using uint64 = uint64_t;
using tresult = int32;
using TBool = uint8;
using char8 = char;
using char16 = char16_t;
using FIDString = const char*;

using TUID = int8[16];

#define VST3_INLINE_UID(l1, l2, l3, l4)                                        \
    {                                                                          \
        static_cast<int8>(((uint32)(l1) & 0xFF000000) >> 24),                  \
            static_cast<int8>(((uint32)(l1) & 0x00FF0000) >> 16),              \
            static_cast<int8>(((uint32)(l1) & 0x0000FF00) >> 8),               \
            static_cast<int8>(((uint32)(l1) & 0x000000FF)),                    \
            static_cast<int8>(((uint32)(l2) & 0xFF000000) >> 24),              \
            static_cast<int8>(((uint32)(l2) & 0x00FF0000) >> 16),              \
            static_cast<int8>(((uint32)(l2) & 0x0000FF00) >> 8),               \
            static_cast<int8>(((uint32)(l2) & 0x000000FF)),                    \
            static_cast<int8>(((uint32)(l3) & 0xFF000000) >> 24),              \
            static_cast<int8>(((uint32)(l3) & 0x00FF0000) >> 16),              \
            static_cast<int8>(((uint32)(l3) & 0x0000FF00) >> 8),               \
            static_cast<int8>(((uint32)(l3) & 0x000000FF)),                    \
            static_cast<int8>(((uint32)(l4) & 0xFF000000) >> 24),              \
            static_cast<int8>(((uint32)(l4) & 0x00FF0000) >> 16),              \
            static_cast<int8>(((uint32)(l4) & 0x0000FF00) >> 8),               \
            static_cast<int8>(((uint32)(l4) & 0x000000FF))                     \
    }

enum : tresult {
    kNoInterface = -1,
    kResultOk = 0,
    kResultTrue = 0,
    kResultFalse = 1,
    kInvalidArgument = 2,
    kNotImplemented = 3,
    kInternalError = 4,
    kNotInitialized = 5,
    kOutOfMemory = 6
};

inline bool iidEqual(const TUID a, const TUID b) {
    return std::memcmp(a, b, 16) == 0;
}

inline void copyAsciiToUTF16(char16* dst, size_t maxChars, const char* src) {
    if (!dst || maxChars == 0) return;
    size_t i = 0;
    if (src) {
        while (src[i] != '\0' && i + 1 < maxChars) {
            dst[i] = static_cast<char16>(static_cast<unsigned char>(src[i]));
            ++i;
        }
    }
    dst[i] = 0;
}

class FUnknown {
public:
    virtual tresult queryInterface(const TUID _iid, void** obj) = 0;
    virtual uint32 addRef() = 0;
    virtual uint32 release() = 0;
};
static constexpr TUID kFUnknownIID = VST3_INLINE_UID(0x00000000, 0x00000000, 0xC0000000, 0x00000046);

class IBStream : public FUnknown {
public:
    enum IStreamSeekMode { kIBSeekSet = 0, kIBSeekCur, kIBSeekEnd };
    virtual tresult read(void* buffer, int32 numBytes, int32* numBytesRead) = 0;
    virtual tresult write(void* buffer, int32 numBytes, int32* numBytesWritten) = 0;
    virtual tresult seek(int64 pos, int32 mode, int64* result) = 0;
    virtual tresult tell(int64* pos) = 0;
};

class IPluginBase : public FUnknown {
public:
    virtual tresult initialize(FUnknown* context) = 0;
    virtual tresult terminate() = 0;
};
static constexpr TUID kIPluginBaseIID = VST3_INLINE_UID(0x22888DDB, 0x156E45AE, 0x8358B348, 0x08190625);

struct PFactoryInfo {
    enum FactoryFlags { kNoFlags = 0, kClassesDiscardable = 1 << 0, kLicenseCheck = 1 << 1, kComponentNonDiscardable = 1 << 3, kUnicode = 1 << 4 };
    char8 vendor[64];
    char8 url[256];
    char8 email[128];
    int32 flags;
};

struct PClassInfo {
    enum { kManyInstances = 0x7FFFFFFF };
    TUID cid;
    int32 cardinality;
    char8 category[32];
    char8 name[64];
};

struct PClassInfo2 {
    TUID cid;
    int32 cardinality;
    char8 category[32];
    char8 name[64];
    uint32 classFlags;
    char8 subCategories[128];
    char8 vendor[64];
    char8 version[64];
    char8 sdkVersion[64];
};

struct PClassInfoW {
    TUID cid;
    int32 cardinality;
    char8 category[32];
    char16 name[64];
    uint32 classFlags;
    char8 subCategories[128];
    char16 vendor[64];
    char16 version[64];
    char16 sdkVersion[64];
};

class IPluginFactory : public FUnknown {
public:
    virtual tresult getFactoryInfo(PFactoryInfo* info) = 0;
    virtual int32 countClasses() = 0;
    virtual tresult getClassInfo(int32 index, PClassInfo* info) = 0;
    virtual tresult createInstance(FIDString cid, FIDString _iid, void** obj) = 0;
};
static constexpr TUID kIPluginFactoryIID = VST3_INLINE_UID(0x7A4D811C, 0x52114A1F, 0xAED9D2EE, 0x0B43BF9F);

class IPluginFactory2 : public IPluginFactory {
public:
    virtual tresult getClassInfo2(int32 index, PClassInfo2* info) = 0;
};
static constexpr TUID kIPluginFactory2IID = VST3_INLINE_UID(0x0007B650, 0xF24B4C0B, 0xA464EDB9, 0xF00B2ABB);

class IPluginFactory3 : public IPluginFactory2 {
public:
    virtual tresult getClassInfoUnicode(int32 index, PClassInfoW* info) = 0;
    virtual tresult setHostContext(FUnknown* context) = 0;
};
static constexpr TUID kIPluginFactory3IID = VST3_INLINE_UID(0x4555A2AB, 0xC1234E57, 0x9B122910, 0x36878931);

struct ViewRect {
    int32 left = 0;
    int32 top = 0;
    int32 right = 0;
    int32 bottom = 0;
    int32 getWidth() const { return right - left; }
    int32 getHeight() const { return bottom - top; }
};

class IPlugView;

class IPlugFrame : public FUnknown {
public:
    virtual tresult resizeView(IPlugView* view, ViewRect* newSize) = 0;
};
static constexpr TUID kIPlugFrameIID = VST3_INLINE_UID(0x367FAF01, 0xAFA94693, 0x8D4DA2A0, 0xED0882A3);

class IPlugView : public FUnknown {
public:
    virtual tresult isPlatformTypeSupported(FIDString type) = 0;
    virtual tresult attached(void* parent, FIDString type) = 0;
    virtual tresult removed() = 0;
    virtual tresult onWheel(float distance) = 0;
    virtual tresult onKeyDown(char16 key, int16 keyCode, int16 modifiers) = 0;
    virtual tresult onKeyUp(char16 key, int16 keyCode, int16 modifiers) = 0;
    virtual tresult getSize(ViewRect* size) = 0;
    virtual tresult onSize(ViewRect* newSize) = 0;
    virtual tresult onFocus(TBool state) = 0;
    virtual tresult setFrame(IPlugFrame* frame) = 0;
    virtual tresult canResize() = 0;
    virtual tresult checkSizeConstraint(ViewRect* rect) = 0;
};
static constexpr TUID kIPlugViewIID = VST3_INLINE_UID(0x5BC32507, 0xD06049EA, 0xA6151B52, 0x2B755B29);

namespace Vst {

using ParamID = uint32;
using ParamValue = double;
using String128 = char16[128];
using MediaType = int32;
using BusDirection = int32;
using BusType = int32;
using IoMode = int32;
using UnitID = int32;
using ProgramListID = int32;
using SpeakerArrangement = uint64;
using Sample32 = float;
using Sample64 = double;
using TQuarterNotes = double;
using TSamples = int64;
using CtrlNumber = int16;

enum MediaTypes { kAudio = 0, kEvent = 1, kNumMediaTypes };
enum BusDirections { kInput = 0, kOutput = 1 };
enum BusTypes { kMain = 0, kAux = 1 };

namespace SpeakerArr {
constexpr SpeakerArrangement kStereo = (1ULL << 0) | (1ULL << 1);
}  // namespace SpeakerArr

struct BusInfo {
    MediaType mediaType;
    BusDirection direction;
    int32 channelCount;
    String128 name;
    BusType busType;
    uint32 flags;
    enum BusFlags { kDefaultActive = 1 << 0, kIsControlVoltage = 1 << 1 };
};

struct RoutingInfo {
    MediaType mediaType;
    int32 busIndex;
    int32 channel;
};

class IComponent : public IPluginBase {
public:
    virtual tresult getControllerClassId(TUID classId) = 0;
    virtual tresult setIoMode(IoMode mode) = 0;
    virtual int32 getBusCount(MediaType type, BusDirection dir) = 0;
    virtual tresult getBusInfo(MediaType type, BusDirection dir, int32 index, BusInfo& bus) = 0;
    virtual tresult getRoutingInfo(RoutingInfo& inInfo, RoutingInfo& outInfo) = 0;
    virtual tresult activateBus(MediaType type, BusDirection dir, int32 index, TBool state) = 0;
    virtual tresult setActive(TBool state) = 0;
    virtual tresult setState(IBStream* state) = 0;
    virtual tresult getState(IBStream* state) = 0;
};
static constexpr TUID kIComponentIID = VST3_INLINE_UID(0xE831FF31, 0xF2D54301, 0x928EBBEE, 0x25697802);

struct ProcessSetup {
    int32 processMode;
    int32 symbolicSampleSize;
    int32 maxSamplesPerBlock;
    double sampleRate;
};

enum SymbolicSampleSizes { kSample32 = 0, kSample64 = 1 };

struct AudioBusBuffers {
    int32 numChannels;
    uint64 silenceFlags;
    union {
        Sample32** channelBuffers32;
        Sample64** channelBuffers64;
    };
};

class IParamValueQueue : public FUnknown {
public:
    virtual ParamID getParameterId() = 0;
    virtual int32 getPointCount() = 0;
    virtual tresult getPoint(int32 index, int32& sampleOffset, ParamValue& value) = 0;
    virtual tresult addPoint(int32 sampleOffset, ParamValue value, int32& index) = 0;
};

class IParameterChanges : public FUnknown {
public:
    virtual int32 getParameterCount() = 0;
    virtual IParamValueQueue* getParameterData(int32 index) = 0;
    virtual IParamValueQueue* addParameterData(const ParamID& id, int32& index) = 0;
};

struct NoteOnEvent {
    int16 channel;
    int16 pitch;
    float tuning;
    float velocity;
    int32 length;
    int32 noteId;
};

struct NoteOffEvent {
    int16 channel;
    int16 pitch;
    float velocity;
    int32 noteId;
    float tuning;
};

struct DataEvent {
    uint32 size;
    uint32 type;
    const uint8* bytes;
};

struct PolyPressureEvent {
    int16 channel;
    int16 pitch;
    float pressure;
    int32 noteId;
};

struct NoteExpressionValueEvent {
    uint32 typeId;
    int32 noteId;
    double value;
};

struct ChordEvent {
    int16 root;
    int16 bassNote;
    int16 mask;
    uint16 textLen;
    const char16* text;
};

struct ScaleEvent {
    int16 root;
    int16 mask;
    uint16 textLen;
    const char16* text;
};

struct LegacyMIDICCOutEvent {
    uint8 controlNumber;
    int8 channel;
    int8 value;
    int8 value2;
};

struct Event {
    int32 busIndex;
    int32 sampleOffset;
    TQuarterNotes ppqPosition;
    uint16 flags;
    uint16 type;
    enum EventTypes {
        kNoteOnEvent = 0,
        kNoteOffEvent = 1,
        kDataEvent = 2,
        kPolyPressureEvent = 3,
        kNoteExpressionValueEvent = 4,
        kNoteExpressionTextEvent = 5,
        kChordEvent = 6,
        kScaleEvent = 7,
        kLegacyMIDICCOutEvent = 65535
    };
    union {
        NoteOnEvent noteOn;
        NoteOffEvent noteOff;
        DataEvent data;
        PolyPressureEvent polyPressure;
        NoteExpressionValueEvent noteExpressionValue;
        ChordEvent chord;
        ScaleEvent scale;
        LegacyMIDICCOutEvent midiCCOut;
    };
};

class IEventList : public FUnknown {
public:
    virtual int32 getEventCount() = 0;
    virtual tresult getEvent(int32 index, Event& e) = 0;
    virtual tresult addEvent(Event& e) = 0;
};

struct ProcessData {
    int32 processMode;
    int32 symbolicSampleSize;
    int32 numSamples;
    int32 numInputs;
    int32 numOutputs;
    AudioBusBuffers* inputs;
    AudioBusBuffers* outputs;
    IParameterChanges* inputParameterChanges;
    IParameterChanges* outputParameterChanges;
    IEventList* inputEvents;
    IEventList* outputEvents;
    void* processContext;
};

class IAudioProcessor : public FUnknown {
public:
    virtual tresult setBusArrangements(SpeakerArrangement* inputs, int32 numIns,
                                       SpeakerArrangement* outputs, int32 numOuts) = 0;
    virtual tresult getBusArrangement(BusDirection dir, int32 index, SpeakerArrangement& arr) = 0;
    virtual tresult canProcessSampleSize(int32 symbolicSampleSize) = 0;
    virtual uint32 getLatencySamples() = 0;
    virtual tresult setupProcessing(ProcessSetup& setup) = 0;
    virtual tresult setProcessing(TBool state) = 0;
    virtual tresult process(ProcessData& data) = 0;
    virtual uint32 getTailSamples() = 0;
};
static constexpr TUID kIAudioProcessorIID = VST3_INLINE_UID(0x42043F99, 0xB7DA453C, 0xA569E79D, 0x9AAEC33D);

struct ParameterInfo {
    ParamID id;
    String128 title;
    String128 shortTitle;
    String128 units;
    int32 stepCount;
    ParamValue defaultNormalizedValue;
    UnitID unitId;
    int32 flags;
    enum ParameterFlags {
        kNoFlags = 0,
        kCanAutomate = 1 << 0,
        kIsReadOnly = 1 << 1,
        kIsWrapAround = 1 << 2,
        kIsList = 1 << 3,
        kIsHidden = 1 << 4,
        kIsProgramChange = 1 << 15,
        kIsBypass = 1 << 16
    };
};

class IComponentHandler : public FUnknown {
public:
    virtual tresult beginEdit(ParamID id) = 0;
    virtual tresult performEdit(ParamID id, ParamValue valueNormalized) = 0;
    virtual tresult endEdit(ParamID id) = 0;
    virtual tresult restartComponent(int32 flags) = 0;
};

class IEditController : public IPluginBase {
public:
    virtual tresult setComponentState(IBStream* state) = 0;
    virtual tresult setState(IBStream* state) = 0;
    virtual tresult getState(IBStream* state) = 0;
    virtual int32 getParameterCount() = 0;
    virtual tresult getParameterInfo(int32 paramIndex, ParameterInfo& info) = 0;
    virtual tresult getParamStringByValue(ParamID id, ParamValue valueNormalized, String128 string) = 0;
    virtual tresult getParamValueByString(ParamID id, char16* string, ParamValue& valueNormalized) = 0;
    virtual ParamValue normalizedParamToPlain(ParamID id, ParamValue valueNormalized) = 0;
    virtual ParamValue plainParamToNormalized(ParamID id, ParamValue plainValue) = 0;
    virtual ParamValue getParamNormalized(ParamID id) = 0;
    virtual tresult setParamNormalized(ParamID id, ParamValue value) = 0;
    virtual tresult setComponentHandler(IComponentHandler* handler) = 0;
    virtual IPlugView* createView(FIDString name) = 0;
};
static constexpr TUID kIEditControllerIID = VST3_INLINE_UID(0xDCD7BBE3, 0x7742448D, 0xA874AACC, 0x979C759E);

class IMidiMapping : public FUnknown {
public:
    virtual tresult getMidiControllerAssignment(int32 busIndex, int16 channel,
                                                CtrlNumber midiControllerNumber, ParamID& id) = 0;
};
static constexpr TUID kIMidiMappingIID = VST3_INLINE_UID(0xDF0FF9F7, 0x49B74669, 0xB63AB732, 0x7ADBF5E5);

class IMessage;

class IConnectionPoint : public FUnknown {
public:
    virtual tresult connect(IConnectionPoint* other) = 0;
    virtual tresult disconnect(IConnectionPoint* other) = 0;
    virtual tresult notify(IMessage* message) = 0;
};
static constexpr TUID kIConnectionPointIID = VST3_INLINE_UID(0x70A4156F, 0x6E6E4026, 0x989148BF, 0xAA60D8D1);

}  // namespace Vst
}  // namespace Steinberg

// ============================================================================
// Implementação da View VST3 (IPlugView para macOS "NSView")
// ============================================================================

namespace {

using namespace Steinberg;
using namespace Steinberg::Vst;

static constexpr TUID kElectroPianoProcessorCID =
    VST3_INLINE_UID(0x456C5072, 0x45706E6F, 0x50726F63, 0x00010100);

class ElectroPianoVST3View final : public IPlugView {
public:
    explicit ElectroPianoVST3View(epno::ElectroPianoCore* core) : core_(core) {
        double savedScale = [[NSUserDefaults standardUserDefaults] doubleForKey:@"ElectroPiano_PluginUIScale_v1"];
        double sc = (savedScale >= 0.70 && savedScale <= 1.60) ? savedScale : 1.0;
        width_ = (int32)std::lround(1140.0 * sc);
        height_ = (int32)std::lround(650.0 * sc);
    }

    ~ElectroPianoVST3View() {
        if (frameObs_) {
            [[NSNotificationCenter defaultCenter] removeObserver:frameObs_];
            frameObs_ = nil;
        }
        if (nsView_) {
            [nsView_ removeFromSuperview];
            nsView_ = nil;
        }
    }

    tresult queryInterface(const TUID _iid, void** obj) override {
        if (!obj) return kInvalidArgument;
        if (iidEqual(_iid, kFUnknownIID) || iidEqual(_iid, kIPlugViewIID)) {
            addRef();
            *obj = static_cast<IPlugView*>(this);
            return kResultTrue;
        }
        *obj = nullptr;
        return kNoInterface;
    }

    uint32 addRef() override { return ++refCount_; }
    uint32 release() override {
        uint32 r = --refCount_;
        if (r == 0) delete this;
        return r;
    }

    tresult isPlatformTypeSupported(FIDString type) override {
        if (type && std::strcmp(type, "NSView") == 0) return kResultTrue;
        return kResultFalse;
    }

    tresult attached(void* parent, FIDString type) override {
        if (!parent || !type || std::strcmp(type, "NSView") != 0) return kInvalidArgument;
        NSView* parentView = (__bridge NSView*)parent;
        if (!nsView_) {
            nsView_ = CreateElectroPianoPluginView(core_, NSMakeSize(width_, height_));
        }
        width_ = std::max<int32>(760, (int32)std::lround(nsView_.frame.size.width));
        height_ = std::max<int32>(430, (int32)std::lround(nsView_.frame.size.height));
        [nsView_ setFrame:NSMakeRect(0, 0, width_, height_)];
        [parentView addSubview:nsView_];

        if (frameObs_) {
            [[NSNotificationCenter defaultCenter] removeObserver:frameObs_];
            frameObs_ = nil;
        }
        frameObs_ = [[NSNotificationCenter defaultCenter]
            addObserverForName:NSViewFrameDidChangeNotification
                        object:nsView_
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:[this](NSNotification* _Nonnull) {
                        if (!nsView_ || inResizeCallback_) return;
                        int32 nw = std::max<int32>(760, (int32)std::lround(nsView_.frame.size.width));
                        int32 nh = std::max<int32>(430, (int32)std::lround(nsView_.frame.size.height));
                        if (nw != width_ || nh != height_) {
                            width_ = nw;
                            height_ = nh;
                            if (frame_) {
                                inResizeCallback_ = true;
                                ViewRect vr{0, 0, width_, height_};
                                frame_->resizeView(this, &vr);
                                inResizeCallback_ = false;
                            }
                        }
                    }];
        return kResultTrue;
    }

    tresult removed() override {
        if (frameObs_) {
            [[NSNotificationCenter defaultCenter] removeObserver:frameObs_];
            frameObs_ = nil;
        }
        if (nsView_) {
            [nsView_ removeFromSuperview];
            nsView_ = nil;
        }
        return kResultTrue;
    }

    tresult onWheel(float) override { return kResultFalse; }
    tresult onKeyDown(char16, int16, int16) override { return kResultFalse; }
    tresult onKeyUp(char16, int16, int16) override { return kResultFalse; }

    tresult getSize(ViewRect* size) override {
        if (!size) return kInvalidArgument;
        size->left = 0;
        size->top = 0;
        size->right = width_;
        size->bottom = height_;
        return kResultTrue;
    }

    tresult onSize(ViewRect* newSize) override {
        if (!newSize) return kInvalidArgument;
        width_ = std::max<int32>(760, newSize->getWidth());
        height_ = std::max<int32>(430, newSize->getHeight());
        if (nsView_ && !inResizeCallback_) {
            inResizeCallback_ = true;
            [nsView_ setFrameSize:NSMakeSize(width_, height_)];
            inResizeCallback_ = false;
        }
        return kResultTrue;
    }

    tresult onFocus(TBool) override { return kResultTrue; }
    tresult setFrame(IPlugFrame* frame) override {
        frame_ = frame;
        return kResultTrue;
    }
    tresult canResize() override { return kResultFalse; }
    tresult checkSizeConstraint(ViewRect* rect) override {
        if (!rect) return kInvalidArgument;
        rect->right = rect->left + width_;
        rect->bottom = rect->top + height_;
        return kResultTrue;
    }

private:
    std::atomic<uint32> refCount_{1};
    epno::ElectroPianoCore* core_ = nullptr;
    NSView* nsView_ = nil;
    id frameObs_ = nil;
    bool inResizeCallback_ = false;
    IPlugFrame* frame_ = nullptr;
    int32 width_ = 1140;
    int32 height_ = 650;
};

// ============================================================================
// Componente Unificado VST3 (IComponent + IAudioProcessor + IEditController)
// ============================================================================

class ElectroPianoVST3Plugin final : public IComponent,
                                     public IAudioProcessor,
                                     public IEditController,
                                     public IMidiMapping,
                                     public IConnectionPoint {
public:
    ElectroPianoVST3Plugin() = default;
    ~ElectroPianoVST3Plugin() = default;

    // --- FUnknown ---
    tresult queryInterface(const TUID _iid, void** obj) override {
        if (!obj) return kInvalidArgument;
        if (iidEqual(_iid, kFUnknownIID) ||
            iidEqual(_iid, kIPluginBaseIID) ||
            iidEqual(_iid, kIComponentIID)) {
            addRef();
            *obj = static_cast<IComponent*>(this);
            return kResultTrue;
        }
        if (iidEqual(_iid, kIAudioProcessorIID)) {
            addRef();
            *obj = static_cast<IAudioProcessor*>(this);
            return kResultTrue;
        }
        if (iidEqual(_iid, kIEditControllerIID)) {
            addRef();
            *obj = static_cast<IEditController*>(this);
            return kResultTrue;
        }
        if (iidEqual(_iid, kIMidiMappingIID)) {
            addRef();
            *obj = static_cast<IMidiMapping*>(this);
            return kResultTrue;
        }
        if (iidEqual(_iid, kIConnectionPointIID)) {
            addRef();
            *obj = static_cast<IConnectionPoint*>(this);
            return kResultTrue;
        }
        *obj = nullptr;
        return kNoInterface;
    }

    uint32 addRef() override { return ++refCount_; }
    uint32 release() override {
        uint32 r = --refCount_;
        if (r == 0) delete this;
        return r;
    }

    // --- IPluginBase ---
    tresult initialize(FUnknown*) override {
        if (initialized_) return kResultTrue;
        initialized_ = true;
        return kResultTrue;
    }

    tresult terminate() override {
        core_.setParamChangeCallback(nullptr);
        componentHandler_ = nullptr;
        initialized_ = false;
        return kResultTrue;
    }

    // --- IComponent ---
    tresult getControllerClassId(TUID) override {
        // Unificado (SingleComponentEffect): o próprio IComponent implementa IEditController.
        return kNoInterface;
    }

    tresult setIoMode(IoMode) override { return kResultTrue; }

    int32 getBusCount(MediaType type, BusDirection dir) override {
        if (type == kAudio && dir == kOutput) return 1;
        if (type == kEvent && dir == kInput) return 1;
        return 0;
    }

    tresult getBusInfo(MediaType type, BusDirection dir, int32 index, BusInfo& bus) override {
        if (index != 0) return kInvalidArgument;
        std::memset(&bus, 0, sizeof(BusInfo));
        if (type == kAudio && dir == kOutput) {
            bus.mediaType = kAudio;
            bus.direction = kOutput;
            bus.channelCount = 2;
            copyAsciiToUTF16(bus.name, 128, "Stereo Out");
            bus.busType = kMain;
            bus.flags = BusInfo::kDefaultActive;
            return kResultTrue;
        }
        if (type == kEvent && dir == kInput) {
            bus.mediaType = kEvent;
            bus.direction = kInput;
            bus.channelCount = 16;
            copyAsciiToUTF16(bus.name, 128, "MIDI In");
            bus.busType = kMain;
            bus.flags = BusInfo::kDefaultActive;
            return kResultTrue;
        }
        return kInvalidArgument;
    }

    tresult getRoutingInfo(RoutingInfo&, RoutingInfo&) override { return kNotImplemented; }

    tresult activateBus(MediaType type, BusDirection dir, int32 index, TBool state) override {
        if (index != 0) return kInvalidArgument;
        if (type == kAudio && dir == kOutput) {
            audioOutActive_ = (state != 0);
            return kResultTrue;
        }
        if (type == kEvent && dir == kInput) {
            eventInActive_ = (state != 0);
            return kResultTrue;
        }
        return kInvalidArgument;
    }

    tresult setActive(TBool state) override {
        if (!state) {
            core_.panic();
        }
        return kResultTrue;
    }

    tresult setState(IBStream* state) override {
        if (!state) return kInvalidArgument;
        uint32 firstWord = 0;
        int32 bytesRead = 0;
        if (state->read(&firstWord, sizeof(firstWord), &bytesRead) != kResultTrue || bytesRead != sizeof(firstWord)) {
            return kResultTrue;
        }
        // Formato completo v2: firstWord = tamanho do blob 'EPST'
        if (firstWord > 8 && firstWord < 1024 * 1024 && firstWord != 0x45504E4F) {
            std::vector<uint8_t> blob(firstWord);
            if (state->read(blob.data(), static_cast<int32>(firstWord), &bytesRead) == kResultTrue &&
                bytesRead == static_cast<int32>(firstWord)) {
                core_.deserializeState(blob.data(), blob.size());
            }
            return kResultTrue;
        }
        if (firstWord != 0x45504E4F) { // 'EPNO' (legado v1)
            return kResultFalse;
        }
        for (uint32 i = 0; i < epno::kNumParams; ++i) {
            float val = 0.0f;
            if (state->read(&val, sizeof(val), &bytesRead) == kResultTrue && bytesRead == sizeof(val)) {
                core_.setParam(i, val);
            }
        }
        uint32 pathLen = 0;
        if (state->read(&pathLen, sizeof(pathLen), &bytesRead) == kResultTrue &&
            bytesRead == sizeof(pathLen) && pathLen > 0 && pathLen < 4096) {
            std::string path(pathLen, '\0');
            if (state->read(path.data(), static_cast<int32>(pathLen), &bytesRead) == kResultTrue &&
                bytesRead == static_cast<int32>(pathLen)) {
                auto current = core_.getBankSummary();
                if (current.path != path) {
                    core_.loadBankAsync(path);
                }
            }
        }
        return kResultTrue;
    }

    tresult getState(IBStream* state) override {
        if (!state) return kInvalidArgument;
        auto blob = core_.serializeState();
        uint32 blobSize = static_cast<uint32>(blob.size());
        int32 written = 0;
        state->write(&blobSize, sizeof(blobSize), &written);
        if (blobSize > 0) {
            state->write(blob.data(), static_cast<int32>(blobSize), &written);
        }
        return kResultTrue;
    }

    // --- IAudioProcessor ---
    tresult setBusArrangements(SpeakerArrangement* inputs, int32 numIns,
                               SpeakerArrangement* outputs, int32 numOuts) override {
        if (numIns != 0 || numOuts != 1 || !outputs) return kResultFalse;
        if (outputs[0] != SpeakerArr::kStereo) return kResultFalse;
        return kResultTrue;
    }

    tresult getBusArrangement(BusDirection dir, int32 index, SpeakerArrangement& arr) override {
        if (dir == kOutput && index == 0) {
            arr = SpeakerArr::kStereo;
            return kResultTrue;
        }
        return kInvalidArgument;
    }

    tresult canProcessSampleSize(int32 symbolicSampleSize) override {
        return (symbolicSampleSize == kSample32) ? kResultTrue : kResultFalse;
    }

    uint32 getLatencySamples() override { return 0; }

    tresult setupProcessing(ProcessSetup& setup) override {
        if (setup.sampleRate > 0.0) {
            core_.setSampleRate(setup.sampleRate);
        }
        return kResultTrue;
    }

    tresult setProcessing(TBool state) override {
        if (!state) {
            core_.panic();
        }
        return kResultTrue;
    }

    tresult process(ProcessData& data) override {
        // 1. Mudanças de parâmetros vindas do host
        if (data.inputParameterChanges) {
            int32 numParamsChanged = data.inputParameterChanges->getParameterCount();
            for (int32 i = 0; i < numParamsChanged; ++i) {
                if (IParamValueQueue* queue = data.inputParameterChanges->getParameterData(i)) {
                    ParamID pid = queue->getParameterId();
                    int32 numPoints = queue->getPointCount();
                    if (numPoints > 0 && pid < epno::kNumParams) {
                        int32 sampleOffset = 0;
                        ParamValue val = 0.0;
                        if (queue->getPoint(numPoints - 1, sampleOffset, val) == kResultTrue) {
                            core_.setParamNormalized(pid, static_cast<float>(val));
                        }
                    }
                }
            }
        }

        // 2. Eventos MIDI / NoteOn / NoteOff
        if (data.inputEvents) {
            int32 eventCount = data.inputEvents->getEventCount();
            for (int32 i = 0; i < eventCount; ++i) {
                Event ev{};
                if (data.inputEvents->getEvent(i, ev) == kResultTrue) {
                    if (ev.type == Event::kNoteOnEvent) {
                        int pitch = ev.noteOn.pitch;
                        int vel = static_cast<int>( std::lround(ev.noteOn.velocity * 127.0f) );
                        if (vel <= 0) {
                            core_.noteOff(pitch);
                        } else {
                            core_.noteOn(pitch, static_cast<uint8_t>(std::clamp(vel, 1, 127)));
                        }
                    } else if (ev.type == Event::kNoteOffEvent) {
                        core_.noteOff(ev.noteOff.pitch);
                    } else if (ev.type == Event::kLegacyMIDICCOutEvent) {
                        if (ev.midiCCOut.controlNumber == 64) {
                            core_.setSustain(ev.midiCCOut.value >= 64);
                        }
                    }
                }
            }
        }

        // 3. Renderização de áudio estéreo
        if (data.numSamples <= 0 || data.numOutputs <= 0 || !data.outputs) {
            return kResultTrue;
        }

        AudioBusBuffers& outBus = data.outputs[0];
        if (outBus.numChannels < 2 || !outBus.channelBuffers32) {
            return kResultTrue;
        }

        float* outL = outBus.channelBuffers32[0];
        float* outR = outBus.channelBuffers32[1];
        if (!outL || !outR) {
            return kResultTrue;
        }

        core_.render(outL, outR, data.numSamples);
        outBus.silenceFlags = 0;
        return kResultTrue;
    }

    uint32 getTailSamples() override {
        return 44100 * 10; // Cauda de ressonância / release do piano
    }

    // --- IEditController ---
    tresult setComponentState(IBStream* state) override {
        return setState(state);
    }

    int32 getParameterCount() override {
        return static_cast<int32>(epno::kNumParams);
    }

    tresult getParameterInfo(int32 paramIndex, ParameterInfo& info) override {
        if (paramIndex < 0 || paramIndex >= static_cast<int32>(epno::kNumParams)) {
            return kInvalidArgument;
        }
        const auto& spec = epno::kParamSpecs[paramIndex];
        std::memset(&info, 0, sizeof(ParameterInfo));
        info.id = spec.id;
        copyAsciiToUTF16(info.title, 128, spec.name);
        copyAsciiToUTF16(info.shortTitle, 128, spec.name);
        copyAsciiToUTF16(info.units, 128, spec.unitLabel);
        info.stepCount = spec.isStepped ? static_cast<int32>(spec.maxVal - spec.minVal) : 0;
        info.defaultNormalizedValue = epno::ElectroPianoCore::plainToNormalized(spec.id, spec.defaultVal);
        info.unitId = 0;
        info.flags = ParameterInfo::kCanAutomate;
        return kResultTrue;
    }

    tresult getParamStringByValue(ParamID id, ParamValue valueNormalized, String128 string) override {
        if (id >= epno::kNumParams) return kInvalidArgument;
        float plain = epno::ElectroPianoCore::normalizedToPlain(id, static_cast<float>(valueNormalized));
        char buf[64];
        switch (id) {
            case epno::kParamMasterGainDb:
            case epno::kParamEqBassDb:
            case epno::kParamEqMidDb:
            case epno::kParamEqTrebleDb:
                std::snprintf(buf, sizeof(buf), "%+.1f", plain);
                break;
            case epno::kParamVelocityCurve: {
                int idx = static_cast<int>(std::lround(plain));
                const char* label = (idx <= 0) ? "Leve" : (idx == 1 ? "Normal" : "Pesada");
                std::snprintf(buf, sizeof(buf), "%s", label);
                break;
            }
            case epno::kParamTranspose:
                std::snprintf(buf, sizeof(buf), "%+d", static_cast<int>(std::lround(plain)));
                break;
            case epno::kParamTuningHz:
            case epno::kParamEqMidFreqHz:
                std::snprintf(buf, sizeof(buf), "%.0f", plain);
                break;
            case epno::kParamReleaseSamples:
            case epno::kParamReleaseTime:
                std::snprintf(buf, sizeof(buf), "%.0f%%", plain);
                break;
            case epno::kParamSustainPedal:
                std::snprintf(buf, sizeof(buf), "%s", plain >= 0.5f ? "Ligado" : "Desligado");
                break;
            default:
                std::snprintf(buf, sizeof(buf), "%.2f", plain);
                break;
        }
        copyAsciiToUTF16(string, 128, buf);
        return kResultTrue;
    }

    tresult getParamValueByString(ParamID, char16*, ParamValue&) override {
        return kNotImplemented;
    }

    ParamValue normalizedParamToPlain(ParamID id, ParamValue valueNormalized) override {
        return epno::ElectroPianoCore::normalizedToPlain(id, static_cast<float>(valueNormalized));
    }

    ParamValue plainParamToNormalized(ParamID id, ParamValue plainValue) override {
        return epno::ElectroPianoCore::plainToNormalized(id, static_cast<float>(plainValue));
    }

    ParamValue getParamNormalized(ParamID id) override {
        return core_.getParamNormalized(id);
    }

    tresult setParamNormalized(ParamID id, ParamValue value) override {
        if (id >= epno::kNumParams) return kInvalidArgument;
        core_.setParamNormalized(id, static_cast<float>(value));
        return kResultTrue;
    }

    tresult setComponentHandler(IComponentHandler* handler) override {
        componentHandler_ = handler;
        if (handler) {
            core_.setParamChangeCallback([this](uint32_t id, float norm) {
                if (componentHandler_) {
                    componentHandler_->beginEdit(id);
                    componentHandler_->performEdit(id, norm);
                    componentHandler_->endEdit(id);
                }
            });
        } else {
            core_.setParamChangeCallback(nullptr);
        }
        return kResultTrue;
    }

    IPlugView* createView(FIDString name) override {
        if (name && std::strcmp(name, "editor") == 0) {
            return new ElectroPianoVST3View(&core_);
        }
        return nullptr;
    }

    // --- IMidiMapping ---
    tresult getMidiControllerAssignment(int32 busIndex, int16 channel,
                                        CtrlNumber midiControllerNumber, ParamID& id) override {
        if (busIndex == 0 && (channel >= 0 && channel < 16)) {
            if (midiControllerNumber == 64) { // CC64 Damper / Sustain Pedal
                id = epno::kParamSustainPedal;
                return kResultTrue;
            }
        }
        return kResultFalse;
    }

    // --- IConnectionPoint ---
    tresult connect(IConnectionPoint* other) override {
        return other ? kResultTrue : kInvalidArgument;
    }
    tresult disconnect(IConnectionPoint*) override { return kResultTrue; }
    tresult notify(IMessage*) override { return kResultTrue; }

private:
    std::atomic<uint32> refCount_{1};
    bool initialized_ = false;
    bool audioOutActive_ = true;
    bool eventInActive_ = true;
    IComponentHandler* componentHandler_ = nullptr;
    epno::ElectroPianoCore core_;
};

// ============================================================================
// Factory VST3 (IPluginFactory3)
// ============================================================================

class ElectroPianoVST3Factory final : public IPluginFactory3 {
public:
    ElectroPianoVST3Factory() = default;
    ~ElectroPianoVST3Factory() = default;

    tresult queryInterface(const TUID _iid, void** obj) override {
        if (!obj) return kInvalidArgument;
        if (iidEqual(_iid, kFUnknownIID) ||
            iidEqual(_iid, kIPluginFactoryIID) ||
            iidEqual(_iid, kIPluginFactory2IID) ||
            iidEqual(_iid, kIPluginFactory3IID)) {
            addRef();
            *obj = static_cast<IPluginFactory3*>(this);
            return kResultTrue;
        }
        *obj = nullptr;
        return kNoInterface;
    }

    uint32 addRef() override { return ++refCount_; }
    uint32 release() override {
        uint32 r = --refCount_;
        return r;
    }

    tresult getFactoryInfo(PFactoryInfo* info) override {
        if (!info) return kInvalidArgument;
        std::memset(info, 0, sizeof(PFactoryInfo));
        std::snprintf(info->vendor, sizeof(info->vendor), "Electro Pro");
        std::snprintf(info->url, sizeof(info->url), "https://electropro.local");
        std::snprintf(info->email, sizeof(info->email), "support@electropro.local");
        info->flags = PFactoryInfo::kUnicode;
        return kResultTrue;
    }

    int32 countClasses() override { return 1; }

    tresult getClassInfo(int32 index, PClassInfo* info) override {
        if (index != 0 || !info) return kInvalidArgument;
        std::memset(info, 0, sizeof(PClassInfo));
        std::memcpy(info->cid, kElectroPianoProcessorCID, sizeof(TUID));
        info->cardinality = PClassInfo::kManyInstances;
        std::snprintf(info->category, sizeof(info->category), "Audio Module Class");
        std::snprintf(info->name, sizeof(info->name), "Electro Piano");
        return kResultTrue;
    }

    tresult getClassInfo2(int32 index, PClassInfo2* info) override {
        if (index != 0 || !info) return kInvalidArgument;
        std::memset(info, 0, sizeof(PClassInfo2));
        std::memcpy(info->cid, kElectroPianoProcessorCID, sizeof(TUID));
        info->cardinality = PClassInfo::kManyInstances;
        std::snprintf(info->category, sizeof(info->category), "Audio Module Class");
        std::snprintf(info->name, sizeof(info->name), "Electro Piano");
        info->classFlags = 0;
        std::snprintf(info->subCategories, sizeof(info->subCategories), "Instrument|Piano");
        std::snprintf(info->vendor, sizeof(info->vendor), "Electro Pro");
        std::snprintf(info->version, sizeof(info->version), "1.0.0");
        std::snprintf(info->sdkVersion, sizeof(info->sdkVersion), "VST 3.7.8");
        return kResultTrue;
    }

    tresult getClassInfoUnicode(int32 index, PClassInfoW* info) override {
        if (index != 0 || !info) return kInvalidArgument;
        std::memset(info, 0, sizeof(PClassInfoW));
        std::memcpy(info->cid, kElectroPianoProcessorCID, sizeof(TUID));
        info->cardinality = PClassInfo::kManyInstances;
        std::snprintf(info->category, sizeof(info->category), "Audio Module Class");
        copyAsciiToUTF16(info->name, 64, "Electro Piano");
        info->classFlags = 0;
        std::snprintf(info->subCategories, sizeof(info->subCategories), "Instrument|Piano");
        copyAsciiToUTF16(info->vendor, 64, "Electro Pro");
        copyAsciiToUTF16(info->version, 64, "1.0.0");
        copyAsciiToUTF16(info->sdkVersion, 64, "VST 3.7.8");
        return kResultTrue;
    }

    tresult setHostContext(FUnknown*) override { return kResultTrue; }

    tresult createInstance(FIDString cid, FIDString _iid, void** obj) override {
        if (!cid || !_iid || !obj) return kInvalidArgument;
        if (iidEqual(reinterpret_cast<const int8*>(cid), kElectroPianoProcessorCID)) {
            auto* plugin = new ElectroPianoVST3Plugin();
            tresult res = plugin->queryInterface(reinterpret_cast<const int8*>(_iid), obj);
            plugin->release();
            return res;
        }
        *obj = nullptr;
        return kNoInterface;
    }

private:
    std::atomic<uint32> refCount_{1};
};

}  // namespace

// ============================================================================
// Símbolos exportados do bundle macOS .vst3
// ============================================================================

extern "C" __attribute__((visibility("default"))) bool bundleEntry(CFBundleRef) {
    return true;
}

extern "C" __attribute__((visibility("default"))) bool bundleExit(void) {
    return true;
}

extern "C" __attribute__((visibility("default"))) Steinberg::IPluginFactory* GetPluginFactory(void) {
    static ElectroPianoVST3Factory sFactory;
    sFactory.addRef();
    return &sFactory;
}
