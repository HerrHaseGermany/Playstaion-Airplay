import XCTest
@testable import PlayLink

final class OutputSelectionTests: XCTestCase {
    func testSelectedOutputAtLaunchStartsStreaming() {
        var selection = OutputSelection()
        XCTAssertEqual(selection.update(selected: true), .start)
        XCTAssertNil(selection.update(selected: true))
    }

    func testSwitchAwayThenBackStopsAndRestarts() {
        var selection = OutputSelection()
        XCTAssertEqual(selection.update(selected: false), .stop)
        XCTAssertEqual(selection.update(selected: true), .start)
        XCTAssertEqual(selection.update(selected: false), .stop)
        XCTAssertNil(selection.update(selected: false))
        XCTAssertEqual(selection.update(selected: true), .start)
    }

    func testRefreshDoesNotUndoManualStopOrRetryErrors() {
        var selection = OutputSelection()
        XCTAssertEqual(selection.update(selected: true), .start)
        // Window/menu refreshes and device-list notifications must not reconnect
        // after a manual stop or an authentication/capture failure.
        for _ in 0..<10 { XCTAssertNil(selection.update(selected: true)) }
        XCTAssertEqual(selection.update(selected: false), .stop)
        XCTAssertEqual(selection.update(selected: true), .start)
    }
}
