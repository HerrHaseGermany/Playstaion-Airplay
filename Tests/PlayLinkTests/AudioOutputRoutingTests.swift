import XCTest
@testable import PlayLink

final class AudioOutputRoutingTests: XCTestCase {
    private final class Outputs {
        var current: String? = "headphones"
        var available: Set<String> = ["headphones", "speakers", VirtualOutput.uid]
        var builtIn: String? = "speakers"
        var selected: [String] = []
        var reject: String?
        lazy var routing = AudioOutputRouting(current: { self.current },
            available: { self.available.contains($0) }, builtIn: { self.builtIn },
            select: {
                if self.reject == $0 { throw PlayLinkError.message("Device disappeared") }
                self.selected.append($0)
                self.current = $0
            })
    }

    func testStartAndStopRestoreTheOriginalOutput() throws {
        let outputs = Outputs()
        try outputs.routing.start()
        outputs.routing.observe() // The app's own notification must not overwrite history.
        try outputs.routing.start() // Repeated refresh/start is harmless.
        try outputs.routing.restore()
        XCTAssertEqual(outputs.selected, [VirtualOutput.uid, "headphones"])
    }

    func testStopRespectsAManualChangeBeforeItsNotificationArrives() throws {
        let outputs = Outputs()
        try outputs.routing.start()
        outputs.current = "speakers"
        try outputs.routing.restore()
        XCTAssertEqual(outputs.current, "speakers")
        XCTAssertEqual(outputs.selected, [VirtualOutput.uid])
        try outputs.routing.start()
        try outputs.routing.restore()
        XCTAssertEqual(outputs.current, "speakers")
    }

    func testExternalSelectionOfAirplayRetainsTheLastObservedOutput() throws {
        let outputs = Outputs()
        outputs.routing.observe()
        outputs.current = VirtualOutput.uid
        outputs.routing.observe()
        try outputs.routing.start()
        try outputs.routing.restore()
        XCTAssertEqual(outputs.selected, ["headphones"])
    }

    func testMissingPreviousDeviceFallsBackToBuiltInSpeakers() throws {
        let outputs = Outputs()
        try outputs.routing.start()
        outputs.available.remove("headphones")
        try outputs.routing.restore()
        XCTAssertEqual(outputs.current, "speakers")
    }

    func testDeviceDisappearingDuringRestorationUsesFallback() throws {
        let outputs = Outputs()
        try outputs.routing.start()
        outputs.reject = "headphones"
        try outputs.routing.restore()
        XCTAssertEqual(outputs.current, "speakers")
    }

    func testLaunchingWithAirplayAlreadySelectedUsesBuiltInFallback() throws {
        let outputs = Outputs()
        outputs.current = VirtualOutput.uid
        try outputs.routing.start()
        try outputs.routing.restore()
        XCTAssertEqual(outputs.selected, ["speakers"])
    }

    func testNoFallbackReportsFailureWithoutChoosingAnArbitraryOutput() throws {
        let outputs = Outputs()
        try outputs.routing.start()
        outputs.available = [VirtualOutput.uid, "another-users-room"]
        XCTAssertThrowsError(try outputs.routing.restore())
        XCTAssertEqual(outputs.current, VirtualOutput.uid)
        XCTAssertEqual(outputs.selected, [VirtualOutput.uid])
    }

    func testUnknownCurrentOutputDoesNotSwitchBlindly() throws {
        let outputs = Outputs()
        outputs.current = nil
        XCTAssertThrowsError(try outputs.routing.start())
        XCTAssertTrue(outputs.selected.isEmpty)
    }
}
