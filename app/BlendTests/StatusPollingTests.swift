import XCTest

/// The engine as polling sees it: whether an app reads a mix, and how often it was read.
@MainActor
private final class FakeEngine {
    var inUse = false
    var reads = 0
    var quiets = 0
}

/// Counts reads across opening and closing Blend's views and a mix coming into and out of
/// use, with real timers on the main run loop, as the app runs them.
@MainActor
final class StatusPollingTests: XCTestCase {
    private func makePolling(_ engine: FakeEngine) -> StatusPolling {
        StatusPolling(
            read: {
                engine.reads += 1
                return engine.inUse
            },
            quiet: { engine.quiets += 1 })
    }

    /// Reads that happen while the main run loop runs for this long.
    private func reads(_ engine: FakeEngine, during seconds: TimeInterval) -> Int {
        let before = engine.reads
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        return engine.reads - before
    }

    func testNothingReadsWhileClosedAndUnused() {
        let engine = FakeEngine()
        let polling = makePolling(engine)
        XCTAssertEqual(reads(engine, during: 0.5), 0)
        XCTAssertFalse(polling.running)
    }

    func testOpeningReadsAtOnceThenEvery100msUntilClosed() {
        let engine = FakeEngine()
        let polling = makePolling(engine)
        polling.setViewsOpen(true)
        // Before any timer fires, so the first frame is current.
        XCTAssertEqual(engine.reads, 1)
        XCTAssertTrue(polling.running)
        let open = reads(engine, during: 0.55)
        XCTAssertGreaterThanOrEqual(open, 3)
        XCTAssertLessThanOrEqual(open, 7)

        polling.setViewsOpen(false)
        XCTAssertFalse(polling.running)
        XCTAssertEqual(engine.quiets, 1)
        XCTAssertEqual(reads(engine, during: 0.5), 0)
    }

    func testAMixInUseKeepsReadingWithTheViewsClosed() {
        let engine = FakeEngine()
        let polling = makePolling(engine)
        engine.inUse = true
        polling.changed()
        XCTAssertEqual(engine.reads, 1)
        XCTAssertTrue(polling.running)
        XCTAssertGreaterThanOrEqual(reads(engine, during: 0.55), 3)

        // The next read sees nothing in use and stops.
        engine.inUse = false
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertFalse(polling.running)
        XCTAssertEqual(engine.quiets, 1)
        XCTAssertEqual(reads(engine, during: 0.5), 0)
    }

    func testClosingTheViewsKeepsReadingUntilTheMixIsFree() {
        let engine = FakeEngine()
        let polling = makePolling(engine)
        polling.setViewsOpen(true)
        engine.inUse = true
        polling.changed()
        polling.setViewsOpen(false)
        XCTAssertTrue(polling.running)
        XCTAssertGreaterThanOrEqual(reads(engine, during: 0.55), 3)
        XCTAssertEqual(engine.quiets, 0)

        engine.inUse = false
        polling.changed()
        XCTAssertFalse(polling.running)
        XCTAssertEqual(reads(engine, during: 0.5), 0)
    }

    /// A device coming or going while Blend is unused is read once, without starting a timer.
    func testAChangeWhileUnusedReadsOnce() {
        let engine = FakeEngine()
        let polling = makePolling(engine)
        polling.changed()
        XCTAssertEqual(engine.reads, 1)
        XCTAssertEqual(engine.quiets, 1)
        XCTAssertFalse(polling.running)
        XCTAssertEqual(reads(engine, during: 0.5), 0)
    }

    /// What a view shows when it opens after a quiet spell: everything but the levels.
    func testQuietStatusKeepsEverythingButLevels() {
        let status = MixStatus(deviceReady: true, running: true, users: ["zoom.us"], peak: 0.5,
            sourcePeaks: [0.3, 0.2], sourceLive: [true, false], sourceSilent: [false, true])
        let quiet = status.withoutLevels
        XCTAssertEqual(quiet.peak, 0)
        XCTAssertEqual(quiet.sourcePeaks, [0, 0])
        XCTAssertEqual(quiet.deviceReady, true)
        XCTAssertEqual(quiet.running, true)
        XCTAssertEqual(quiet.users, ["zoom.us"])
        XCTAssertEqual(quiet.sourceLive, [true, false])
        XCTAssertEqual(quiet.sourceSilent, [false, true])
    }
}
