import Observation
import XCTest

@MainActor
@Observable
private final class Activity {
    var busy: Bool

    init(busy: Bool) {
        self.busy = busy
    }
}

@MainActor
final class WhenIdleTests: XCTestCase {
    /// The gate reads the condition again on the main actor after a change; this lets it.
    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
        }
    }

    func testRunsRightAwayWhenIdle() {
        let activity = Activity(busy: false)
        let gate = WhenIdle { !activity.busy }
        var runs = 0
        gate.run { runs += 1 }
        XCTAssertEqual(runs, 1)
    }

    func testWaitsForTheChangeToIdle() async {
        let activity = Activity(busy: true)
        let gate = WhenIdle { !activity.busy }
        var runs = 0
        gate.run { runs += 1 }
        XCTAssertEqual(runs, 0)
        activity.busy = true
        await settle()
        XCTAssertEqual(runs, 0)
        activity.busy = false
        await settle()
        XCTAssertEqual(runs, 1)
    }

    func testRunsOncePerReturnToIdle() async {
        let activity = Activity(busy: false)
        let gate = WhenIdle { !activity.busy }
        var runs = 0
        gate.run { runs += 1 }
        // A change that leaves it idle is not a new return to idle.
        activity.busy = false
        await settle()
        XCTAssertEqual(runs, 1)
        activity.busy = true
        await settle()
        activity.busy = false
        await settle()
        XCTAssertEqual(runs, 2)
    }
}
