import AppKit
import CoreAudio
import Observation

/// How the source picker groups apps, in the order it lists them.
enum AppGroup: Int, CaseIterable, Identifiable {
    case communication
    case browsers
    case other

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .communication: "Communication"
        case .browsers: "Browsers"
        case .other: "Other apps"
        }
    }
}

/// One copy of a running app, or several copies that were launched the same way and so
/// cannot be told apart. The engine decides identity from launch arguments alone.
struct RunningApp: Identifiable, Hashable {
    let bundleID: String
    /// The folders this copy was launched with; empty for a plain launch.
    let identity: String
    /// The identity, set only when other copies of the app are running and need telling
    /// apart; nil means every copy.
    let instance: String?
    let name: String
    /// The folder, shown when other copies of the same app are running.
    let detail: String?
    let icon: NSImage?
    let playing: Bool
    /// Using a microphone right now, as a call app does during a call.
    let listening: Bool
    let group: AppGroup
    let pid: pid_t
    var id: String { "\(bundleID)#\(instance ?? "*")" }

    /// Brings this copy's windows to the front, which is the surest way to see which copy
    /// it is.
    func show() {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }
}

extension MixSource {
    static func app(_ app: RunningApp) -> MixSource {
        MixSource(kind: .app, bundleID: app.bundleID, instance: app.instance, name: app.name)
    }
}

/// What can be added to a mix: input devices other than Blend's own, and running apps.
@MainActor
@Observable
final class AudioCatalog {
    private(set) var inputs: [InputDevice] = []
    private(set) var apps: [RunningApp] = []
    private(set) var defaultInput: InputDevice?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private var browsers = AudioCatalog.browserIDs()

    /// Call and chat apps. An app using a microphone counts as one too, so a call app
    /// missing here still lands in the group while it is in a call.
    private static let communicationApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams",
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.FaceTime",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "org.whispersystems.signal-desktop",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark", "com.skype.skype", "im.riot.app",
    ]

    /// Browsers, plus whatever opens web links on this Mac. Every app that can open a link
    /// would be too many: editors and terminals claim them as well.
    private static let knownBrowsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
        "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "org.chromium.Chromium", "com.kagi.kagimacOS",
        "app.zen-browser.zen", "com.duckduckgo.macos.browser", "org.torproject.torbrowser",
    ]

    private static func browserIDs() -> Set<String> {
        var ids = knownBrowsers
        if let page = URL(string: "https://example.com"),
           let handler = NSWorkspace.shared.urlForApplication(toOpen: page),
           let id = Bundle(url: handler)?.bundleIdentifier {
            ids.insert(id)
        }
        return ids
    }

    /// Running apps by group, apps in a call first, then by name. Sound alone doesn't
    /// reorder them, so rows stay put while you reach for one.
    var groupedApps: [(group: AppGroup, apps: [RunningApp])] {
        AppGroup.allCases.compactMap { group in
            let members = apps.filter { $0.group == group }
                .sorted { ($0.listening ? 0 : 1, $0.name.lowercased()) < ($1.listening ? 0 : 1, $1.name.lowercased()) }
            return members.isEmpty ? nil : (group, members)
        }
    }

    /// Names given to app copies, by bundle ID and identity, so a copy named once is called
    /// that everywhere and the next time it runs.
    private(set) var copyNames: [String: String] =
        UserDefaults.standard.dictionary(forKey: "CopyNames") as? [String: String] ?? [:]

    init() {
        refreshDevices()
        refreshApps()
        listen(kAudioHardwarePropertyDevices)
        listen(kAudioHardwarePropertyDefaultInputDevice)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.refreshApps() }
            })
        }
    }

    /// Keeps "playing" current while a picker is open; idle otherwise.
    func watch(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        browsers = Self.browserIDs()
        refreshApps()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshApps() }
        }
    }

    /// The running copy a source captures, if it is open.
    func app(for source: MixSource) -> RunningApp? {
        apps.first { app in
            app.bundleID == source.bundleID && (source.instance == nil || app.identity == source.instance)
        }
    }

    /// The app's icon, from any running copy.
    func icon(for source: MixSource) -> NSImage? {
        apps.first { $0.bundleID == source.bundleID }?.icon
    }

    func isPresent(_ source: MixSource) -> Bool {
        switch source.kind {
        case .device: inputs.contains { $0.uid == source.uid }
        case .app: app(for: source) != nil
        case .system: true
        }
    }

    /// A device source whose input is a physical microphone, as against a virtual one.
    func isMicrophone(_ source: MixSource) -> Bool {
        source.kind == .device && inputs.contains { $0.uid == source.uid && $0.hardware }
    }

    func nameCopy(bundleID: String, identity: String, _ name: String) {
        let key = "\(bundleID)#\(identity)"
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard copyNames[key] != (trimmed.isEmpty ? nil : trimmed) else { return }
        copyNames[key] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(copyNames, forKey: "CopyNames")
        refreshApps()
    }

    private func listen(_ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address,
            .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
    }

    private func refreshDevices() {
        let found = InputDevices.inputs(HAL.devices().map(HAL.record))
        inputs = found
        let defaultUID = HAL.string(HAL.defaultInput(), kAudioDevicePropertyDeviceUID)
        defaultInput = found.first { $0.uid == defaultUID }
            ?? found.first { $0.uid == "BuiltInMicrophoneDevice" }
            ?? found.first
    }

    private struct Copy: Decodable {
        let bundleID: String
        let name: String
        let pid: Int32
        let identity: String
        let label: String
        let playing: Bool
        let listening: Bool
    }

    private func refreshApps() {
        guard let raw = BlendCopyRunningApps() else { return }
        defer { free(raw) }
        let ownID = Bundle.main.bundleIdentifier
        let copies = ((try? JSONDecoder().decode([Copy].self,
            from: Data(String(cString: raw).utf8))) ?? [])
            .filter { $0.bundleID != ownID }
        var entries: [RunningApp] = []
        for (bundleID, group) in Dictionary(grouping: copies, by: \.bundleID) {
            let identities = Dictionary(grouping: group, by: \.identity)
            for (identity, same) in identities {
                let first = same[0]
                let several = identities.count > 1
                let label = first.label.isEmpty ? "default" : first.label
                let given = copyNames["\(bundleID)#\(identity)"]
                let listening = same.contains { $0.listening }
                entries.append(RunningApp(bundleID: bundleID, identity: identity,
                    instance: several ? identity : nil,
                    name: several ? given ?? "\(first.name) (\(label))" : first.name,
                    detail: several && !identity.isEmpty ? identity : nil,
                    icon: icon(bundleID: bundleID, pid: first.pid),
                    playing: same.contains { $0.playing }, listening: listening,
                    group: Self.communicationApps.contains(bundleID) ? .communication
                        : browsers.contains(bundleID) ? .browsers
                        : listening ? .communication : .other,
                    pid: first.pid))
            }
        }
        let sorted = entries.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if sorted != apps {
            apps = sorted
        }
    }

    /// Loaded once per app: the list refreshes every second while a picker is open.
    private func icon(bundleID: String, pid: pid_t) -> NSImage? {
        if let icon = icons[bundleID] {
            return icon
        }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        icons[bundleID] = icon
        return icon
    }
}

/// Minimal Core Audio property reads for the UI.
enum HAL {
    static func address(_ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
    }

    static func devices() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &size, &ids)
        return ids
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value else {
            return ""
        }
        return value.takeRetainedValue() as String
    }

    static func record(_ device: AudioObjectID) -> DeviceRecord {
        DeviceRecord(uid: string(device, kAudioDevicePropertyDeviceUID),
            name: string(device, kAudioObjectPropertyName),
            transport: uint32(device, kAudioDevicePropertyTransportType),
            inputChannels: inputChannels(device), isPrivate: isPrivateAggregate(device))
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }

    /// Only aggregates have a composition; any other device reads as not private.
    static func isPrivateAggregate(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioAggregateDevicePropertyComposition)
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let composition = value?.takeRetainedValue() as? [String: Any] else {
            return false
        }
        return (composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue ?? false
    }

    static func inputChannels(_ device: AudioObjectID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else {
            return 0
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func defaultInput() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &size, &device)
        return device
    }

    static func pluginInstalled(bundleID: String) -> Bool {
        var address = address(kAudioHardwarePropertyTranslateBundleIDToPlugIn)
        var bundle = bundleID as CFString
        var plugin = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &bundle) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifier, &size, &plugin)
        }
        return status == noErr && plugin != 0
    }
}
