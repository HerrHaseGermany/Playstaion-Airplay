// Adaptation of Apple's MIT-licensed NullAudio sample; see Vendor/LICENSE.txt.
// The sample remains unmodified. Its interface is wrapped to publish output only.
#include "Vendor/NullAudio.c"

static bool Airplay_Hidden(AudioObjectID object) {
    return object >= kObjectID_Stream_Input && object != kObjectID_Stream_Output &&
           object != kObjectID_Volume_Output_Master && object != kObjectID_Mute_Output_Master;
}

static bool Airplay_List(const AudioObjectPropertyAddress* address) {
    return address->mSelector == kAudioObjectPropertyOwnedObjects ||
           address->mSelector == kAudioDevicePropertyStreams ||
           address->mSelector == kAudioObjectPropertyControlList;
}

static UInt32 Airplay_ListCount(const AudioObjectPropertyAddress* address) {
    if(address->mScope == kAudioObjectPropertyScopeInput) return 0;
    if(address->mSelector == kAudioDevicePropertyStreams) return 1;
    return address->mSelector == kAudioObjectPropertyControlList ? 2 : 3;
}

static Boolean Airplay_HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                                  const AudioObjectPropertyAddress* address) {
    if(Airplay_Hidden(object)) return false;
    return NullAudio_HasProperty(driver, object, pid, address);
}

static OSStatus Airplay_GetSize(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                               const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
                               const void* qualifier, UInt32* size) {
    if(Airplay_Hidden(object)) return kAudioHardwareBadObjectError;
    if(object == kObjectID_Device && address && Airplay_List(address) && size) {
        *size = Airplay_ListCount(address) * sizeof(AudioObjectID);
        return noErr;
    }
    return NullAudio_GetPropertyDataSize(driver, object, pid, address, qualifierSize, qualifier, size);
}

static OSStatus Airplay_GetData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                               const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
                               const void* qualifier, UInt32 capacity, UInt32* size, void* data) {
    if(Airplay_Hidden(object)) return kAudioHardwareBadObjectError;
    if(object == kObjectID_Device && address && Airplay_List(address) && size) {
        UInt32 count = Airplay_ListCount(address);
        if(capacity < count * sizeof(AudioObjectID) || (count && !data)) return kAudioHardwareBadPropertySizeError;
        const AudioObjectID objects[] = {kObjectID_Stream_Output, kObjectID_Volume_Output_Master, kObjectID_Mute_Output_Master};
        if(count) memcpy(data, objects + (address->mSelector == kAudioObjectPropertyControlList ? 1 : 0), count * sizeof(AudioObjectID));
        *size = count * sizeof(AudioObjectID);
        return noErr;
    }
    if(object == kObjectID_Device && address &&
       (address->mSelector == kAudioDevicePropertyDeviceCanBeDefaultDevice ||
        address->mSelector == kAudioDevicePropertyDeviceCanBeDefaultSystemDevice)) {
        if(!data || !size || capacity < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        *((UInt32*)data) = address->mScope == kAudioObjectPropertyScopeOutput ? 1 : 0;
        *size = sizeof(UInt32);
        return noErr;
    }
    if(object == kObjectID_Volume_Output_Master && address && data && size) {
        if(address->mSelector == kAudioLevelControlPropertyDecibelRange) {
            if(capacity < sizeof(AudioValueRange)) return kAudioHardwareBadPropertySizeError;
            *((AudioValueRange*)data) = (AudioValueRange){-96.0, 0.0};
            *size = sizeof(AudioValueRange);
            return noErr;
        }
        if(address->mSelector == kAudioLevelControlPropertyDecibelValue ||
           address->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels ||
           address->mSelector == kAudioLevelControlPropertyConvertDecibelsToScalar) {
            if(capacity < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            Float32 value = 0;
            if(address->mSelector == kAudioLevelControlPropertyDecibelValue) {
                pthread_mutex_lock(&gPlugIn_StateMutex);
                value = gVolume_Output_Master_Value;
                pthread_mutex_unlock(&gPlugIn_StateMutex);
            } else value = *((Float32*)data);
            if(address->mSelector == kAudioLevelControlPropertyConvertDecibelsToScalar)
                value = value <= -96 ? 0 : powf(10.0f, fminf(0, value) / 20.0f);
            else value = value <= 0 ? -96 : fmaxf(-96, 20.0f * log10f(fminf(1, value)));
            *((Float32*)data) = value;
            *size = sizeof(Float32);
            return noErr;
        }
    }
    return NullAudio_GetPropertyData(driver, object, pid, address, qualifierSize, qualifier, capacity, size, data);
}

static OSStatus Airplay_Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    OSStatus status = NullAudio_Initialize(driver, host);
    if(status != noErr) return status;
    gVolume_Output_Master_Value = 1.0;
    CFPropertyListRef stored = NULL;
    host->CopyFromStorage(host, CFSTR("airplay.outputVolume"), &stored);
    if(stored) {
        Float32 value = 1;
        if(CFGetTypeID(stored) == CFNumberGetTypeID() &&
           CFNumberGetValue((CFNumberRef)stored, kCFNumberFloat32Type, &value) && isfinite(value))
            gVolume_Output_Master_Value = fmaxf(0, fminf(1, value));
        CFRelease(stored);
    }
    return noErr;
}

static OSStatus Airplay_SetData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                               const AudioObjectPropertyAddress* address, UInt32 qualifierSize,
                               const void* qualifier, UInt32 size, const void* data) {
    if(Airplay_Hidden(object)) return kAudioHardwareBadObjectError;
    if(object == kObjectID_Volume_Output_Master && address && data &&
       (address->mSelector == kAudioLevelControlPropertyScalarValue || address->mSelector == kAudioLevelControlPropertyDecibelValue)) {
        if(size != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        Float32 value = *((const Float32*)data);
        if(!isfinite(value)) return kAudioHardwareIllegalOperationError;
        if(address->mSelector == kAudioLevelControlPropertyDecibelValue)
            value = value <= -96 ? 0 : powf(10.0f, fminf(0, value) / 20.0f);
        AudioObjectPropertyAddress scalar = *address;
        scalar.mSelector = kAudioLevelControlPropertyScalarValue;
        OSStatus status = NullAudio_SetPropertyData(driver, object, pid, &scalar, qualifierSize, qualifier, sizeof(value), &value);
        if(status == noErr) {
            pthread_mutex_lock(&gPlugIn_StateMutex);
            value = gVolume_Output_Master_Value;
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            CFNumberRef stored = CFNumberCreate(NULL, kCFNumberFloat32Type, &value);
            gPlugIn_Host->WriteToStorage(gPlugIn_Host, CFSTR("airplay.outputVolume"), stored);
            CFRelease(stored);
        }
        return status;
    }
    return NullAudio_SetPropertyData(driver, object, pid, address, qualifierSize, qualifier, size, data);
}

void* PlaystationAirplay_Create(CFAllocatorRef allocator, CFUUIDRef type) {
    gAudioServerPlugInDriverInterface.HasProperty = Airplay_HasProperty;
    gAudioServerPlugInDriverInterface.GetPropertyDataSize = Airplay_GetSize;
    gAudioServerPlugInDriverInterface.GetPropertyData = Airplay_GetData;
    gAudioServerPlugInDriverInterface.SetPropertyData = Airplay_SetData;
    gAudioServerPlugInDriverInterface.Initialize = Airplay_Initialize;
    gDevice_SampleRate = 48000.0;
    return NullAudio_Create(allocator, type);
}
