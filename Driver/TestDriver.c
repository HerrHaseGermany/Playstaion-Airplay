#include <assert.h>
#include <stdio.h>
#include "../.build/driver/PlaystationAirplay.c"

static OSStatus EmptyStorage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef* data) {
    *data = NULL;
    return noErr;
}

static UInt32 notificationCount = 0;
static Float32 storedVolume = -1;
static OSStatus Changed(AudioServerPlugInHostRef host, AudioObjectID object, UInt32 count,
                        const AudioObjectPropertyAddress* addresses) {
    notificationCount += count;
    return noErr;
}
static OSStatus Store(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef value) {
    if(CFEqual(key, CFSTR("airplay.outputVolume")))
        assert(CFNumberGetValue((CFNumberRef)value, kCFNumberFloat32Type, &storedVolume));
    return noErr;
}

int main(void) {
    AudioServerPlugInDriverRef driver = PlaystationAirplay_Create(NULL, kAudioServerPlugInTypeUUID);
    assert(driver != NULL);
    AudioServerPlugInHostInterface host = { .CopyFromStorage = EmptyStorage,
        .PropertiesChanged = Changed, .WriteToStorage = Store };
    assert((*driver)->Initialize(driver, &host) == noErr);
    AudioObjectPropertyAddress address = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    UInt32 size = 99;
    assert((*driver)->GetPropertyDataSize(driver, kObjectID_Device, 0, &address, 0, NULL, &size) == noErr);
    assert(size == 0);
    address.mScope = kAudioObjectPropertyScopeOutput;
    assert((*driver)->GetPropertyDataSize(driver, kObjectID_Device, 0, &address, 0, NULL, &size) == noErr);
    assert(size == sizeof(AudioObjectID));
    AudioObjectID stream = 0;
    assert((*driver)->GetPropertyData(driver, kObjectID_Device, 0, &address, 0, NULL, sizeof(stream), &size, &stream) == noErr);
    assert(stream == kObjectID_Stream_Output);
    address.mSelector = kAudioObjectPropertyOwnedObjects;
    address.mScope = kAudioObjectPropertyScopeGlobal;
    assert((*driver)->GetPropertyDataSize(driver, kObjectID_Device, 0, &address, 0, NULL, &size) == noErr);
    assert(size == 3 * sizeof(AudioObjectID));
    address.mSelector = kAudioObjectPropertyControlList;
    assert((*driver)->GetPropertyDataSize(driver, kObjectID_Device, 0, &address, 0, NULL, &size) == noErr);
    assert(size == 2 * sizeof(AudioObjectID));
    AudioObjectID controls[2] = {0};
    assert((*driver)->GetPropertyData(driver, kObjectID_Device, 0, &address, 0, NULL, sizeof(controls), &size, controls) == noErr);
    assert(controls[0] == kObjectID_Volume_Output_Master && controls[1] == kObjectID_Mute_Output_Master);
    address.mSelector = kAudioObjectPropertyName;
    CFStringRef name = NULL;
    assert((*driver)->GetPropertyData(driver, kObjectID_Device, 0, &address, 0, NULL, sizeof(name), &size, &name) == noErr);
    assert(CFEqual(name, CFSTR("Playstation Airplay")));
    CFRelease(name);
    address.mSelector = kAudioDevicePropertyDeviceUID;
    assert((*driver)->GetPropertyData(driver, kObjectID_Device, 0, &address, 0, NULL, sizeof(name), &size, &name) == noErr);
    assert(CFEqual(name, CFSTR("de.raudzis.playlink.output")));
    CFRelease(name);
    address.mSelector = kAudioStreamPropertyVirtualFormat;
    AudioStreamBasicDescription format = {0};
    assert((*driver)->GetPropertyData(driver, stream, 0, &address, 0, NULL, sizeof(format), &size, &format) == noErr);
    assert(format.mChannelsPerFrame == 2 && format.mSampleRate == 48000.0 && format.mBitsPerChannel == 32);
    assert(!(*driver)->HasProperty(driver, kObjectID_Stream_Input, 0, &address));
    address.mSelector = kAudioLevelControlPropertyScalarValue;
    Float32 volume = 0;
    Boolean settable = false;
    assert((*driver)->IsPropertySettable(driver, controls[0], 0, &address, &settable) == noErr && settable);
    assert((*driver)->GetPropertyData(driver, controls[0], 0, &address, 0, NULL, sizeof(volume), &size, &volume) == noErr);
    assert(volume == 1);
    volume = 0.5;
    assert((*driver)->SetPropertyData(driver, controls[0], 0, &address, 0, NULL, sizeof(volume), &volume) == noErr);
    assert(storedVolume == 0.5 && notificationCount >= 2);
    volume = -1;
    assert((*driver)->GetPropertyData(driver, controls[0], 0, &address, 0, NULL, sizeof(volume), &size, &volume) == noErr && volume == 0.5);
    address.mSelector = kAudioLevelControlPropertyDecibelValue;
    assert((*driver)->GetPropertyData(driver, controls[0], 0, &address, 0, NULL, sizeof(volume), &size, &volume) == noErr);
    assert(fabsf(volume - (-6.0206f)) < 0.001);
    volume = -96;
    assert((*driver)->SetPropertyData(driver, controls[0], 0, &address, 0, NULL, sizeof(volume), &volume) == noErr);
    assert(storedVolume == 0);
    address.mSelector = kAudioBooleanControlPropertyValue;
    UInt32 muted = 1;
    assert((*driver)->SetPropertyData(driver, controls[1], 0, &address, 0, NULL, sizeof(muted), &muted) == noErr);
    muted = 0;
    assert((*driver)->GetPropertyData(driver, controls[1], 0, &address, 0, NULL, sizeof(muted), &size, &muted) == noErr && muted == 1);
    assert((*driver)->StartIO(driver, kObjectID_Device, 1) == noErr);
    Float64 sampleTime = -1; UInt64 hostTime = 0, seed = 0;
    assert((*driver)->GetZeroTimeStamp(driver, kObjectID_Device, 1, &sampleTime, &hostTime, &seed) == noErr);
    assert(sampleTime >= 0 && hostTime > 0);
    assert((*driver)->StopIO(driver, kObjectID_Device, 1) == noErr);
    puts("Virtual driver: output-only stereo, volume, dB mapping, persistence, mute notifications and I/O clock passed.");
    return 0;
}
