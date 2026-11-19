import Foundation

final class DiscordBridge {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let queue = DispatchQueue(label: "de.raudzis.playlink.events")
    private var pending = Data()
    var onEvent: ((String, String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var descriptor: Int32 { input.fileHandleForWriting.fileDescriptor }

    func start(token: String, channelID: String) throws {
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
        let config = try JSONSerialization.data(withJSONObject: ["token": token, "channelId": channelID])
        try input.fileHandleForWriting.write(contentsOf: config + Data([10]))
    }

    private func consume(_ data: Data) {
        pending.append(data)
        while let end = pending.firstIndex(of: 10) {
            let line = pending[..<end]
            if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
               let kind = event["event"] as? String {
                onEvent?(kind, event[kind == "ready" ? "channel" : "message"] as? String ?? "")
            }
            pending.removeSubrange(...end)
        }
        if pending.count > 65536 { pending.removeAll() }
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    deinit {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
