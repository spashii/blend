import AVFoundation
import AppKit
import CoreAudio
import CryptoKit
import Foundation
import Observation
import Security
import ServiceManagement

/// The audio driver that makes mixes appear as microphones. It ships inside Blend.app and is
/// copied into /Library/Audio/Plug-Ins/HAL with one administrator prompt; the Mac's audio
/// service then restarts to load it.
enum Driver {
    static let installed = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/BlendDriver.driver")
    static var bundled: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/BlendDriver.driver")
    }

    enum State: Equatable {
        case notInstalled
        case current
        /// Installed, but not the build this copy of Blend carries.
        case different(installedVersion: String)
        /// A build of Blend without the driver inside it, and none installed.
        case notBundled
    }

    static func state() -> State {
        let files = FileManager.default
        let hasBundled = files.fileExists(atPath: bundled.path)
        guard files.fileExists(atPath: installed.path) else {
            return hasBundled ? .notInstalled : .notBundled
        }
        // Builds are compared by their code, so a changed driver is caught even when the
        // version number stayed the same, and a release that only re-signed the same driver
        // doesn't ask for a password and an audio restart.
        guard hasBundled, let mine = identity(bundled), let theirs = identity(installed) else {
            return .current
        }
        return mine == theirs ? .current : .different(installedVersion: version(installed) ?? "?")
    }

    static func loaded() -> Bool {
        HAL.pluginInstalled(bundleID: "app.blend.driver")
    }

    /// The audio service restarts after an install and takes a few seconds to load its
    /// plug-ins; it is asked off the main thread, since calls block while it starts.
    static func waitUntilLoaded() async {
        await Task.detached {
            for _ in 0..<60 {
                if loaded() {
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }.value
    }

    static func version(_ driver: URL) -> String? {
        let info = NSDictionary(contentsOf: driver.appendingPathComponent("Contents/Info.plist"))
        return info?["CFBundleShortVersionString"] as? String
    }

    /// The code directory hash, which covers the code, the Info.plist and the signer, but
    /// not the signature's timestamp; the file's own hash for an unsigned build.
    private static func identity(_ driver: URL) -> Data? {
        var code: SecStaticCode?
        var info: CFDictionary?
        if SecStaticCodeCreateWithPath(driver as CFURL, [], &code) == errSecSuccess, let code,
           SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
           let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data {
            return unique
        }
        guard let data = try? Data(contentsOf: driver.appendingPathComponent("Contents/MacOS/BlendDriver"))
        else {
            return nil
        }
        return Data(SHA256.hash(data: data))
    }

    /// Copies the bundled driver into place through a hidden folder next to it, so
    /// coreaudiod never sees a half-copied bundle, then restarts the audio service.
    static func install() async throws {
        let script = """
            set -e
            dir=/Library/Audio/Plug-Ins/HAL
            mkdir -p "$dir"
            tmp=$(mktemp -d "$dir/.blend-install.XXXXXX")
            ditto \(shellQuoted(bundled.path)) "$tmp/BlendDriver.driver"
            chown -R root:wheel "$tmp"
            xattr -cr "$tmp"
            rm -rf "$dir/BlendDriver.driver"
            mv "$tmp/BlendDriver.driver" "$dir/BlendDriver.driver"
            rmdir "$tmp"
            \(restartAudio)
            """
        try await Admin.run(script, prompt: "Blend is installing its audio driver.")
    }

    static func uninstall() async throws {
        let script = """
            set -e
            rm -rf /Library/Audio/Plug-Ins/HAL/BlendDriver.driver
            \(restartAudio)
            """
        try await Admin.run(script, prompt: "Blend is removing its audio driver.")
    }

    /// restart-audio.sh, which the development helper shares; it fails with a message when
    /// the audio service doesn't settle.
    private static var restartAudio: String {
        guard let url = Bundle.main.url(forResource: "restart-audio", withExtension: "sh"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            return "killall coreaudiod AirPlayXPCHelper 2>/dev/null || true"
        }
        return script
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Runs a shell script as root after the standard administrator prompt, which names Blend.
enum Admin {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Cancelled: Error {}

    private static let queue = DispatchQueue(label: "app.blend.admin")

    static func run(_ script: String, prompt: String) async throws {
        let source = "do shell script \(literal(script)) with prompt \(literal(prompt)) "
            + "with administrator privileges"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // NSAppleScript blocks while the prompt is up, so it runs off the main thread, and
            // always on this one queue because it is not thread-safe.
            queue.async {
                var error: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    if (error[NSAppleScript.errorNumber] as? Int) == -128 {
                        continuation.resume(throwing: Cancelled())
                    } else {
                        let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                        continuation.resume(throwing: Failure(message: message))
                    }
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

enum Access: Equatable {
    case allowed
    case denied
    case notAsked
    /// macOS gives no way to tell; it asks the first time it matters.
    case unknown
}

enum Permissions {
    static func microphone() -> Access {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .allowed
        case .denied, .restricted: .denied
        case .notDetermined: .notAsked
        @unknown default: .unknown
        }
    }

    static func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// System Audio Recording has no public status call, and a denied capture is plain
    /// silence. TCC's own preflight and request calls are private but stable, and are what
    /// other capture tools use; without them the status is unknown and macOS asks on the
    /// first capture instead.
    static func appAudio() -> Access {
        guard let preflight = TCC.preflight else { return .unknown }
        switch preflight(TCC.audioCapture, nil) {
        case 0: return .allowed
        case 1: return .denied
        default: return .notAsked
        }
    }

    static func requestAppAudio() async {
        guard let request = TCC.request else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            request(TCC.audioCapture, nil) { _ in continuation.resume() }
        }
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openAppAudioSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
    }

    static func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) {
            NSWorkspace.shared.open(url)
        }
    }

    private enum TCC {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

        static var audioCapture: CFString { "kTCCServiceAudioCapture" as CFString }
        nonisolated(unsafe) private static let handle = dlopen(
            "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
        static let preflight: Preflight? = symbol("TCCAccessPreflight")
        static let request: Request? = symbol("TCCAccessRequest")

        private static func symbol<T>(_ name: String) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
    }
}

/// What Blend needs before mixes work, as one observable state for the setup page and the
/// warnings elsewhere.
@MainActor
@Observable
final class Setup {
    private(set) var driver: Driver.State = Driver.state()
    /// The Mac's audio service has loaded the driver, so mixes exist as devices.
    private(set) var driverLoaded = Driver.loaded()
    private(set) var microphone: Access = Permissions.microphone()
    private(set) var appAudio: Access = Permissions.appAudio()
    private(set) var openAtLogin: SMAppService.Status = SMAppService.mainApp.status
    private(set) var working = false
    private(set) var lastError: String?

    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        // Permissions change in System Settings, so they are read again whenever Blend comes
        // back to the front.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // The driver's devices come and go with the audio service.
        var devices = HAL.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices,
            .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Everything has been installed or asked for once. A refusal still counts as done:
    /// the warnings say what it breaks.
    var complete: Bool {
        driver == .current && driverLoaded && microphone != .notAsked && appAudio != .notAsked
    }

    func refresh() {
        driver = Driver.state()
        driverLoaded = Driver.loaded()
        microphone = Permissions.microphone()
        appAudio = Permissions.appAudio()
        openAtLogin = SMAppService.mainApp.status
    }

    /// Stays working until the audio service has loaded the new driver, so the page goes
    /// straight from installing to done.
    func installDriver() async {
        await perform {
            try await Driver.install()
            await Driver.waitUntilLoaded()
        }
    }

    func uninstallDriver() async -> Bool {
        await perform { try await Driver.uninstall() }
    }

    func allowMicrophone() async {
        await Permissions.requestMicrophone()
        refresh()
    }

    func allowAppAudio() async {
        await Permissions.requestAppAudio()
        refresh()
    }

    func setOpenAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    @discardableResult
    private func perform(_ action: () async throws -> Void) async -> Bool {
        working = true
        defer {
            working = false
            refresh()
        }
        do {
            try await action()
            lastError = nil
            return true
        } catch is Admin.Cancelled {
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
