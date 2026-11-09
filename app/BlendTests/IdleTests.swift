import XCTest

final class IdleTests: XCTestCase {
    func testIdleWithoutMixes() {
        XCTAssertTrue(MixStatus.idle([], checking: false))
    }

    func testIdleWhenNoAppReadsAnyMix() {
        let waiting = MixStatus(deviceReady: true)
        XCTAssertTrue(MixStatus.idle([waiting, MixStatus()], checking: false))
    }

    func testBusyWhileAnAppReadsOneOfTheMixes() {
        let call = MixStatus(deviceReady: true, running: true, users: ["zoom.us"])
        XCTAssertFalse(MixStatus.idle([MixStatus(deviceReady: true), call], checking: false))
    }

    /// The "In use" case: the driver reports the device running but can't name the app.
    func testBusyWhileAnUnnamedAppReadsAMix() {
        XCTAssertFalse(MixStatus.idle([MixStatus(deviceReady: true, running: true)], checking: false))
    }

    func testBusyDuringACheck() {
        XCTAssertFalse(MixStatus.idle([MixStatus(deviceReady: true)], checking: true))
    }
}
