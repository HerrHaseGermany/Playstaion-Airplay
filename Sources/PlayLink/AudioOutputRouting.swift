import Foundation

// Main-actor owned. Stable UIDs survive device ID changes and reconnects.
final class AudioOutputRouting {
    private let current: () -> String?
    private let available: (String) -> Bool
    private let builtIn: () -> String?
    private let select: (String) throws -> Void
    private var previousUID: String?
    var onRemember: ((String) -> Void)?

    init(current: @escaping () -> String? = VirtualOutput.defaultUID,
         available: @escaping (String) -> Bool = VirtualOutput.isAvailableOutput,
         builtIn: @escaping () -> String? = VirtualOutput.builtInOutputUID,
         select: @escaping (String) throws -> Void = VirtualOutput.select) {
        self.current = current
        self.available = available
        self.builtIn = builtIn
        self.select = select
    }

    func observe() {
        if let uid = current() { remember(uid) }
    }

    func remember(_ uid: String) {
        guard uid != VirtualOutput.uid, previousUID != uid else { return }
        previousUID = uid
        onRemember?(uid)
    }

    func start() throws {
        guard let uid = current() else {
            throw PlayLinkError.message("Could not read the current audio output. Choose an output in macOS Sound settings and retry.")
        }
        guard uid != VirtualOutput.uid else { return }
        remember(uid)
        try select(VirtualOutput.uid)
    }

    func restore() throws {
        // A manual/device-driven change always takes priority, even if its
        // Core Audio notification has not reached the model yet.
        guard current() == VirtualOutput.uid else { observe(); return }
        if let previousUID, available(previousUID) {
            do { try select(previousUID); return }
            catch { /* The device may have disappeared since the availability check. */ }
        }
        let target = builtIn()
        guard let target, target != VirtualOutput.uid, available(target) else {
            throw PlayLinkError.message("No previous or built-in audio output is available. Choose another output in macOS Sound settings.")
        }
        try select(target)
    }
}
