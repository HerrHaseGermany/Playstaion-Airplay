import XCTest
@testable import PlayLink

final class OutputBufferTuningTests: XCTestCase {
    func testTuningRemembersBeforeChangingAndRestoresOnExit() throws {
        var frames: UInt32 = 512
        var remembered: UInt32?
        let tuning = OutputBufferTuning(current: { frames }, supported: { _ in true }, set: { frames = $0 })
        tuning.onRemember = { value in
            XCTAssertEqual(frames, 512)
            remembered = value
        }
        try tuning.apply()
        XCTAssertEqual(remembered, 512)
        XCTAssertEqual(frames, 128)
        try tuning.apply()
        try tuning.restore()
        XCTAssertEqual(frames, 512)
    }

    func testAlreadySmallerOrUnsupportedBuffersAreUnchanged() throws {
        for initial: UInt32 in [64, 128, 512] {
            var frames = initial
            let tuning = OutputBufferTuning(current: { frames }, supported: { _ in false }, set: { frames = $0 })
            try tuning.apply()
            try tuning.restore()
            XCTAssertEqual(frames, initial)
        }
    }

    func testDoesNotIncreaseASmallerSupportedBuffer() throws {
        var frames: UInt32 = 64
        let tuning = OutputBufferTuning(current: { frames }, supported: { _ in true }, set: { frames = $0 })
        try tuning.apply()
        XCTAssertEqual(frames, 64)
    }

    func testLaterManualBufferChangeTakesPriority() throws {
        var frames: UInt32 = 512
        let tuning = OutputBufferTuning(current: { frames }, supported: { _ in true }, set: { frames = $0 })
        try tuning.apply()
        frames = 256
        try tuning.restore()
        XCTAssertEqual(frames, 256)
    }

    func testWatchdogRestoresFromForwardedSnapshot() throws {
        var frames: UInt32? = 128
        try OutputBufferTuning.restore(original: 512, current: { frames }, set: { frames = $0 })
        XCTAssertEqual(frames, 512)
        frames = nil
        try OutputBufferTuning.restore(original: 512, current: { frames }, set: { frames = $0 })
        XCTAssertNil(frames)
    }

    func testRejectedTuningDoesNotRestoreOverExistingValue() throws {
        let tuning = OutputBufferTuning(current: { 512 }, supported: { _ in true }, set: { _ in
            throw PlayLinkError.message("Unsupported")
        })
        XCTAssertThrowsError(try tuning.apply())
        XCTAssertNoThrow(try tuning.restore())
    }
}
