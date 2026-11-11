import XCTest

/// "Lower other sources while I talk": off by default, kept with the mix, and offered only
/// where it can apply.
@MainActor
final class DuckingTests: XCTestCase {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "DuckingTests-\(UUID().uuidString)")
    }

    private let mic = MixSource.device(uid: "BuiltInMicrophoneDevice", name: "Microphone")
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

    func testOfferedOnlyWithAMicAndSomethingToLower() {
        XCTAssertTrue(Mix(id: "a", name: "Call", slot: 0, sources: [mic, call]).canDuck)
        XCTAssertTrue(Mix(id: "a", name: "Call", slot: 0, sources: [mic, call, .system()]).canDuck)
        XCTAssertFalse(Mix(id: "a", name: "Call", slot: 0, sources: [call, .system()]).canDuck,
            "no microphone")
        XCTAssertFalse(Mix(id: "a", name: "Call", slot: 0, sources: [mic]).canDuck,
            "nothing to lower")
    }

    func testHiddenInSplitMode() {
        var mix = Mix(id: "a", name: "Call", slot: 0, sources: [mic, .system()])
        mix.duck = true
        XCTAssertTrue(mix.canDuck)
        mix.split = true
        XCTAssertFalse(mix.canDuck)
        // Leaving split brings back the choice that was made before.
        mix.split = false
        XCTAssertTrue(mix.canDuck)
        XCTAssertTrue(mix.duck)
    }
}
