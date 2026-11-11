import SwiftUI

@main
struct BlendApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environment(delegate.model)
        } label: {
            Image(delegate.model.menuBarImage, label: Text("Blend Mic"))
                .help("Blend Mic")
        }
        .menuBarExtraStyle(.window)

        Window("Blend Mic", id: "settings") {
            SettingsView()
                .environment(delegate.model)
                .frame(minWidth: 720, minHeight: 460)
        }
        .windowResizability(.contentSize)
        // The first launch opens straight to setup; after that Blend lives in the menu bar.
        .defaultLaunchBehavior(delegate.model.setupComplete ? .suppressed : .presented)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel

    override init() {
        // Before the model, which starts talking to the driver.
        MoveToApplications.yieldToRunningCopy()
        MoveToApplications.offerIfNeeded()
        model = AppModel()
        super.init()
    }

    /// Quitting silences every mix, so Blend says which apps would lose sound first. A quit
    /// from logging out or shutting down goes ahead without asking.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil {
            return .terminateNow
        }
        let inUse = model.store.mixes.filter { model.status($0).running }
        guard !inUse.isEmpty, !model.uninstalling else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "Quit Blend Mic?"
        alert.informativeText = inUse.map { mix in
            let users = model.status(mix).users
            let who = users.isEmpty ? "An app" : ListFormatter.localizedString(byJoining: users)
            return "\(who) is using \(mix.name)."
        }.joined(separator: " ") + " It goes silent until Blend Mic opens again."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate()
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// Something wrong with one source of a mix, in words a person can act on.
struct SourceIssue: Equatable {
    let text: String
    /// The mix is in use or being checked, so this is costing sound right now.
    let urgent: Bool
}

/// Ties presets on disk to the engine: every change to a preset is sent to the engine.
@MainActor
@Observable
final class AppModel {
    static let generalTag = "#general"

    let store = MixStore()
    let engine = EngineBridge()
    let shared = SharedMixes()
    let catalog = AudioCatalog()
    let player = RecentPlayer()
    let setup = Setup()
    let updates: Updates
    let check: MixCheck
    var selection: String?
    var showingNewMix = false
    var uninstalling = false
    @ObservationIgnored private var visibleViews = 0

    init() {
        check = MixCheck(engine: engine, player: player)
        updates = Updates(idle: { [engine, check] in
            MixStatus.idle(engine.statuses.values, checking: check.phase != .idle)
        })
        store.onChange = { [weak self] mixes in
            self?.engine.apply(mixes)
            self?.shared.write(mixes)
        }
        engine.apply(store.mixes)
        shared.write(store.mixes)
        if !setupComplete {
            selection = Self.generalTag
        }
    }

    /// A check belongs to the view that started it: closing every Blend view ends it, so
    /// the microphone is never left running behind a closed panel.
    func viewAppeared() {
        visibleViews += 1
        engine.viewOpened()
        setup.refresh()
    }

    func viewDisappeared() {
        visibleViews = max(0, visibleViews - 1)
        if visibleViews == 0 {
            check.stop()
        }
    }

    /// Things the person should know about, in plain words, for the panel and the window.
    var problems: [String] {
        var list: [String] = []
        if let error = engine.lastError {
            list.append("Blend Mic couldn't apply your mixes: \(error)")
        }
        list.append(contentsOf: store.loadErrors)
        return list
    }

    var setupComplete: Bool {
        setup.complete
    }

    var anyRunning: Bool {
        engine.statuses.values.contains { $0.running }
    }

    /// Two overlapping discs, like the app icon: filled while an app is using a mix, with a
    /// badge while a source in use isn't working. Template images in Assets.xcassets.
    var menuBarImage: String {
        if store.mixes.contains(where: { mix in issues(mix).contains { $0.urgent } }) {
            return "MenuBarAttention"
        }
        return anyRunning ? "MenuBarInUse" : "MenuBar"
    }

    func status(_ mix: Mix) -> MixStatus {
        engine.statuses[mix.id] ?? MixStatus()
    }

    /// Whether the mix is carrying sound somewhere right now.
    func active(_ mix: Mix) -> Bool {
        status(mix).running || check.phase(for: mix) != .idle
    }

    /// "Used by Zoom", or nil when no app is reading the mix.
    func usedBy(_ mix: Mix) -> String? {
        let status = status(mix)
        guard status.running else { return nil }
        return status.users.isEmpty
            ? "In use" : "Used by " + ListFormatter.localizedString(byJoining: status.users)
    }

    func issue(_ source: MixSource, at index: Int, in mix: Mix) -> SourceIssue? {
        let active = active(mix) && !mix.muted && !source.muted
        let status = status(mix)
        switch source.kind {
        case .device:
            if !catalog.isPresent(source) {
                return SourceIssue(text: "Not connected", urgent: active)
            }
            if setup.microphone == .denied {
                return SourceIssue(text: "Blend Mic isn't allowed to use microphones", urgent: active)
            }
        case .app:
            if !catalog.isPresent(source) {
                return SourceIssue(text: source.instance == nil ? "Not open" : "This copy isn't open",
                    urgent: active)
            }
            if setup.appAudio == .denied {
                return SourceIssue(text: "Blend Mic isn't allowed to capture app audio", urgent: active)
            }
            // A call app that picked the mix it is in sends the call back to itself.
            if status.running, let app = catalog.app(for: source),
               let name = NSRunningApplication(processIdentifier: app.pid)?.localizedName,
               status.users.contains(name) {
                return SourceIssue(text: "\(name) is also using this mix, so it hears itself", urgent: true)
            }
        case .system:
            if setup.appAudio == .denied {
                return SourceIssue(text: "Blend Mic isn't allowed to capture app audio", urgent: active)
            }
        }
        if active {
            if !status.live(index) {
                return SourceIssue(text: "Blend Mic couldn't start capturing it", urgent: true)
            }
            // Apps go quiet all the time; an input device that gives exact zeros is muted or
            // refused.
            if source.kind == .device && status.silent(index) {
                return SourceIssue(text: "No sound. Check that it isn't muted.", urgent: true)
            }
        }
        // The echo reference is a capture of what the Mac plays, under the same permission
        // as app audio.
        if source.kind == .device && source.processing.echoCancel && setup.appAudio == .denied {
            return SourceIssue(text: "Echo cancellation needs permission for audio from other apps",
                urgent: false)
        }
        return nil
    }

    func issues(_ mix: Mix) -> [SourceIssue] {
        mix.sources.enumerated().compactMap { index, source in issue(source, at: index, in: mix) }
    }

    func binding(for id: String) -> Binding<Mix>? {
        guard store.mix(id: id) != nil else { return nil }
        return Binding(
            get: { self.store.mix(id: id) ?? Mix(id: id, name: "", slot: 0) },
            set: { self.store.update($0) })
    }

    /// Removes the driver, the mixes and Blend's settings, then moves Blend to the Trash.
    func uninstall() async {
        check.stop()
        // An empty list first, so the driver's own saved copy of the mixes is cleared too.
        engine.apply([])
        guard await setup.uninstallDriver() else {
            engine.apply(store.mixes)
            return
        }
        uninstalling = true
        store.deleteAll()
        // A login item switched off in System Settings reads as requiresApproval but is still
        // registered. macOS keeps a disabled record of an unregistered item in its background
        // items list, which no public call removes; it is not listed under Open at Login.
        if setup.openAtLogin != .notRegistered {
            setup.setOpenAtLogin(false)
        }
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "All", domain]
            try? reset.run()
            reset.waitUntilExit()
            // Quitting writes preferences and window state again, so the files go once Blend
            // has exited.
            Leftovers.removeAfterQuit(domain: domain)
        }
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }
}
