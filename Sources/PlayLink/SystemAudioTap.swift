import CoreAudio
import AVFoundation
import Foundation
import OSLog

// A private, tap-only device has no microphone or physical input streams.
// This API requests system audio recording permission independently of screens.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var description: CATapDescription?
    private var processListener: AudioObjectPropertyListenerBlock?
    private let controlQueue: DispatchQueue
    private let audioQueue: DispatchQueue
    private let receive: (AVAudioPCMBuffer) -> Void
    private let reportError: (String) -> Void
    private var started = false
    private var loggedLayout = false
    private let logger = Logger(subsystem: "de.raudzis.playlink", category: "SystemAudioTap")

    init(controlQueue: DispatchQueue, audioQueue: DispatchQueue,
         receive: @escaping (AVAudioPCMBuffer) -> Void, reportError: @escaping (String) -> Void) {
        self.controlQueue = controlQueue
        self.audioQueue = audioQueue
        self.receive = receive
        self.reportError = reportError
    }

    func prepare() throws {
        do {
            guard VirtualOutput.deviceID() != nil else {
                throw PlayLinkError.message("Install the Playstation Airplay audio output and restart your Mac first.")
            }
            let config = CATapDescription(excludingProcesses: try excludedProcesses(),
                                          deviceUID: VirtualOutput.uid, stream: 0)
            config.uuid = UUID()
            config.name = "Playstation Airplay System Audio"
            config.isPrivate = true
            config.muteBehavior = .unmuted
            if #available(macOS 26.0, *) {
                config.bundleIDs = [Bundle.main.bundleIdentifier ?? "de.raudzis.playlink",
                                    "com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary"]
                config.isProcessRestoreEnabled = true
            }
            description = config
            try check(AudioHardwareCreateProcessTap(config, &tapID), "Create system audio tap")

            var format = AudioStreamBasicDescription()
            var address = property(kAudioTapPropertyFormat)
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "Read tap audio format")
            guard let audioFormat = AVAudioFormat(streamDescription: &format),
                  audioFormat.channelCount == 2, format.mBytesPerFrame > 0 else {
                throw PlayLinkError.message("The system audio tap did not provide a valid stereo format.")
            }

            let device: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Playstation Airplay Audio Capture",
                kAudioAggregateDeviceUIDKey: "de.raudzis.playlink.audio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [],
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: config.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try check(AudioHardwareCreateAggregateDevice(device as CFDictionary, &deviceID), "Create audio capture device")
            // This device is private to the capture session; no system output
            // device or persistent user setting is changed.
            var bufferAddress = property(kAudioDevicePropertyBufferFrameSize)
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &bufferAddress, &settable) == noErr, settable.boolValue {
                var frames: UInt32 = 128
                let status = AudioObjectSetPropertyData(deviceID, &bufferAddress, 0, nil,
                    UInt32(MemoryLayout<UInt32>.size), &frames)
                if status == noErr {
                    var size = UInt32(MemoryLayout<UInt32>.size)
                    if AudioObjectGetPropertyData(deviceID, &bufferAddress, 0, nil, &size, &frames) == noErr {
                        logger.notice("Private capture buffer frames=\(frames)")
                    }
                }
            }
            logger.notice("Tap format: rate=\(format.mSampleRate) channels=\(format.mChannelsPerFrame) bytesPerFrame=\(format.mBytesPerFrame) interleaved=\(audioFormat.isInterleaved)")
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, audioQueue) {
                [weak self] _, input, _, _, _ in
                guard let self else { return }
                let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                if !self.loggedLayout {
                    self.loggedLayout = true
                    self.logger.notice("First callback: buffers=\(source.count) firstBytes=\(source.first?.mDataByteSize ?? 0) firstChannels=\(source.first?.mNumberChannels ?? 0)")
                }
                guard let pcm = Self.copyBufferList(input, format: audioFormat) else { return }
                self.receive(pcm)
            }, "Prepare audio capture callback")

            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.refreshExclusions()
            }
            var processesAddress = property(kAudioHardwarePropertyProcessObjectList)
            try check(AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                &processesAddress, controlQueue, listener), "Watch audio processes")
            processListener = listener
        } catch {
            stop()
            throw error
        }
    }

    static func copyBufferList(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard let first = source.first, first.mDataByteSize > 0, bytesPerFrame > 0,
              Int(first.mDataByteSize) % bytesPerFrame == 0 else { return nil }
        let frames = AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        // frameLength sets each destination AudioBuffer's usable mDataByteSize.
        pcm.frameLength = frames
        let destination = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in 0..<source.count {
            guard let from = source[index].mData, let to = destination[index].mData,
                  source[index].mNumberChannels == destination[index].mNumberChannels,
                  source[index].mDataByteSize == destination[index].mDataByteSize else { return nil }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        return pcm
    }

    func start() throws {
        guard let ioProc else { throw PlayLinkError.message("The system audio tap is not prepared.") }
        // macOS prompts for audio-only permission here, never screen recording.
        try check(AudioDeviceStart(deviceID, ioProc), "Start system audio recording")
        started = true
    }

    func stop() {
        if let listener = processListener {
            var address = property(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                &address, controlQueue, listener)
            processListener = nil
        }
        if let ioProc {
            if started { AudioDeviceStop(deviceID, ioProc) }
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
        }
        ioProc = nil
        started = false
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        description = nil
    }

    private func refreshExclusions() {
        guard tapID != kAudioObjectUnknown, let description else { return }
        do {
            let processes = try excludedProcesses()
            guard processes != description.processes else { return }
            description.processes = processes
            var address = property(kAudioTapPropertyDescription)
            var value = Unmanaged.passUnretained(description).toOpaque()
            try check(AudioObjectSetPropertyData(tapID, &address, 0, nil,
                UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &value), "Update Discord audio exclusion")
        } catch { reportError(error.localizedDescription) }
    }

    private func excludedProcesses() throws -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = property(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size), "Read audio process list")
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if !processes.isEmpty {
            let status = processes.withUnsafeMutableBytes {
                AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
            }
            try check(status, "Read audio processes")
        }
        return processes.filter { process in
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = property(kAudioProcessPropertyPID)
            if AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
               pid == getpid() { return true }
            var bundleID: CFString = "" as CFString
            var bundleSize = UInt32(MemoryLayout<CFString>.size)
            var bundleAddress = property(kAudioProcessPropertyBundleID)
            let status = withUnsafeMutablePointer(to: &bundleID) {
                AudioObjectGetPropertyData(process, &bundleAddress, 0, nil, &bundleSize, $0)
            }
            guard status == noErr else { return false }
            let id = bundleID as String
            return id == Bundle.main.bundleIdentifier || id.lowercased().contains("discord")
        }.sorted()
    }

    private func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw PlayLinkError.message("\(operation) failed (\(status)). Allow this app under Privacy & Security → Screen & System Audio Recording → System Audio Recording Only, then reconnect.")
        }
    }

    deinit { stop() }
}
