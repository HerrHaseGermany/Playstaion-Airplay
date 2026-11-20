import CoreAudio
import Foundation

enum VirtualOutput {
    static let uid = "de.raudzis.playlink.output"

    static func supportsSystemVolume() -> Bool {
        guard let device = deviceID() else { return false }
        return [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute].allSatisfy { selector in
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectHasProperty(device, &address)
        }
    }

    static func deviceID() -> AudioObjectID? {
        deviceID(forUID: uid)
    }

    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func defaultDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, &size, &device) == noErr else { return nil }
        return device
    }

    static func select() throws {
        try select(uid: uid)
    }

    static func select(uid: String) throws {
        guard var device = deviceID(forUID: uid), isAvailableOutput(device) else {
            throw PlayLinkError.message(uid == self.uid
                ? "Install the audio output and restart your Mac first."
                : "The previous audio output is no longer available.")
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device)
        guard status == noErr else { throw PlayLinkError.message("Could not select the audio output (\(status)).") }
    }

    static func defaultUID() -> String? { defaultDevice().flatMap(deviceUID) }

    static func driverBox() -> AudioObjectID? {
        var bundle = "de.raudzis.playlink.audio" as CFString
        var plugin: AudioObjectID = 0
        var address = property(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let result = withUnsafePointer(to: &bundle) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), $0, &size, &plugin)
        }
        guard result == noErr, plugin != kAudioObjectUnknown else { return nil }
        address = property(kAudioPlugInPropertyBoxList)
        guard AudioObjectGetPropertyDataSize(plugin, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var boxes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = boxes.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(plugin, &address, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? boxes.first : nil
    }

    static func setPublished(_ published: Bool) throws {
        guard let box = driverBox() else { return }
        var address = property(kAudioBoxPropertyAcquired)
        var value: UInt32 = published ? 1 : 0
        let status = AudioObjectSetPropertyData(box, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else {
            throw PlayLinkError.message("Could not \(published ? "show" : "hide") the Playstation Airplay output (\(status)).")
        }
    }

    static func bufferFrames() -> UInt32? {
        guard let device = deviceID() else { return nil }
        var address = property(kAudioDevicePropertyBufferFrameSize)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func supportsBufferFrames(_ frames: UInt32) -> Bool {
        guard let device = deviceID() else { return false }
        var address = property(kAudioDevicePropertyBufferFrameSize)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return false }
        address.mSelector = kAudioDevicePropertyBufferFrameSizeRange
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &range) == noErr
            && Double(frames) >= range.mMinimum && Double(frames) <= range.mMaximum
    }

    static func setBufferFrames(_ frames: UInt32) throws {
        guard let device = deviceID() else { throw PlayLinkError.message("The audio output is not available.") }
        var address = property(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        guard status == noErr else { throw PlayLinkError.message("Could not change the audio output buffer (\(status)).") }
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        var address = property(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func isAvailableOutput(uid: String) -> Bool {
        deviceID(forUID: uid).map(isAvailableOutput) ?? false
    }

    private static func isAvailableOutput(_ device: AudioObjectID) -> Bool {
        var aliveAddress = property(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var streamsAddress = property(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var streamsSize: UInt32 = 0
        return AudioObjectGetPropertyData(device, &aliveAddress, 0, nil, &size, &alive) == noErr
            && alive != 0
            && AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamsSize) == noErr
            && streamsSize > 0
    }

    static func builtInOutputUID() -> String? {
        var address = property(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let result = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { return nil }
        for device in devices where isAvailableOutput(device) {
            var transportAddress = property(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
               transport == kAudioDeviceTransportTypeBuiltIn {
                return deviceUID(device)
            }
        }
        return nil
    }

    private static func property(_ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}
