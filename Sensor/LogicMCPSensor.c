// LogicMCPSensor — transparent AUv2 audio effect that meters the signal at its
// insert point and publishes compact feature frames to a memory-mapped ring
// buffer that the Logic MCP server reads from outside the host process.
//
// Realtime rules honored in the render path: no locks, no allocation, no file
// I/O (the ring is mmapped and pre-touched at initialize time), no logging.

#include <AudioToolbox/AudioToolbox.h>
#include <AudioUnit/AudioUnit.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <uuid/uuid.h>

#define SENSOR_MAGIC "LMCPSNS1"
#define SENSOR_VERSION 1
#define SENSOR_FRAME_CAPACITY 2048
#define SENSOR_MAX_CHANNELS 2
#define SENSOR_FRAMES_PER_SECOND 10
#define SENSOR_MAX_NOTIFIES 8
#define SENSOR_MAX_LISTENERS 32

typedef struct {
    uint64_t sequence;       // 1-based publish counter
    double unixTime;         // CLOCK_REALTIME seconds at frame emit
    double sampleRate;
    uint32_t channels;
    uint32_t sampleCount;    // samples aggregated into this frame
    float peak[SENSOR_MAX_CHANNELS];
    float rms[SENSOR_MAX_CHANNELS];
    double beat;             // host beat position, -1 when unavailable
    double tempo;            // host tempo, -1 when unavailable
    uint32_t transport;      // 0 stopped, 1 playing, 2 unknown
    uint32_t bypassed;
    uint64_t audioSampleCursor; // audio ring write cursor at frame emit
} SensorFrame;

typedef struct {
    char magic[8];
    uint32_t version;
    uint32_t frameBytes;
    uint32_t frameCapacity;
    uint32_t reserved;
    char instanceID[40];
    _Atomic uint64_t writeCursor; // frames published so far
    uint8_t pad[56];
} SensorHeader;

// Rolling raw-audio ring ("black box"): interleaved float32 sample frames so
// an AI client can listen to any recent window, not just read numbers.
typedef struct {
    char magic[8];       // "LMCPAUD1"
    uint32_t version;
    uint32_t channels;
    double sampleRate;
    uint64_t capacityFrames;      // ring capacity in sample frames
    _Atomic uint64_t writeCursor; // total sample frames written
    uint8_t pad[24];
} AudioRingHeader;

#define AUDIO_RING_SECONDS 45

// The reader parses these layouts by offset from another process; lock them.
_Static_assert(sizeof(SensorFrame) == 80, "SensorFrame layout changed");
_Static_assert(sizeof(SensorHeader) == 128, "SensorHeader layout changed");
_Static_assert(offsetof(SensorHeader, writeCursor) == 64, "writeCursor offset changed");
_Static_assert(offsetof(SensorFrame, beat) == 48, "beat offset changed");
_Static_assert(offsetof(SensorFrame, audioSampleCursor) == 72, "audioSampleCursor offset changed");
_Static_assert(sizeof(AudioRingHeader) == 64, "AudioRingHeader layout changed");
_Static_assert(offsetof(AudioRingHeader, writeCursor) == 32, "audio writeCursor offset changed");

typedef struct {
    AudioComponentPlugInInterface interface;

    int initialized;
    AudioStreamBasicDescription inputFormat;
    AudioStreamBasicDescription outputFormat;
    UInt32 maxFramesPerSlice;
    UInt32 bypassed;
    AURenderCallbackStruct inputCallback;
    AudioUnitConnection connection;
    HostCallbackInfo hostCallbacks;
    AudioComponentInstance instance;
    AUPreset presentPreset;

    AURenderCallback notifyProcs[SENSOR_MAX_NOTIFIES];
    void *notifyRefCons[SENSOR_MAX_NOTIFIES];

    struct {
        AudioUnitPropertyID property;
        AudioUnitPropertyListenerProc proc;
        void *userData;
    } listeners[SENSOR_MAX_LISTENERS];

    float *scratch; // maxFrames * channels, used when the host passes no buffers
    UInt32 scratchCapacity;

    // Ring buffers
    SensorHeader *ring; // mmapped; frames follow the header
    size_t ringBytes;
    char ringPath[1024];
    AudioRingHeader *audioRing; // mmapped; interleaved float32 frames follow
    size_t audioRingBytes;
    char audioRingPath[1024];
    uint32_t audioChannels;

    // Aggregation state (render thread only)
    double sumSquares[SENSOR_MAX_CHANNELS];
    float windowPeak[SENSOR_MAX_CHANNELS];
    uint32_t windowSamples;
    uint32_t samplesPerFrame;
    uint64_t sequence;
} SensorAU;

static void sensorNotifyListeners(SensorAU *au, AudioUnitPropertyID property,
                                  AudioUnitScope scope, AudioUnitElement element);
static void sensorCloseRing(SensorAU *au);

// MARK: - Ring buffer

static void sensorEmitFrame(SensorAU *au) {
    if (!au->ring || au->windowSamples == 0) {
        return;
    }
    SensorFrame frame;
    memset(&frame, 0, sizeof(frame));
    frame.sequence = ++au->sequence;
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    frame.unixTime = (double)now.tv_sec + (double)now.tv_nsec / 1e9;
    frame.sampleRate = au->outputFormat.mSampleRate;
    uint32_t channels = au->outputFormat.mChannelsPerFrame;
    if (channels > SENSOR_MAX_CHANNELS) channels = SENSOR_MAX_CHANNELS;
    frame.channels = channels;
    frame.sampleCount = au->windowSamples;
    for (uint32_t channel = 0; channel < channels; channel++) {
        frame.peak[channel] = au->windowPeak[channel];
        frame.rms[channel] = (float)sqrt(au->sumSquares[channel] / (double)au->windowSamples);
    }
    frame.beat = -1;
    frame.tempo = -1;
    frame.transport = 2;
    frame.bypassed = au->bypassed;
    frame.audioSampleCursor = au->audioRing
        ? atomic_load_explicit(&au->audioRing->writeCursor, memory_order_relaxed)
        : 0;
    if (au->hostCallbacks.beatAndTempoProc) {
        Float64 beat = 0, tempo = 0;
        if (au->hostCallbacks.beatAndTempoProc(au->hostCallbacks.hostUserData, &beat, &tempo) == noErr) {
            frame.beat = beat;
            frame.tempo = tempo;
        }
    }
    if (au->hostCallbacks.transportStateProc) {
        Boolean playing = false, changed = false, looping = false;
        Float64 sampleTime = 0, cycleStart = 0, cycleEnd = 0;
        if (au->hostCallbacks.transportStateProc(
                au->hostCallbacks.hostUserData, &playing, &changed,
                &sampleTime, &looping, &cycleStart, &cycleEnd) == noErr) {
            frame.transport = playing ? 1 : 0;
        }
    }

    uint64_t cursor = atomic_load_explicit(&au->ring->writeCursor, memory_order_relaxed);
    SensorFrame *slots = (SensorFrame *)((uint8_t *)au->ring + sizeof(SensorHeader));
    slots[cursor % SENSOR_FRAME_CAPACITY] = frame;
    atomic_store_explicit(&au->ring->writeCursor, cursor + 1, memory_order_release);

    for (uint32_t channel = 0; channel < SENSOR_MAX_CHANNELS; channel++) {
        au->sumSquares[channel] = 0;
        au->windowPeak[channel] = 0;
    }
    au->windowSamples = 0;
}

static OSStatus sensorOpenRing(SensorAU *au) {
    const char *home = getenv("HOME");
    if (!home) home = "/tmp";
    char directory[900];
    snprintf(directory, sizeof(directory), "%s/Library/Application Support/LogicMCPSensor", home);
    char parent[900];
    snprintf(parent, sizeof(parent), "%s/Library/Application Support", home);
    mkdir(parent, 0755);
    mkdir(directory, 0755);

    uuid_t uuid;
    uuid_generate(uuid);
    char uuidText[40];
    uuid_unparse_lower(uuid, uuidText);
    snprintf(au->ringPath, sizeof(au->ringPath), "%s/sensor-%s.ring", directory, uuidText);

    au->ringBytes = sizeof(SensorHeader) + sizeof(SensorFrame) * SENSOR_FRAME_CAPACITY;
    int fd = open(au->ringPath, O_RDWR | O_CREAT | O_EXCL, 0644);
    if (fd < 0) {
        return kAudioUnitErr_FailedInitialization;
    }
    if (ftruncate(fd, (off_t)au->ringBytes) != 0) {
        close(fd);
        unlink(au->ringPath);
        return kAudioUnitErr_FailedInitialization;
    }
    void *mapped = mmap(NULL, au->ringBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) {
        unlink(au->ringPath);
        return kAudioUnitErr_FailedInitialization;
    }
    memset(mapped, 0, au->ringBytes); // pre-touch every page before realtime use
    au->ring = (SensorHeader *)mapped;
    memcpy(au->ring->magic, SENSOR_MAGIC, 8);
    au->ring->version = SENSOR_VERSION;
    au->ring->frameBytes = sizeof(SensorFrame);
    au->ring->frameCapacity = SENSOR_FRAME_CAPACITY;
    memcpy(au->ring->instanceID, uuidText, sizeof(uuidText));
    atomic_store_explicit(&au->ring->writeCursor, 0, memory_order_release);

    // Companion rolling audio ring, sample-synchronized via the feature
    // frames' audioSampleCursor field.
    au->audioChannels = au->outputFormat.mChannelsPerFrame > SENSOR_MAX_CHANNELS
        ? SENSOR_MAX_CHANNELS : au->outputFormat.mChannelsPerFrame;
    if (au->audioChannels == 0) au->audioChannels = 1;
    uint64_t capacityFrames = (uint64_t)(au->outputFormat.mSampleRate * AUDIO_RING_SECONDS);
    snprintf(au->audioRingPath, sizeof(au->audioRingPath), "%s/sensor-%s.audio", directory, uuidText);
    au->audioRingBytes = sizeof(AudioRingHeader)
        + (size_t)capacityFrames * au->audioChannels * sizeof(float);
    int audioFD = open(au->audioRingPath, O_RDWR | O_CREAT | O_EXCL, 0644);
    if (audioFD < 0 || ftruncate(audioFD, (off_t)au->audioRingBytes) != 0) {
        if (audioFD >= 0) close(audioFD);
        sensorCloseRing(au);
        return kAudioUnitErr_FailedInitialization;
    }
    void *audioMapped = mmap(NULL, au->audioRingBytes, PROT_READ | PROT_WRITE, MAP_SHARED, audioFD, 0);
    close(audioFD);
    if (audioMapped == MAP_FAILED) {
        sensorCloseRing(au);
        return kAudioUnitErr_FailedInitialization;
    }
    memset(audioMapped, 0, au->audioRingBytes); // pre-touch before realtime use
    au->audioRing = (AudioRingHeader *)audioMapped;
    memcpy(au->audioRing->magic, "LMCPAUD1", 8);
    au->audioRing->version = SENSOR_VERSION;
    au->audioRing->channels = au->audioChannels;
    au->audioRing->sampleRate = au->outputFormat.mSampleRate;
    au->audioRing->capacityFrames = capacityFrames;
    atomic_store_explicit(&au->audioRing->writeCursor, 0, memory_order_release);
    return noErr;
}

static void sensorAppendAudio(SensorAU *au, const AudioBufferList *ioData, UInt32 frameCount) {
    AudioRingHeader *ring = au->audioRing;
    if (!ring) return;
    const uint32_t channels = au->audioChannels;
    const uint64_t capacity = ring->capacityFrames;
    float *slots = (float *)((uint8_t *)ring + sizeof(AudioRingHeader));
    uint64_t cursor = atomic_load_explicit(&ring->writeCursor, memory_order_relaxed);

    // Collect up to two channel pointers, handling both buffer layouts.
    const float *channelData[SENSOR_MAX_CHANNELS] = { NULL, NULL };
    UInt32 channelStride[SENSOR_MAX_CHANNELS] = { 1, 1 };
    uint32_t found = 0;
    for (UInt32 buffer = 0; buffer < ioData->mNumberBuffers && found < channels; buffer++) {
        const float *samples = (const float *)ioData->mBuffers[buffer].mData;
        if (!samples) continue;
        UInt32 interleaved = ioData->mBuffers[buffer].mNumberChannels;
        if (interleaved <= 1) {
            channelData[found] = samples;
            channelStride[found] = 1;
            found++;
        } else {
            for (UInt32 channel = 0; channel < interleaved && found < channels; channel++) {
                channelData[found] = samples + channel;
                channelStride[found] = interleaved;
                found++;
            }
        }
    }
    if (found == 0) return;

    for (UInt32 sample = 0; sample < frameCount; sample++) {
        uint64_t slot = (cursor + sample) % capacity;
        float *out = slots + slot * channels;
        for (uint32_t channel = 0; channel < channels; channel++) {
            const float *source = channelData[channel < found ? channel : found - 1];
            UInt32 stride = channelStride[channel < found ? channel : found - 1];
            out[channel] = source[sample * stride];
        }
    }
    atomic_store_explicit(&ring->writeCursor, cursor + frameCount, memory_order_release);
}

static void sensorCloseRing(SensorAU *au) {
    if (au->ring) {
        munmap(au->ring, au->ringBytes);
        au->ring = NULL;
    }
    if (au->ringPath[0]) {
        unlink(au->ringPath);
        au->ringPath[0] = 0;
    }
    if (au->audioRing) {
        munmap(au->audioRing, au->audioRingBytes);
        au->audioRing = NULL;
    }
    if (au->audioRingPath[0]) {
        unlink(au->audioRingPath);
        au->audioRingPath[0] = 0;
    }
}

// MARK: - Formats

static AudioStreamBasicDescription sensorDefaultFormat(void) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = 44100;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = 2;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(float);
    format.mBytesPerPacket = sizeof(float);
    return format;
}

static int sensorFormatIsUsable(const AudioStreamBasicDescription *format) {
    if (format->mFormatID != kAudioFormatLinearPCM) return 0;
    if (!(format->mFormatFlags & kAudioFormatFlagIsFloat)) return 0;
    if (format->mBitsPerChannel != 32) return 0;
    if (format->mChannelsPerFrame < 1 || format->mChannelsPerFrame > 64) return 0;
    return 1;
}

// MARK: - Instance lifecycle

static OSStatus sensorInitialize(void *self) {
    SensorAU *au = (SensorAU *)self;
    if (au->initialized) return noErr;
    if (au->inputFormat.mChannelsPerFrame != au->outputFormat.mChannelsPerFrame) {
        return kAudioUnitErr_FormatNotSupported;
    }
    UInt32 channels = au->outputFormat.mChannelsPerFrame;
    au->scratchCapacity = au->maxFramesPerSlice * channels;
    au->scratch = calloc(au->scratchCapacity, sizeof(float));
    if (!au->scratch) return kAudioUnitErr_FailedInitialization;
    OSStatus status = sensorOpenRing(au);
    if (status != noErr) {
        free(au->scratch);
        au->scratch = NULL;
        return status;
    }
    au->samplesPerFrame = (uint32_t)(au->outputFormat.mSampleRate / SENSOR_FRAMES_PER_SECOND);
    if (au->samplesPerFrame < 256) au->samplesPerFrame = 256;
    au->windowSamples = 0;
    au->sequence = 0;
    au->initialized = 1;
    return noErr;
}

static OSStatus sensorUninitialize(void *self) {
    SensorAU *au = (SensorAU *)self;
    if (!au->initialized) return noErr;
    sensorCloseRing(au);
    free(au->scratch);
    au->scratch = NULL;
    au->initialized = 0;
    return noErr;
}

static OSStatus sensorReset(void *self, AudioUnitScope scope, AudioUnitElement element) {
    SensorAU *au = (SensorAU *)self;
    for (uint32_t channel = 0; channel < SENSOR_MAX_CHANNELS; channel++) {
        au->sumSquares[channel] = 0;
        au->windowPeak[channel] = 0;
    }
    au->windowSamples = 0;
    return noErr;
}

// MARK: - Properties

static OSStatus sensorGetPropertyInfo(void *self, AudioUnitPropertyID property,
                                      AudioUnitScope scope, AudioUnitElement element,
                                      UInt32 *outSize, Boolean *outWritable) {
    UInt32 size = 0;
    Boolean writable = false;
    Boolean globalOnly = false;
    switch (property) {
    case kAudioUnitProperty_StreamFormat:
        size = sizeof(AudioStreamBasicDescription); writable = true; break;
    case kAudioUnitProperty_SampleRate:
        size = sizeof(Float64); writable = true; break;
    case kAudioUnitProperty_ElementCount:
        size = sizeof(UInt32); writable = false; break;
    case kAudioUnitProperty_MaximumFramesPerSlice:
        size = sizeof(UInt32); writable = true; globalOnly = true; break;
    case kAudioUnitProperty_Latency:
    case kAudioUnitProperty_TailTime:
        size = sizeof(Float64); writable = false; globalOnly = true; break;
    case kAudioUnitProperty_SupportedNumChannels:
        size = sizeof(AUChannelInfo); writable = false; globalOnly = true; break;
    case kAudioUnitProperty_BypassEffect:
        size = sizeof(UInt32); writable = true; globalOnly = true; break;
    case kAudioUnitProperty_LastRenderError:
        size = sizeof(OSStatus); writable = false; globalOnly = true; break;
    case kAudioUnitProperty_ParameterList:
        size = 0; writable = false; break;
    case kAudioUnitProperty_ClassInfo:
        size = sizeof(CFPropertyListRef); writable = true; globalOnly = true; break;
    case kAudioUnitProperty_PresentPreset:
        size = sizeof(AUPreset); writable = true; globalOnly = true; break;
    case kAudioUnitProperty_HostCallbacks:
        size = sizeof(HostCallbackInfo); writable = true; globalOnly = true; break;
    case kAudioUnitProperty_SetRenderCallback:
        size = sizeof(AURenderCallbackStruct); writable = true; break;
    case kAudioUnitProperty_MakeConnection:
        size = sizeof(AudioUnitConnection); writable = true; break;
    case kAudioUnitProperty_InPlaceProcessing:
    case kAudioUnitProperty_ShouldAllocateBuffer:
        size = sizeof(UInt32); writable = false; globalOnly = true; break;
    default:
        return kAudioUnitErr_InvalidProperty;
    }
    if (globalOnly && scope != kAudioUnitScope_Global) {
        return kAudioUnitErr_InvalidScope;
    }
    if (outSize) *outSize = size;
    if (outWritable) *outWritable = writable;
    return noErr;
}

static OSStatus sensorGetProperty(void *self, AudioUnitPropertyID property,
                                  AudioUnitScope scope, AudioUnitElement element,
                                  void *outData, UInt32 *ioSize) {
    SensorAU *au = (SensorAU *)self;
    if (!ioSize) return kAudioUnitErr_InvalidParameter;
    // Enforce identical property/scope validity rules as GetPropertyInfo.
    UInt32 declaredSize;
    Boolean writable;
    OSStatus infoStatus = sensorGetPropertyInfo(self, property, scope, element, &declaredSize, &writable);
    if (infoStatus != noErr) return infoStatus;
    if (!outData) {
        *ioSize = declaredSize;
        return noErr;
    }
    switch (property) {
    case kAudioUnitProperty_StreamFormat: {
        if (*ioSize < sizeof(AudioStreamBasicDescription)) return kAudioUnitErr_InvalidParameter;
        const AudioStreamBasicDescription *format =
            (scope == kAudioUnitScope_Input) ? &au->inputFormat : &au->outputFormat;
        memcpy(outData, format, sizeof(*format));
        *ioSize = sizeof(*format);
        return noErr;
    }
    case kAudioUnitProperty_SampleRate: {
        if (*ioSize < sizeof(Float64)) return kAudioUnitErr_InvalidParameter;
        Float64 rate = (scope == kAudioUnitScope_Input)
            ? au->inputFormat.mSampleRate : au->outputFormat.mSampleRate;
        memcpy(outData, &rate, sizeof(rate));
        *ioSize = sizeof(rate);
        return noErr;
    }
    case kAudioUnitProperty_ElementCount: {
        if (*ioSize < sizeof(UInt32)) return kAudioUnitErr_InvalidParameter;
        UInt32 count = 1;
        memcpy(outData, &count, sizeof(count));
        *ioSize = sizeof(count);
        return noErr;
    }
    case kAudioUnitProperty_MaximumFramesPerSlice: {
        if (*ioSize < sizeof(UInt32)) return kAudioUnitErr_InvalidParameter;
        memcpy(outData, &au->maxFramesPerSlice, sizeof(UInt32));
        *ioSize = sizeof(UInt32);
        return noErr;
    }
    case kAudioUnitProperty_Latency:
    case kAudioUnitProperty_TailTime: {
        if (*ioSize < sizeof(Float64)) return kAudioUnitErr_InvalidParameter;
        Float64 zero = 0;
        memcpy(outData, &zero, sizeof(zero));
        *ioSize = sizeof(zero);
        return noErr;
    }
    case kAudioUnitProperty_SupportedNumChannels: {
        if (*ioSize < sizeof(AUChannelInfo)) return kAudioUnitErr_InvalidParameter;
        AUChannelInfo info = { -1, -1 }; // any count in, same count out
        memcpy(outData, &info, sizeof(info));
        *ioSize = sizeof(info);
        return noErr;
    }
    case kAudioUnitProperty_BypassEffect: {
        if (*ioSize < sizeof(UInt32)) return kAudioUnitErr_InvalidParameter;
        memcpy(outData, &au->bypassed, sizeof(UInt32));
        *ioSize = sizeof(UInt32);
        return noErr;
    }
    case kAudioUnitProperty_LastRenderError: {
        if (*ioSize < sizeof(OSStatus)) return kAudioUnitErr_InvalidParameter;
        OSStatus none = noErr;
        memcpy(outData, &none, sizeof(none));
        *ioSize = sizeof(none);
        return noErr;
    }
    case kAudioUnitProperty_ParameterList:
        *ioSize = 0;
        return noErr;
    case kAudioUnitProperty_InPlaceProcessing:
    case kAudioUnitProperty_ShouldAllocateBuffer: {
        if (*ioSize < sizeof(UInt32)) return kAudioUnitErr_InvalidParameter;
        UInt32 yes = 1;
        memcpy(outData, &yes, sizeof(yes));
        *ioSize = sizeof(yes);
        return noErr;
    }
    case kAudioUnitProperty_ClassInfo: {
        if (*ioSize < sizeof(CFPropertyListRef)) return kAudioUnitErr_InvalidParameter;
        CFMutableDictionaryRef dictionary = CFDictionaryCreateMutable(
            NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        SInt32 typeValue = 'aufx', subtypeValue = 'lmsn', manufacturerValue = 'LMcp';
        SInt32 versionValue = 0x00010000;
        CFNumberRef type = CFNumberCreate(NULL, kCFNumberSInt32Type, &typeValue);
        CFNumberRef subtype = CFNumberCreate(NULL, kCFNumberSInt32Type, &subtypeValue);
        CFNumberRef manufacturer = CFNumberCreate(NULL, kCFNumberSInt32Type, &manufacturerValue);
        CFNumberRef version = CFNumberCreate(NULL, kCFNumberSInt32Type, &versionValue);
        CFDictionarySetValue(dictionary, CFSTR(kAUPresetTypeKey), type);
        CFDictionarySetValue(dictionary, CFSTR(kAUPresetSubtypeKey), subtype);
        CFDictionarySetValue(dictionary, CFSTR(kAUPresetManufacturerKey), manufacturer);
        CFDictionarySetValue(dictionary, CFSTR(kAUPresetVersionKey), version);
        CFDictionarySetValue(dictionary, CFSTR(kAUPresetNameKey),
                             au->presentPreset.presetName ? au->presentPreset.presetName : CFSTR("Untitled"));
        CFRelease(type); CFRelease(subtype); CFRelease(manufacturer); CFRelease(version);
        *(CFPropertyListRef *)outData = dictionary;
        *ioSize = sizeof(CFPropertyListRef);
        return noErr;
    }
    case kAudioUnitProperty_PresentPreset: {
        if (*ioSize < sizeof(AUPreset)) return kAudioUnitErr_InvalidParameter;
        AUPreset preset = au->presentPreset;
        if (preset.presetName) CFRetain(preset.presetName);
        memcpy(outData, &preset, sizeof(preset));
        *ioSize = sizeof(preset);
        return noErr;
    }
    default:
        return kAudioUnitErr_InvalidProperty;
    }
}

static OSStatus sensorSetProperty(void *self, AudioUnitPropertyID property,
                                  AudioUnitScope scope, AudioUnitElement element,
                                  const void *inData, UInt32 inSize) {
    SensorAU *au = (SensorAU *)self;
    switch (property) {
    case kAudioUnitProperty_StreamFormat: {
        if (inSize < sizeof(AudioStreamBasicDescription) || !inData) return kAudioUnitErr_InvalidParameter;
        const AudioStreamBasicDescription *format = (const AudioStreamBasicDescription *)inData;
        if (!sensorFormatIsUsable(format)) return kAudioUnitErr_FormatNotSupported;
        if (au->initialized) return kAudioUnitErr_Initialized;
        if (scope == kAudioUnitScope_Input) au->inputFormat = *format;
        else if (scope == kAudioUnitScope_Output) au->outputFormat = *format;
        else return kAudioUnitErr_InvalidScope;
        sensorNotifyListeners(au, property, scope, element);
        return noErr;
    }
    case kAudioUnitProperty_SampleRate: {
        if (inSize < sizeof(Float64) || !inData) return kAudioUnitErr_InvalidParameter;
        Float64 rate = *(const Float64 *)inData;
        if (au->initialized) return kAudioUnitErr_Initialized;
        if (scope == kAudioUnitScope_Input) au->inputFormat.mSampleRate = rate;
        else au->outputFormat.mSampleRate = rate;
        return noErr;
    }
    case kAudioUnitProperty_MaximumFramesPerSlice: {
        if (inSize < sizeof(UInt32) || !inData) return kAudioUnitErr_InvalidParameter;
        if (au->initialized) return kAudioUnitErr_Initialized;
        au->maxFramesPerSlice = *(const UInt32 *)inData;
        sensorNotifyListeners(au, property, kAudioUnitScope_Global, 0);
        return noErr;
    }
    case kAudioUnitProperty_BypassEffect: {
        if (inSize < sizeof(UInt32) || !inData) return kAudioUnitErr_InvalidParameter;
        au->bypassed = *(const UInt32 *)inData;
        sensorNotifyListeners(au, property, kAudioUnitScope_Global, 0);
        return noErr;
    }
    case kAudioUnitProperty_SetRenderCallback: {
        if (inSize < sizeof(AURenderCallbackStruct) || !inData) return kAudioUnitErr_InvalidParameter;
        if (scope != kAudioUnitScope_Input && scope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidScope;
        au->inputCallback = *(const AURenderCallbackStruct *)inData;
        memset(&au->connection, 0, sizeof(au->connection));
        return noErr;
    }
    case kAudioUnitProperty_MakeConnection: {
        if (inSize < sizeof(AudioUnitConnection) || !inData) return kAudioUnitErr_InvalidParameter;
        au->connection = *(const AudioUnitConnection *)inData;
        memset(&au->inputCallback, 0, sizeof(au->inputCallback));
        return noErr;
    }
    case kAudioUnitProperty_HostCallbacks: {
        if (!inData) return kAudioUnitErr_InvalidParameter;
        memset(&au->hostCallbacks, 0, sizeof(au->hostCallbacks));
        UInt32 bytes = inSize < sizeof(HostCallbackInfo) ? inSize : (UInt32)sizeof(HostCallbackInfo);
        memcpy(&au->hostCallbacks, inData, bytes);
        return noErr;
    }
    case kAudioUnitProperty_ClassInfo: {
        // Stateless apart from the preset name, which hosts expect to round-trip.
        if (inSize >= sizeof(CFPropertyListRef) && inData) {
            CFPropertyListRef plist = *(CFPropertyListRef const *)inData;
            if (plist && CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
                CFStringRef name = CFDictionaryGetValue((CFDictionaryRef)plist, CFSTR(kAUPresetNameKey));
                if (name && CFGetTypeID(name) == CFStringGetTypeID()) {
                    if (au->presentPreset.presetName) CFRelease(au->presentPreset.presetName);
                    au->presentPreset.presetName = CFRetain(name);
                }
            }
        }
        sensorNotifyListeners(au, property, kAudioUnitScope_Global, 0);
        return noErr;
    }
    case kAudioUnitProperty_PresentPreset: {
        if (inSize < sizeof(AUPreset) || !inData) return kAudioUnitErr_InvalidParameter;
        const AUPreset *preset = (const AUPreset *)inData;
        if (au->presentPreset.presetName) CFRelease(au->presentPreset.presetName);
        au->presentPreset = *preset;
        if (au->presentPreset.presetName) CFRetain(au->presentPreset.presetName);
        sensorNotifyListeners(au, property, kAudioUnitScope_Global, 0);
        return noErr;
    }
    default:
        return kAudioUnitErr_InvalidProperty;
    }
}

static OSStatus sensorAddPropertyListener(void *self, AudioUnitPropertyID property,
                                          AudioUnitPropertyListenerProc proc, void *userData) {
    SensorAU *au = (SensorAU *)self;
    for (int index = 0; index < SENSOR_MAX_LISTENERS; index++) {
        if (au->listeners[index].proc == NULL) {
            au->listeners[index].property = property;
            au->listeners[index].proc = proc;
            au->listeners[index].userData = userData;
            return noErr;
        }
    }
    return kAudioUnitErr_InvalidParameter;
}

static OSStatus sensorRemovePropertyListener(void *self, AudioUnitPropertyID property,
                                             AudioUnitPropertyListenerProc proc) {
    SensorAU *au = (SensorAU *)self;
    for (int index = 0; index < SENSOR_MAX_LISTENERS; index++) {
        if (au->listeners[index].proc == proc && au->listeners[index].property == property) {
            memset(&au->listeners[index], 0, sizeof(au->listeners[index]));
        }
    }
    return noErr;
}

static OSStatus sensorRemovePropertyListenerWithUserData(void *self, AudioUnitPropertyID property,
                                                         AudioUnitPropertyListenerProc proc,
                                                         void *userData) {
    SensorAU *au = (SensorAU *)self;
    for (int index = 0; index < SENSOR_MAX_LISTENERS; index++) {
        if (au->listeners[index].proc == proc && au->listeners[index].property == property
            && au->listeners[index].userData == userData) {
            memset(&au->listeners[index], 0, sizeof(au->listeners[index]));
        }
    }
    return noErr;
}

static void sensorNotifyListeners(SensorAU *au, AudioUnitPropertyID property,
                                  AudioUnitScope scope, AudioUnitElement element) {
    for (int index = 0; index < SENSOR_MAX_LISTENERS; index++) {
        if (au->listeners[index].proc && au->listeners[index].property == property) {
            au->listeners[index].proc(au->listeners[index].userData,
                                      (AudioUnit)au->instance, property, scope, element);
        }
    }
}

// MARK: - Parameters (none)

static OSStatus sensorGetParameter(void *self, AudioUnitParameterID parameter,
                                   AudioUnitScope scope, AudioUnitElement element,
                                   AudioUnitParameterValue *outValue) {
    return kAudioUnitErr_InvalidParameter;
}

static OSStatus sensorSetParameter(void *self, AudioUnitParameterID parameter,
                                   AudioUnitScope scope, AudioUnitElement element,
                                   AudioUnitParameterValue value, UInt32 bufferOffset) {
    return kAudioUnitErr_InvalidParameter;
}

// MARK: - Render notifications

static OSStatus sensorAddRenderNotify(void *self, AURenderCallback proc, void *refCon) {
    SensorAU *au = (SensorAU *)self;
    for (int index = 0; index < SENSOR_MAX_NOTIFIES; index++) {
        if (au->notifyProcs[index] == NULL) {
            au->notifyProcs[index] = proc;
            au->notifyRefCons[index] = refCon;
            return noErr;
        }
    }
    return kAudioUnitErr_InvalidParameter;
}

static OSStatus sensorRemoveRenderNotify(void *self, AURenderCallback proc, void *refCon) {
    SensorAU *au = (SensorAU *)self;
    for (int index = 0; index < SENSOR_MAX_NOTIFIES; index++) {
        if (au->notifyProcs[index] == proc && au->notifyRefCons[index] == refCon) {
            au->notifyProcs[index] = NULL;
            au->notifyRefCons[index] = NULL;
        }
    }
    return noErr;
}

static void sensorCallNotifies(SensorAU *au, AudioUnitRenderActionFlags flags,
                               const AudioTimeStamp *timeStamp, UInt32 busNumber,
                               UInt32 frameCount, AudioBufferList *ioData) {
    for (int index = 0; index < SENSOR_MAX_NOTIFIES; index++) {
        if (au->notifyProcs[index]) {
            AudioUnitRenderActionFlags localFlags = flags;
            au->notifyProcs[index](au->notifyRefCons[index], &localFlags, timeStamp,
                                   busNumber, frameCount, ioData);
        }
    }
}

// MARK: - Render

static void sensorMeter(SensorAU *au, const AudioBufferList *ioData, UInt32 frameCount) {
    sensorAppendAudio(au, ioData, frameCount);
    uint32_t channelIndex = 0;
    for (UInt32 buffer = 0; buffer < ioData->mNumberBuffers && channelIndex < SENSOR_MAX_CHANNELS; buffer++) {
        const float *samples = (const float *)ioData->mBuffers[buffer].mData;
        if (!samples) continue;
        UInt32 interleavedChannels = ioData->mBuffers[buffer].mNumberChannels;
        if (interleavedChannels <= 1) {
            double sum = au->sumSquares[channelIndex];
            float peak = au->windowPeak[channelIndex];
            for (UInt32 sample = 0; sample < frameCount; sample++) {
                float value = samples[sample];
                float magnitude = fabsf(value);
                if (magnitude > peak) peak = magnitude;
                sum += (double)value * (double)value;
            }
            au->sumSquares[channelIndex] = sum;
            au->windowPeak[channelIndex] = peak;
            channelIndex++;
        } else {
            for (UInt32 channel = 0; channel < interleavedChannels && channelIndex < SENSOR_MAX_CHANNELS; channel++) {
                double sum = au->sumSquares[channelIndex];
                float peak = au->windowPeak[channelIndex];
                for (UInt32 sample = 0; sample < frameCount; sample++) {
                    float value = samples[sample * interleavedChannels + channel];
                    float magnitude = fabsf(value);
                    if (magnitude > peak) peak = magnitude;
                    sum += (double)value * (double)value;
                }
                au->sumSquares[channelIndex] = sum;
                au->windowPeak[channelIndex] = peak;
                channelIndex++;
            }
        }
    }
    au->windowSamples += frameCount;
    if (au->windowSamples >= au->samplesPerFrame) {
        sensorEmitFrame(au);
    }
}

static OSStatus sensorRender(void *self, AudioUnitRenderActionFlags *ioFlags,
                             const AudioTimeStamp *timeStamp, UInt32 busNumber,
                             UInt32 frameCount, AudioBufferList *ioData) {
    SensorAU *au = (SensorAU *)self;
    if (!au->initialized) return kAudioUnitErr_Uninitialized;
    if (frameCount > au->maxFramesPerSlice) return kAudioUnitErr_TooManyFramesToProcess;

    sensorCallNotifies(au, kAudioUnitRenderAction_PreRender, timeStamp, busNumber, frameCount, ioData);

    // Give the host buffers backed by our scratch memory when it passes none.
    UInt32 scratchOffset = 0;
    for (UInt32 buffer = 0; buffer < ioData->mNumberBuffers; buffer++) {
        if (ioData->mBuffers[buffer].mData == NULL) {
            UInt32 channels = ioData->mBuffers[buffer].mNumberChannels;
            if (channels == 0) channels = 1;
            UInt32 needed = frameCount * channels;
            if (scratchOffset + needed > au->scratchCapacity) return kAudioUnitErr_TooManyFramesToProcess;
            ioData->mBuffers[buffer].mData = au->scratch + scratchOffset;
            ioData->mBuffers[buffer].mDataByteSize = needed * sizeof(float);
            scratchOffset += needed;
        }
    }

    OSStatus status = noErr;
    if (au->inputCallback.inputProc) {
        AudioUnitRenderActionFlags pullFlags = 0;
        status = au->inputCallback.inputProc(au->inputCallback.inputProcRefCon, &pullFlags,
                                             timeStamp, 0, frameCount, ioData);
    } else if (au->connection.sourceAudioUnit) {
        AudioUnitRenderActionFlags pullFlags = 0;
        status = AudioUnitRender(au->connection.sourceAudioUnit, &pullFlags, timeStamp,
                                 au->connection.sourceOutputNumber, frameCount, ioData);
    } else {
        for (UInt32 buffer = 0; buffer < ioData->mNumberBuffers; buffer++) {
            memset(ioData->mBuffers[buffer].mData, 0, ioData->mBuffers[buffer].mDataByteSize);
        }
    }

    if (status == noErr) {
        sensorMeter(au, ioData, frameCount); // metering only; audio passes through untouched
    }

    sensorCallNotifies(au, kAudioUnitRenderAction_PostRender, timeStamp, busNumber, frameCount, ioData);
    return status;
}

// In-place processing entry points. Logic drives effects through
// AudioUnitProcess rather than the classic pull-model AudioUnitRender.
static OSStatus sensorProcess(void *self, AudioUnitRenderActionFlags *ioFlags,
                              const AudioTimeStamp *timeStamp, UInt32 frameCount,
                              AudioBufferList *ioData) {
    SensorAU *au = (SensorAU *)self;
    if (!au->initialized) return kAudioUnitErr_Uninitialized;
    if (frameCount > au->maxFramesPerSlice) return kAudioUnitErr_TooManyFramesToProcess;
    sensorMeter(au, ioData, frameCount); // audio passes through untouched
    return noErr;
}

static OSStatus sensorProcessMultiple(void *self, AudioUnitRenderActionFlags *ioFlags,
                                      const AudioTimeStamp *timeStamp, UInt32 frameCount,
                                      UInt32 inputListCount,
                                      const AudioBufferList **inputLists,
                                      UInt32 outputListCount,
                                      AudioBufferList **outputLists) {
    SensorAU *au = (SensorAU *)self;
    if (!au->initialized) return kAudioUnitErr_Uninitialized;
    if (frameCount > au->maxFramesPerSlice) return kAudioUnitErr_TooManyFramesToProcess;
    for (UInt32 list = 0; list < outputListCount && list < inputListCount; list++) {
        const AudioBufferList *input = inputLists[list];
        AudioBufferList *output = outputLists[list];
        for (UInt32 buffer = 0; buffer < output->mNumberBuffers && buffer < input->mNumberBuffers; buffer++) {
            if (output->mBuffers[buffer].mData != input->mBuffers[buffer].mData
                && output->mBuffers[buffer].mData && input->mBuffers[buffer].mData) {
                memcpy(output->mBuffers[buffer].mData, input->mBuffers[buffer].mData,
                       output->mBuffers[buffer].mDataByteSize);
            }
        }
    }
    if (inputListCount > 0) {
        sensorMeter(au, (AudioBufferList *)inputLists[0], frameCount);
    }
    return noErr;
}

// MARK: - Component plumbing

static OSStatus sensorOpen(void *self, AudioComponentInstance instance) {
    SensorAU *au = (SensorAU *)self;
    au->instance = instance;
    au->inputFormat = sensorDefaultFormat();
    au->outputFormat = sensorDefaultFormat();
    au->maxFramesPerSlice = 4096;
    au->presentPreset.presetNumber = -1;
    au->presentPreset.presetName = CFSTR("Untitled");
    CFRetain(au->presentPreset.presetName);
    return noErr;
}

static OSStatus sensorClose(void *self) {
    SensorAU *au = (SensorAU *)self;
    sensorUninitialize(self);
    if (au->presentPreset.presetName) CFRelease(au->presentPreset.presetName);
    free(au);
    return noErr;
}

static AudioComponentMethod sensorLookup(SInt16 selector) {
    switch (selector) {
    case kAudioUnitInitializeSelect: return (AudioComponentMethod)sensorInitialize;
    case kAudioUnitUninitializeSelect: return (AudioComponentMethod)sensorUninitialize;
    case kAudioUnitGetPropertyInfoSelect: return (AudioComponentMethod)sensorGetPropertyInfo;
    case kAudioUnitGetPropertySelect: return (AudioComponentMethod)sensorGetProperty;
    case kAudioUnitSetPropertySelect: return (AudioComponentMethod)sensorSetProperty;
    case kAudioUnitAddPropertyListenerSelect: return (AudioComponentMethod)sensorAddPropertyListener;
    case kAudioUnitRemovePropertyListenerSelect: return (AudioComponentMethod)sensorRemovePropertyListener;
    case kAudioUnitRemovePropertyListenerWithUserDataSelect: return (AudioComponentMethod)sensorRemovePropertyListenerWithUserData;
    case kAudioUnitAddRenderNotifySelect: return (AudioComponentMethod)sensorAddRenderNotify;
    case kAudioUnitRemoveRenderNotifySelect: return (AudioComponentMethod)sensorRemoveRenderNotify;
    case kAudioUnitGetParameterSelect: return (AudioComponentMethod)sensorGetParameter;
    case kAudioUnitSetParameterSelect: return (AudioComponentMethod)sensorSetParameter;
    case kAudioUnitResetSelect: return (AudioComponentMethod)sensorReset;
    case kAudioUnitRenderSelect: return (AudioComponentMethod)sensorRender;
    case kAudioUnitProcessSelect: return (AudioComponentMethod)sensorProcess;
    case kAudioUnitProcessMultipleSelect: return (AudioComponentMethod)sensorProcessMultiple;
    default: return NULL;
    }
}

__attribute__((visibility("default")))
void *LogicMCPSensorFactory(const AudioComponentDescription *inDescription) {
    SensorAU *au = calloc(1, sizeof(SensorAU));
    if (!au) return NULL;
    au->interface.Open = sensorOpen;
    au->interface.Close = sensorClose;
    au->interface.Lookup = sensorLookup;
    au->interface.reserved = NULL;
    return au;
}
