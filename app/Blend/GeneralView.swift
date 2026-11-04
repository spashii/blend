import ServiceManagement
import SwiftUI

/// Setup and housekeeping: the driver, the two permissions, opening at login, and
/// uninstalling. The first launch opens here.
struct GeneralView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingUninstall = false

    var body: some View {
        let setup = model.setup
        @Bindable var updates = model.updates
        Form {
            Section {
                DriverRow()
                MicrophoneRow()
                AppAudioRow()
                LoginRow()
            } header: {
                Text("Setup")
            } footer: {
                if let error = setup.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if setup.driver == .current && setup.driverLoaded && model.store.mixes.isEmpty {
                Section {
                    Button("Create Your First Mix…") { model.showingNewMix = true }
                        .buttonStyle(.borderedProminent)
                } footer: {
                    Text("A mix is a microphone you put together: choose what goes in, set the volumes, then pick it in Discord, a call recorder or any other app.")
                }
            }

            Section("About") {
                LabeledContent("Version") {
                    HStack {
                        Text(versionText)
                        Button("Check for Updates…") { model.updates.check() }
                            .disabled(!model.updates.canCheck)
                    }
                }
                Toggle("Check for updates automatically", isOn: $updates.automatic)
                Text("Blend works on this Mac and collects nothing. It goes online only to check for updates.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Licenses") { openLicenses() }
                    .help("Blend's license and those of the libraries it includes")
            }

            Section {
                Button("Uninstall Blend…", role: .destructive) { confirmingUninstall = true }
                    .disabled(setup.working)
            } footer: {
                Text("Removes the driver, your mixes and Blend's settings, then moves Blend to the Trash.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Uninstall Blend?", isPresented: $confirmingUninstall) {
            Button("Uninstall", role: .destructive) {
                Task { await model.uninstall() }
            }
        } message: {
            Text("Your mixes disappear from every app, and sound stops for a moment while the Mac's audio restarts.")
        }
        .onAppear { setup.refresh() }
    }

    private func openLicenses() {
        guard let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil) else {
            return
        }
        NSWorkspace.shared.open([license, notices],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }

    private var versionText: String {
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        guard let driver = Driver.version(Driver.installed) else {
            return app
        }
        return driver == app ? app : "\(app), driver \(driver)"
    }
}

/// One setup step: whether it is done, what it is for while it isn't, and the button that
/// does it. A finished step is just its name and a check mark.
private struct StepRow<Action: View>: View {
    let title: String
    let done: Bool
    let detail: String?
    let action: Action

    init(title: String, done: Bool, detail: String? = nil, @ViewBuilder action: () -> Action) {
        self.title = title
        self.done = done
        self.detail = detail
        self.action = action()
    }

    var body: some View {
        HStack(alignment: detail == nil ? .center : .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? .green : .secondary)
                .font(.title3)
                .accessibilityLabel(done ? "Done" : "To do")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            action
        }
        .padding(.vertical, 2)
    }
}

extension StepRow where Action == EmptyView {
    init(title: String, done: Bool, detail: String? = nil) {
        self.init(title: title, done: done, detail: detail) { EmptyView() }
    }
}

private struct DriverRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let setup = model.setup
        if setup.working {
            StepRow(title: "Audio driver", done: false,
                detail: "Installing. Sound pauses for a moment.") {
                ProgressView().controlSize(.small)
            }
        } else {
            switch setup.driver {
            case .current where setup.driverLoaded:
                StepRow(title: "Audio driver", done: true)
            case .current:
                StepRow(title: "Audio driver", done: false,
                    detail: "Installed, but macOS hasn't loaded it. Restarting the Mac fixes this.") {
                    InstallButton(title: "Try Again")
                }
            case .notInstalled:
                StepRow(title: "Audio driver", done: false,
                    detail: "Makes your mixes show up as microphones. Asks for your password.") {
                    InstallButton(title: "Install…")
                }
            case .different:
                StepRow(title: "Audio driver", done: false,
                    detail: "Blend was updated, and the driver needs the same update.") {
                    InstallButton(title: "Update…")
                }
            case .notBundled:
                StepRow(title: "Audio driver", done: false,
                    detail: "This build doesn't include the driver. Build with tools/build.sh.")
            }
        }
    }
}

private struct InstallButton: View {
    @Environment(AppModel.self) private var model
    let title: String

    var body: some View {
        Button(title) {
            Task { await model.setup.installDriver() }
        }
    }
}

private struct MicrophoneRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.setup.microphone {
        case .allowed:
            StepRow(title: "Microphone", done: true)
        case .notAsked, .unknown:
            StepRow(title: "Microphone", done: false,
                detail: "So your voice can go into mixes.") {
                Button("Allow…") { Task { await model.setup.allowMicrophone() } }
            }
        case .denied:
            StepRow(title: "Microphone", done: false,
                detail: "Turned off in System Settings, so microphones in mixes are silent.") {
                Button("Open Settings…") { Permissions.openMicrophoneSettings() }
            }
        }
    }
}

private struct AppAudioRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.setup.appAudio {
        case .allowed, .unknown:
            // Unknown only on a Mac where the status can't be read; macOS then asks the
            // first time a mix captures an app.
            StepRow(title: "Audio from other apps", done: true)
        case .notAsked:
            StepRow(title: "Audio from other apps", done: false,
                detail: "So mixes can include apps like Zoom or Spotify.") {
                Button("Allow…") { Task { await model.setup.allowAppAudio() } }
            }
        case .denied:
            StepRow(title: "Audio from other apps", done: false,
                detail: "Turned off in System Settings, so apps in mixes are silent.") {
                Button("Open Settings…") { Permissions.openAppAudioSettings() }
            }
        }
    }
}

private struct LoginRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.setup.openAtLogin
        StepRow(title: "Open at login", done: status == .enabled,
            detail: status == .requiresApproval ? "Waiting for your approval in System Settings."
                : status == .enabled ? nil : "Mixes only work while Blend is open.") {
            if status == .requiresApproval {
                Button("Open Settings…") { Permissions.openLoginItemSettings() }
            } else {
                Toggle("Open at login", isOn: Binding(
                    get: { status == .enabled },
                    set: { model.setup.setOpenAtLogin($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }
}
