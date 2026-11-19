import AVFoundation
import Darwin

enum PlayLinkError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// Tap lifecycle is confined to controlQueue; PCM state is confined to queue.
// Callbacks are installed before capture starts and are not changed while running.
final class AudioCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "de.raudzis.playlink.audio")
    private let controlQueue = DispatchQueue(label: "de.raudzis.playlink.audio-control")
    private var tap: SystemAudioTap?
    private var outputVolume: OutputVolumeObserver?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var pending = Data()
    private var partialFrame = Data()
    private var descriptor: Int32 = -1
    private var lastMeter = Date.distantPast
    private var gain: Float = 1
    private var outputGain: Float = 1
    var onLevel: ((Float) -> Void)?
    var onError: ((String) -> Void)?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 48_000, channels: 2, interleaved: true)!

    func setGain(_ value: Float) { queue.async { self.gain = value } }
    func setOutputGain(_ value: Float) {
        queue.async { self.outputGain = value.isFinite ? max(0, min(1, value)) : 0 }
    }

    func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async { [self] in
                let capture = SystemAudioTap(controlQueue: self.controlQueue, audioQueue: self.queue,
                    receive: { [weak self] in self?.process($0) },
                    reportError: { [weak self] in self?.onError?($0) })
                do {
                    try capture.prepare()
                    self.tap = capture
                    let volume = OutputVolumeObserver(queue: self.controlQueue,
                        onGain: { [weak self] in self?.setOutputGain($0) },
                        onError: { [weak self] in self?.onError?($0) })
                    self.outputVolume = volume
                    try volume.start()
                    continuation.resume()
                } catch {
                    self.outputVolume?.stop()
                    self.outputVolume = nil
                    capture.stop()
                    self.tap = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start(descriptor: Int32) async throws {
        try attachPipe(descriptor)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controlQueue.async {
                do {
                    guard let tap = self.tap else { throw PlayLinkError.message("Audio capture is not prepared.") }
                    try tap.start()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func attachPipe(_ descriptor: Int32) throws {
        queue.sync { self.descriptor = descriptor }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw PlayLinkError.message("Could not configure the audio pipe.")
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            controlQueue.async {
                self.tap?.stop()
                self.tap = nil
                self.outputVolume?.stop()
                self.outputVolume = nil
                self.queue.sync {
                    self.descriptor = -1
                    self.pending.removeAll()
                    self.partialFrame.removeAll()
                }
                continuation.resume()
            }
        }
    }

    func process(_ input: AVAudioPCMBuffer) {
        guard descriptor >= 0, input.frameLength > 0 else { return }
        let format = input.format
        let count = Int(input.frameLength)
        if inputFormat != format {
            inputFormat = format
            converter = AVAudioConverter(from: format, to: outputFormat)
        }
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(ceil(Double(count) * 48_000 / format.sampleRate)) + 64) else {
            report("Could not create the audio converter."); return
        }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard result != .error else { report(error?.localizedDescription ?? "Audio conversion failed."); return }
        guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
        let sampleCount = Int(output.frameLength) * 2
        var peak: Float = 0
        for index in 0..<sampleCount {
            let value = Float(samples[index]) * gain * outputGain
            samples[index] = Int16(max(-32768, min(32767, value)))
            peak = max(peak, abs(value) / 32768)
        }
        pending.append(UnsafeBufferPointer(start: samples, count: sampleCount))
        // macOS PIPE_BUF can be smaller than an audio frame. Preserve short
        // writes so a stalled reader never corrupts the stereo sample order.
        while !partialFrame.isEmpty || pending.count >= 3840 {
            if partialFrame.isEmpty {
                partialFrame = Data(pending.prefix(3840))
                pending.removeFirst(3840)
            }
            let written = partialFrame.withUnsafeBytes { write(descriptor, $0.baseAddress!, partialFrame.count) }
            if written < 0 && errno != EAGAIN && errno != EINTR {
                descriptor = -1
                report("The Discord audio sender closed its connection.")
                return
            }
            if written > 0 {
                partialFrame.removeFirst(written)
            } else {
                // Retain the unfinished frame, discard newer complete frames.
                pending.removeFirst((pending.count / 3840) * 3840)
                break
            }
        }
        if Date().timeIntervalSince(lastMeter) > 0.1 {
            lastMeter = Date()
            onLevel?(min(1, peak))
        }
    }

    private func report(_ text: String) { onError?(text) }
}
