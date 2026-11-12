import BlendKitCore
import Foundation

/// BlendKit is Blend Mic's audio engine as a package: it records both sides of an online call
/// and meters the apps that could be part of one. It needs the microphone permission for the
/// microphone and the System Audio Recording permission for the call app's audio, both of
/// which belong to the app that links it.
public enum BlendKit {
    /// The Blend release this build of the engine comes from, such as "0.9.0".
    public static var version: String {
        String(cString: BKVersion())
    }

    /// Software inside the binary, for the host's own notices. The license texts are in the
    /// package's THIRD_PARTY_NOTICES.md and in the release zip.
    public static let thirdPartyComponents: [ThirdPartyComponent] = [
        ThirdPartyComponent(
            name: "JSON for Modern C++", license: "MIT",
            url: "https://github.com/nlohmann/json"),
        ThirdPartyComponent(
            name: "WebRTC audio processing", license: "BSD-3-Clause and the WebRTC patent grant",
            url: "https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing"),
        ThirdPartyComponent(
            name: "Abseil", license: "Apache-2.0", url: "https://github.com/abseil/abseil-cpp"),
        ThirdPartyComponent(
            name: "pffft", license: "FFTPACK license (BSD-style)",
            url: "https://bitbucket.org/jpommier/pffft"),
        ThirdPartyComponent(
            name: "RNNoise", license: "BSD-3-Clause", url: "https://gitlab.xiph.org/xiph/rnnoise"),
        ThirdPartyComponent(
            name: "Ooura FFT", license: "Ooura's permissive license",
            url: "http://www.kurims.kyoto-u.ac.jp/~ooura/fft.html"),
        ThirdPartyComponent(
            name: "FFT by Mark Olesen", license: "Olesen's permissive license",
            url: "https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing"),
        ThirdPartyComponent(
            name: "spl_sqrt_floor", license: "Public domain, by Wilco Dijkstra",
            url: "https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing"),
    ]
}

public struct ThirdPartyComponent: Sendable, Hashable {
    public let name: String
    public let license: String
    public let url: String
}
