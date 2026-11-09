import CoreAudio

/// An input a mix can take: a microphone, an audio interface, or another app's virtual
/// device such as BlackHole.
struct InputDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// One audio device as the HAL reports it to Blend's own process.
struct DeviceRecord: Hashable, Sendable {
    let uid: String
    let name: String
    let transport: UInt32
    let inputChannels: Int
    /// An aggregate made private to the process that created it.
    let isPrivate: Bool
}

/// Which devices a mix can take as a microphone.
enum InputDevices {
    /// Devices with input channels, other than Blend's own, in the HAL's order.
    static func inputs(_ devices: [DeviceRecord]) -> [InputDevice] {
        devices.filter { $0.inputChannels > 0 && !isBlends($0) }.map { device in
            InputDevice(uid: device.uid, name: device.name)
        }
    }

    /// Devices Blend made, which would only feed a mix back into itself. The driver's mixes
    /// and bus carry Blend's UID prefix. Every private aggregate is Blend's too, since only
    /// the process that made one can see it: the engine's app and echo captures, and the
    /// CADefaultDeviceAggregate-<pid>-<n> that AVAudioEngine makes for playing a check back.
    /// Aggregates made in Audio MIDI Setup are public, so they stay.
    static func isBlends(_ device: DeviceRecord) -> Bool {
        device.uid.hasPrefix("app.blend.") || device.isPrivate
    }
}
