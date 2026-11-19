import CoreAudio
import Foundation

// Accessed only from the audio capture control queue.
final class OutputVolumeObserver {
    private var device = AudioObjectID(kAudioObjectUnknown)
    private let queue: DispatchQueue
    private let onGain: (Float) -> Void
    private let onError: (String) -> Void
    private var listener: AudioObjectPropertyListenerBlock?
    private var addresses: [AudioObjectPropertyAddress] = []

    init(queue: DispatchQueue, onGain: @escaping (Float) -> Void, onError: @escaping (String) -> Void) {
        self.queue = queue
        self.onGain = onGain
        self.onError = onError
    }

    func start() throws {
        guard let device = VirtualOutput.deviceID(), VirtualOutput.supportsSystemVolume() else {
            onGain(1) // Keep existing drivers usable until their update is loaded.
            return
        }
        self.device = device
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.publishGain() }
        self.listener = listener
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, listener)
            guard status == noErr else {
                stop()
                throw PlayLinkError.message("Could not watch Mac output volume (\(status)).")
            }
            addresses.append(address)
        }
        publishGain()
    }

    private func publishGain() {
        guard device != kAudioObjectUnknown else { return }
        var volume: Float32 = 1
        var mute: UInt32 = 0
        var volumeAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let volumeStatus = AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &volumeSize, &volume)
        let muteStatus = AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &mute)
        guard volumeStatus == noErr, muteStatus == noErr, volume.isFinite else {
            onError("Could not read Mac output volume. Stop and reconnect.")
            return
        }
        onGain(mute != 0 ? 0 : max(0, min(1, volume)))
    }

    func stop() {
        if let listener {
            for var address in addresses {
                AudioObjectRemovePropertyListenerBlock(device, &address, queue, listener)
            }
        }
        listener = nil
        addresses.removeAll()
        device = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}
