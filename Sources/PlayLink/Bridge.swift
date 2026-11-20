import Foundation
import Darwin
import OSLog

final class DiscordBridge {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let queue = DispatchQueue(label: "de.raudzis.playlink.events")
    private var pending = Data()
    private let logger = Logger(subsystem: "de.raudzis.playlink", category: "DiscordBridge")
    var onEvent: ((String, String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var descriptor: Int32 { input.fileHandleForWriting.fileDescriptor }

    func start(token: String, channelID: String, followUser: Bool = false, userID: String = "") throws {
        guard let resources = Bundle.main.resourceURL else { throw PlayLinkError.message("Missing app resources.") }
        let runtime = resources.appendingPathComponent("runtime/node")
        let script = resources.appendingPathComponent("backend/bot/bridge.mjs")
        guard FileManager.default.isExecutableFile(atPath: runtime.path),
              FileManager.default.fileExists(atPath: script.path) else {
            throw PlayLinkError.message("The Discord runtime is missing. Rebuild Playstation Airplay with scripts/build.sh.")
        }
        process.executableURL = runtime
        process.arguments = [script.path]
        process.currentDirectoryURL = resources.appendingPathComponent("backend")
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "NODE_ENV": "production"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { [weak self] in self?.consume(data) }
        }
        // Drain stderr without persisting raw library diagnostics or credentials.
        errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self] child in self?.onExit?(child.terminationStatus) }
        try process.run()
        let config = try JSONSerialization.data(withJSONObject: [
            "token": token, "channelId": channelID, "followUser": followUser, "userId": userID
        ])
        try input.fileHandleForWriting.write(contentsOf: config + Data([10]))
    }

    private func consume(_ data: Data) {
        pending.append(data)
        while let end = pending.firstIndex(of: 10) {
            let line = pending[..<end]
            if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let kind = event["event"] as? String {
                if kind == "stopped" {
                    let confirmed = event["confirmed"] as? Bool ?? false
                    let elapsed = event["elapsedMs"] as? Int ?? -1
                    logger.notice("Discord leave confirmed=\(confirmed) elapsedMs=\(elapsed)")
                }
                onEvent?(kind, event[kind == "ready" ? "channel" : "message"] as? String ?? "")
            }
            pending.removeSubrange(...end)
        }
        if pending.count > 65536 { pending.removeAll() }
    }

    func stop() async {
        // Capture callbacks have stopped before EOF requests a graceful logout.
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        // SIGTERM also reaches a sender whose stdin is paused during login.
        process.terminate()
        let child = process
        let watchdog = DispatchWorkItem {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 7, execute: watchdog)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                child.waitUntilExit()
                continuation.resume()
            }
        }
        watchdog.cancel()
    }

    deinit {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
