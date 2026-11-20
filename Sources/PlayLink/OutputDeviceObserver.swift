import CoreAudio
import Foundation

// A model-owned observer keeps working when no app window is visible.
final class OutputDeviceObserver {
    private var listener: AudioObjectPropertyListenerBlock?
    private var addresses: [AudioObjectPropertyAddress] = []

    func start(onChange: @escaping () -> Void) throws {
        guard listener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        self.listener = listener
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                &address, .main, listener)
            guard status == noErr else {
                stop()
                throw PlayLinkError.message("Could not watch audio output changes (\(status)).")
            }
            addresses.append(address)
        }
    }

    func stop() {
        if let listener {
            for var address in addresses {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                    &address, .main, listener)
            }
        }
        addresses.removeAll()
        listener = nil
    }

    deinit { stop() }
}

struct OutputSelection {
    enum Action: Equatable { case start, stop }
    private var previous: Bool?

    mutating func update(selected: Bool) -> Action? {
        guard previous != selected else { return nil }
        previous = selected
        return selected ? .start : .stop
    }
}
