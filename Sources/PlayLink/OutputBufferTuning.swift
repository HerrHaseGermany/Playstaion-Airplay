import Foundation

// Scope a smaller buffer to this app's own virtual device. Never increase an
// already smaller buffer or overwrite a later adjustment by another client.
final class OutputBufferTuning {
    static let preferredFrames: UInt32 = 128
    private let current: () -> UInt32?
    private let supported: (UInt32) -> Bool
    private let set: (UInt32) throws -> Void
    private var original: UInt32?
    private var attempted = false
    var onRemember: ((UInt32) -> Void)?

    init(current: @escaping () -> UInt32? = VirtualOutput.bufferFrames,
         supported: @escaping (UInt32) -> Bool = VirtualOutput.supportsBufferFrames,
         set: @escaping (UInt32) throws -> Void = VirtualOutput.setBufferFrames) {
        self.current = current
        self.supported = supported
        self.set = set
    }

    func apply() throws {
        guard !attempted, let frames = current() else { return }
        attempted = true
        guard frames > Self.preferredFrames, supported(Self.preferredFrames) else { return }
        original = frames
        // Forward the rollback value to the watchdog before changing hardware.
        onRemember?(frames)
        try set(Self.preferredFrames)
    }

    func restore() throws {
        if let original { try Self.restore(original: original, current: current, set: set) }
    }

    static func restore(original: UInt32, current: () -> UInt32? = VirtualOutput.bufferFrames,
                        set: (UInt32) throws -> Void = VirtualOutput.setBufferFrames) throws {
        guard current() == preferredFrames else { return }
        try set(original)
    }
}
