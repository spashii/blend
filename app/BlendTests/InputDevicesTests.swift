import XCTest

private func fourCC(_ code: String) -> UInt32 {
    code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
}

/// Which devices the mix pickers offer as microphones.
final class InputDevicesTests: XCTestCase {
    /// The devices Blend's process sees on a MacBook Air with macOS 26.6.2 while a check plays
    /// back (the built-in devices, a mix, and AVAudioEngine's private aggregate, read from a
    /// process that prepared one), with the private aggregates the engine makes for an app
    /// capture and the echo reference, and the UIDs BlackHole and Audio MIDI Setup give
    /// the devices a person adds. Private aggregates show only in the process that made them.
    private static let recorded: [DeviceRecord] = [
        DeviceRecord(uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone",
            transport: fourCC("bltn"), inputChannels: 1, isPrivate: false),
        DeviceRecord(uid: "BuiltInSpeakerDevice", name: "MacBook Air Speakers",
            transport: fourCC("bltn"), inputChannels: 0, isPrivate: false),
        DeviceRecord(uid: "app.blend.mix.3a153f06", name: "Blend Mic",
            transport: fourCC("virt"), inputChannels: 2, isPrivate: false),
        DeviceRecord(uid: "CADefaultDeviceAggregate-52613-0", name: "CADefaultDeviceAggregate-52613-0",
            transport: fourCC("grup"), inputChannels: 1, isPrivate: true),
        DeviceRecord(uid: "7F1C2A64-0B9E-4D3A-8C55-2E6F1A9B4C70", name: "Blend: com.apple.Music",
            transport: fourCC("grup"), inputChannels: 2, isPrivate: true),
        DeviceRecord(uid: "3E0D1C1B-2F4A-4C55-9E7B-6A1D2B3C4D5E", name: "Blend: echo reference",
            transport: fourCC("grup"), inputChannels: 3, isPrivate: true),
        DeviceRecord(uid: "BlackHole2ch_UID", name: "BlackHole 2ch",
            transport: fourCC("virt"), inputChannels: 2, isPrivate: false),
        DeviceRecord(uid: "~:AMS2_Aggregate:0", name: "Aggregate Device",
            transport: fourCC("grup"), inputChannels: 3, isPrivate: false),
    ]

    func testOffersOnlyInputsBlendDidNotMake() {
        XCTAssertEqual(InputDevices.inputs(Self.recorded).map(\.name),
                       ["MacBook Air Microphone", "BlackHole 2ch", "Aggregate Device"])
    }

    /// A private aggregate is Blend's whatever it is called, and a public one is the
    /// person's even when its name looks like Blend's.
    func testThePrivateFlagDecidesNotTheName() {
        let renamed = DeviceRecord(uid: "AB12", name: "MacBook Air Microphone",
            transport: fourCC("grup"), inputChannels: 1, isPrivate: true)
        let lookalike = DeviceRecord(uid: "~:AMS2_Aggregate:1", name: "CADefaultDeviceAggregate-1-1",
            transport: fourCC("grup"), inputChannels: 1, isPrivate: false)
        XCTAssertEqual(InputDevices.inputs([renamed, lookalike]).map(\.uid), ["~:AMS2_Aggregate:1"])
    }
}
