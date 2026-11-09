import CoreAudio

/// An input a mix can take: a microphone, an audio interface, or another app's virtual
/// device such as BlackHole.
struct InputDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    /// A physical microphone, as against a virtual or aggregate device.
    let hardware: Bool
    var id: String { uid }

    /// How a source from this input starts. Echo cancellation takes out what the Mac plays,
    /// which is what a microphone near the speakers picks up. A virtual input often carries
    /// that same audio on purpose, routed into it from an app, and echo cancellation would
    /// erase it. Isolation is left to the person, since it adds delay.
    var startingProcessing: Processing {
        Processing(echoCancel: hardware, isolation: .off)
    }
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
            InputDevice(uid: device.uid, name: device.name,
                hardware: isHardware(transport: device.transport))
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

    /// Transports that carry a physical microphone. Virtual and aggregate devices, and any
    /// device that doesn't say, count as not hardware.
    static func isHardware(transport: UInt32) -> Bool {
        hardwareTransports.contains(transport)
    }

    private static let hardwareTransports: Set<UInt32> = [
        kAudioDeviceTransportTypeBuiltIn,
        kAudioDeviceTransportTypeUSB,
        kAudioDeviceTransportTypeBluetooth,
        kAudioDeviceTransportTypeBluetoothLE,
        kAudioDeviceTransportTypeFireWire,
        kAudioDeviceTransportTypePCI,
        kAudioDeviceTransportTypeThunderbolt,
        kAudioDeviceTransportTypeHDMI,
        kAudioDeviceTransportTypeDisplayPort,
        kAudioDeviceTransportTypeAVB,
        kAudioDeviceTransportTypeContinuityCaptureWired,
        kAudioDeviceTransportTypeContinuityCaptureWireless,
    ]
}
