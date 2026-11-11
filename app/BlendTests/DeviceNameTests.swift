import XCTest

final class DeviceNameTests: XCTestCase {
    private let mix = Mix(id: "8c1e2f3a", name: "Calls", slot: 3)

    /// Other apps list a mix as "Blend Mic (name)", and only the engine's copy says so.
    func testOtherAppsSeeTheMixNameInBrackets() {
        XCTAssertEqual(mix.deviceName, "Blend Mic (Calls)")
        XCTAssertEqual(mix.forEngine.name, "Blend Mic (Calls)")
        XCTAssertEqual(mix.name, "Calls")
    }

    /// Apps keep a selected mix by its UID, so neither the name nor the engine's copy may move it.
    func testTheUIDIgnoresTheName() {
        var renamed = mix
        renamed.name = "Podcast"
        XCTAssertEqual(mix.deviceUID, "app.blend.mix.8c1e2f3a")
        XCTAssertEqual(renamed.deviceUID, mix.deviceUID)
        XCTAssertEqual(mix.forEngine.deviceUID, mix.deviceUID)
        XCTAssertEqual(mix.forEngine.id, mix.id)
        XCTAssertEqual(mix.forEngine.slot, mix.slot)
    }
}
