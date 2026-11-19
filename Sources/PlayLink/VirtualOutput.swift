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
        guard var device = deviceID() else {
            throw PlayLinkError.message("Install the audio output and restart your Mac first.")
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device)
        guard status == noErr else { throw PlayLinkError.message("Could not select the audio output (\(status)).") }
    }
}
