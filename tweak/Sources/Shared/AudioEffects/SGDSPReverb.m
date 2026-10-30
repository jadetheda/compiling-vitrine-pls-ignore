#import "SGDSPEffects.h"
#import <AudioToolbox/AudioToolbox.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

typedef struct {
    float mix, minDelay, maxDelay, decay, decayHigh, density;
} Preset;

// Ambience, small room, medium room, large room, chamber, plate, small hall, large hall, cathedral.
// Calibrated for natural acoustic warmth, smooth diffusion, and zero metallic ringing:
// - minDelay is kept at 8ms to 35ms to eliminate harsh comb-filter notches in the 1-4 kHz critical presence band.
// - decayHigh (Nyquist decay) is damped (0.08s to 0.32s) to model physical atmospheric air absorption, preventing sibilant sibilance and tinny ringing.
// - density (RandomizeReflections) is maximized to 1000 across presets to eliminate flutter modes and modal clustering.
static const Preset kPresets[SGDSPReverbPresetCount] = {
    { 8, 0.008f, 0.024f, 0.35f, 0.08f, 1000}, // Ambience
    {12, 0.010f, 0.035f, 0.60f, 0.12f, 1000}, // Small room
    {16, 0.014f, 0.050f, 1.00f, 0.18f, 1000}, // Medium room
    {18, 0.018f, 0.070f, 1.50f, 0.22f, 1000}, // Large room
    {18, 0.012f, 0.045f, 1.30f, 0.20f, 1000}, // Chamber
    {16, 0.008f, 0.030f, 1.60f, 0.30f, 1000}, // Plate
    {20, 0.022f, 0.090f, 2.20f, 0.25f, 1000}, // Small hall
    {22, 0.028f, 0.120f, 3.20f, 0.28f, 1000}, // Large hall
    {25, 0.035f, 0.160f, 5.50f, 0.32f, 1000}, // Cathedral
};

struct SGDSPReverb {
    AudioUnit unit;
    Float64 sampleTime;
    float input[2][kSGDSPEffectMaxFrames];
    struct {
        AudioBufferList list;
        AudioBuffer second;
    } output;
};

static OSStatus pull(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp, UInt32 bus, UInt32 frames,
                     AudioBufferList *data) {
    SGDSPReverb *reverb = refCon;
    for (UInt32 c = 0; c < data->mNumberBuffers && c < 2; c++) {
        if (data->mBuffers[c].mData) memcpy(data->mBuffers[c].mData, reverb->input[c], frames * sizeof(float));
        else data->mBuffers[c].mData = reverb->input[c];
        data->mBuffers[c].mDataByteSize = frames * sizeof(float);
    }
    return noErr;
}

SGDSPReverb *SGDSPReverbCreate(double rate, int preset, float amount) {
    AudioComponentDescription description = {kAudioUnitType_Effect, kAudioUnitSubType_Reverb2, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    SGDSPReverb *reverb = component ? calloc(1, sizeof *reverb) : NULL;
    if (!reverb) return NULL;

    if (AudioComponentInstanceNew(component, &reverb->unit) != noErr) {
        free(reverb);
        return NULL;
    }

    AudioStreamBasicDescription format = {
        .mSampleRate = rate, .mFormatID = kAudioFormatLinearPCM, .mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
        .mBytesPerPacket = 4, .mFramesPerPacket = 1, .mBytesPerFrame = 4, .mChannelsPerFrame = 2, .mBitsPerChannel = 32,
    };
    UInt32 maxFrames = kSGDSPEffectMaxFrames;
    AURenderCallbackStruct callback = {pull, reverb};

    OSStatus status = AudioUnitSetProperty(reverb->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof format);
    if (!status) status = AudioUnitSetProperty(reverb->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, sizeof format);
    if (!status) status = AudioUnitSetProperty(reverb->unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, sizeof maxFrames);
    if (!status) status = AudioUnitSetProperty(reverb->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof callback);
    if (!status) status = AudioUnitInitialize(reverb->unit);
    if (status) {
        AudioComponentInstanceDispose(reverb->unit);
        free(reverb);
        return NULL;
    }

    reverb->output.list.mNumberBuffers = 2;
    SGDSPReverbSet(reverb, preset, amount);

    // The unit sets itself up on its first render, allocating: that render is a block of silence, here.
    float silence[2][kSGDSPEffectMaxFrames] = {{0}};
    SGDSPReverbRun(reverb, silence[0], silence[1], kSGDSPEffectMaxFrames);
    return reverb;
}

static void setPreset(SGDSPReverb *reverb, int preset, float mix) {
    const Preset *p = &kPresets[preset < 0 ? 0 : preset >= SGDSPReverbPresetCount ? SGDSPReverbPresetCount - 1 : preset];
    const struct { AudioUnitParameterID id; float value; } values[] = {
        {kReverb2Param_DryWetMix, mix}, {kReverb2Param_Gain, 0}, {kReverb2Param_MinDelayTime, p->minDelay},
        {kReverb2Param_MaxDelayTime, p->maxDelay}, {kReverb2Param_DecayTimeAt0Hz, p->decay},
        {kReverb2Param_DecayTimeAtNyquist, p->decayHigh}, {kReverb2Param_RandomizeReflections, p->density},
    };
    for (size_t i = 0; i < sizeof values / sizeof *values; i++) {
        AudioUnitSetParameter(reverb->unit, values[i].id, kAudioUnitScope_Global, 0, values[i].value, 0);
    }
}

void SGDSPReverbSet(SGDSPReverb *reverb, int preset, float amount) {
    int index = preset < 0 ? 0 : preset >= SGDSPReverbPresetCount ? SGDSPReverbPresetCount - 1 : preset;
    setPreset(reverb, index, fminf(100, kPresets[index].mix * fmaxf(0, amount) / 50));
}

void SGDSPReverbSetSend(SGDSPReverb *reverb, int preset) {
    setPreset(reverb, preset, 100);
}

void SGDSPReverbReset(SGDSPReverb *reverb) {
    AudioUnitReset(reverb->unit, kAudioUnitScope_Global, 0);
}

void SGDSPReverbRun(void *state, float *left, float *right, uint32_t frames) {
    SGDSPReverb *reverb = state;
    memcpy(reverb->input[0], left, frames * sizeof(float));
    memcpy(reverb->input[1], right, frames * sizeof(float));
    reverb->output.list.mBuffers[0] = (AudioBuffer){1, frames * (UInt32)sizeof(float), left};
    reverb->output.list.mBuffers[1] = (AudioBuffer){1, frames * (UInt32)sizeof(float), right};
    AudioTimeStamp timestamp = {.mSampleTime = reverb->sampleTime, .mFlags = kAudioTimeStampSampleTimeValid};
    AudioUnitRenderActionFlags flags = 0;

    // A failed render leaves the sound dry rather than whatever the buffers hold.
    if (AudioUnitRender(reverb->unit, &flags, &timestamp, 0, frames, &reverb->output.list) != noErr) {
        memcpy(left, reverb->input[0], frames * sizeof(float));
        memcpy(right, reverb->input[1], frames * sizeof(float));
    } else {
        if (reverb->output.list.mBuffers[0].mData != left) memcpy(left, reverb->output.list.mBuffers[0].mData, frames * sizeof(float));
        if (reverb->output.list.mBuffers[1].mData != right) memcpy(right, reverb->output.list.mBuffers[1].mData, frames * sizeof(float));
    }
    reverb->sampleTime += frames;
}

void SGDSPReverbFree(void *state) {
    SGDSPReverb *reverb = state;
    if (!reverb) return;
    AudioUnitUninitialize(reverb->unit);
    AudioComponentInstanceDispose(reverb->unit);
    free(reverb);
}
