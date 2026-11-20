import AppKit
import CoreAudio
import Darwin
import Foundation
import OSLog

// The same signed executable runs a tiny, non-UI child that watches the host.
// It needs no installed service and survives an abrupt host process exit.
final class OutputLifetime {
    static let argument = "--watch-audio-output"
    private var monitor: Process?
    private let history = Pipe()
    private var finishing = false
    private let bufferTuning = OutputBufferTuning()
    private let logger = Logger(subsystem: "de.raudzis.playlink", category: "OutputLifetime")
    var onFailure: (() -> Void)?

    func start() throws {
        guard VirtualOutput.driverBox() != nil else { return }
        guard let executable = Bundle.main.executableURL else {
            throw PlayLinkError.message("Could not locate the audio output monitor.")
        }
        let child = Process()
        child.executableURL = executable
        child.arguments = [Self.argument, String(getpid())]
        child.standardInput = history
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, !self.finishing else { return }
                self.onFailure?()
            }
        }
        try child.run()
        monitor = child
        bufferTuning.onRemember = { [weak self] frames in
            self?.sendHistory(["originalBufferFrames": frames])
        }
        try VirtualOutput.setPublished(true)
    }

    func tuneBuffer() {
        guard monitor?.isRunning == true else { return }
        let before = VirtualOutput.bufferFrames()
        do {
            try bufferTuning.apply()
            if let before, let after = VirtualOutput.bufferFrames(), before != after {
                logger.notice("Virtual output buffer frames=\(before) -> \(after)")
            }
        } catch { logger.notice("Virtual output buffer tuning unavailable; retaining supported settings") }
    }

    func remember(_ uid: String) {
        sendHistory(["uid": uid])
    }

    private func sendHistory(_ message: [String: Any]) {
        guard monitor?.isRunning == true,
              let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? history.fileHandleForWriting.write(contentsOf: data + Data([10]))
    }

    func finish() throws {
        finishing = true
        // The model has already stopped capture and restored the output.
        if !Self.anotherHostIsRunning(excluding: getpid()), VirtualOutput.defaultUID() != VirtualOutput.uid {
            try bufferTuning.restore()
            try VirtualOutput.setPublished(false)
        }
        try? history.fileHandleForWriting.close()
    }

    private static func anotherHostIsRunning(excluding pid: pid_t) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "de.raudzis.playlink")
            .contains { $0.processIdentifier != pid && !$0.isTerminated }
    }

    static func runMonitor(parent: pid_t) -> Never {
        let queue = DispatchQueue(label: "de.raudzis.playlink.output-lifetime")
        let logger = Logger(subsystem: "de.raudzis.playlink", category: "OutputLifetime")
        let processExit = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: queue)
        let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else { exit(1) }
        var pending = Data()
        var previousUID: String?
        var originalBufferFrames: UInt32?
        var finished = false

        func drainHistory() -> Bool {
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                if count == 0 { return true }
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                pending.append(contentsOf: bytes.prefix(count))
                while let end = pending.firstIndex(of: 10) {
                    if let message = try? JSONSerialization.jsonObject(with: pending[..<end]) as? [String: Any] {
                        if let uid = message["uid"] as? String, uid != VirtualOutput.uid { previousUID = uid }
                        if let frames = message["originalBufferFrames"] as? UInt32 { originalBufferFrames = frames }
                    }
                    pending.removeSubrange(...end)
                }
                if pending.count > 65536 { pending.removeAll() }
            }
        }

        func finish() {
            guard !finished else { return }
            finished = true
            processExit.cancel()
            input.cancel()
            if !anotherHostIsRunning(excluding: parent) {
                let routing = AudioOutputRouting()
                if let previousUID { routing.remember(previousUID) }
                do {
                    try routing.restore()
                    if let originalBufferFrames {
                        try OutputBufferTuning.restore(original: originalBufferFrames)
                        logger.notice("Restored virtual output buffer frames=\(originalBufferFrames)")
                    }
                    try VirtualOutput.setPublished(false)
                    logger.notice("Host ended; restored output and unpublished Playstation Airplay")
                } catch {
                    // Keep a selected device visible if no safe local output
                    // exists, rather than letting macOS pick an arbitrary one.
                    logger.error("Could not restore/unpublish the audio output")
                }
            }
            exit(0)
        }

        processExit.setEventHandler { _ = drainHistory(); finish() }
        input.setEventHandler { if drainHistory() { finish() } }
        processExit.resume()
        input.resume()
        // Cover a host that died before this child registered its exit source.
        if getppid() != parent || kill(parent, 0) != 0 { queue.async { _ = drainHistory(); finish() } }
        dispatchMain()
    }
}
