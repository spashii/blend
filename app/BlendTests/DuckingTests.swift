import XCTest

/// "Lower other sources while I talk": off by default, kept with the mix, and offered only
/// where it can apply.
@MainActor
final class DuckingTests: XCTestCase {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "DuckingTests-\(UUID().uuidString)")
    }

    private let mic = MixSource.device(uid: "BuiltInMicrophoneDevice", name: "Microphone")
    private let blackhole = MixSource.device(uid: "BlackHole2ch_UID", name: "BlackHole 2ch")
    private let call = MixSource(kind: .app, bundleID: "us.zoom.xos", name: "Zoom")

    func testOffByDefault() {
        let mix = Mix(id: "a", name: "Call", slot: 0, sources: [mic, call])
        XCTAssertFalse(mix.duck)
    }

    func testSurvivesRelaunch() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MixStore(directory: directory)
        var mix = try XCTUnwrap(store.create(name: "Call", sources: [mic, call]))
        mix.duck = true
        store.update(mix)
        // Writes settle 400 ms after the last change.
        try await Task.sleep(for: .milliseconds(900))

        let reopened = MixStore(directory: directory)
        XCTAssertEqual(reopened.mixes.first?.duck, true)
    }

    func testFilesWithoutTheFieldLoadAsOff() throws {
        let json = #"{"id":"a","name":"Call","slot":0,"sources":[]}"#
        let mix = try JSONDecoder().decode(Mix.self, from: Data(json.utf8))
        XCTAssertFalse(mix.duck)
    }

    func testTheEngineGetsTheFlag() throws {
        var mix = Mix(id: "a", name: "Call", slot: 0, sources: [mic, call])
        mix.duck = true
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mix)) as? [String: Any]
        XCTAssertEqual(object?["duck"] as? Bool, true)
    }

    /// What the device list says: the built-in microphone is physical, BlackHole is not.
    private let physical: (MixSource) -> Bool = {
        $0.kind == .device && $0.uid == "BuiltInMicrophoneDevice"
    }

    private func canDuck(_ sources: [MixSource]) -> Bool {
        Mix(id: "a", name: "Call", slot: 0, sources: sources).canDuck(isMicrophone: physical)
    }

    func testOfferedOnlyWithAPhysicalMicAndSomethingToLower() {
        XCTAssertTrue(canDuck([mic, call]))
        XCTAssertTrue(canDuck([mic, call, .system()]))
        XCTAssertFalse(canDuck([call, .system()]), "no microphone")
        XCTAssertFalse(canDuck([mic]), "nothing to lower")
    }

    func testAVirtualInputIsLoweredNotListenedTo() {
        XCTAssertFalse(canDuck([blackhole, call]), "a virtual input is no microphone")
        XCTAssertFalse(canDuck([blackhole, .system()]))
        XCTAssertTrue(canDuck([mic, blackhole]), "the virtual input is what gets lowered")
    }

    func testHiddenInSplitMode() {
        var mix = Mix(id: "a", name: "Call", slot: 0, sources: [mic, .system()])
        mix.duck = true
        XCTAssertTrue(mix.canDuck(isMicrophone: physical))
        mix.split = true
        XCTAssertFalse(mix.canDuck(isMicrophone: physical))
        // Leaving split brings back the choice that was made before.
        mix.split = false
        XCTAssertTrue(mix.canDuck(isMicrophone: physical))
        XCTAssertTrue(mix.duck)
    }
}
