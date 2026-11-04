import Combine
import SwiftUI

/// The settings window, laid out like System Settings: General and the mixes in the sidebar,
/// the selected one on the right.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                HStack {
                    Label("General", systemImage: "gearshape")
                    Spacer()
                    if !model.setupComplete {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .help("Setup isn't finished")
                    }
                }
                .tag(AppModel.generalTag)
                Section("Mixes") {
                    ForEach(model.store.mixes) { mix in
                        HStack {
                            Image(systemName: "waveform")
                            Text(mix.name)
                            Spacer()
                            if model.issues(mix).contains(where: \.urgent) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("A source in this mix isn't working")
                            } else if model.status(mix).running {
                                Circle().fill(.green).frame(width: 7, height: 7)
                                    .help(model.usedBy(mix) ?? "")
                            }
                        }
                        .tag(mix.id)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        model.showingNewMix = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("New mix")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .focused($sidebarFocused)
            // Opening the window must not put the cursor in a name field, where one stray key
            // would rename a microphone that is in use.
            .defaultFocus($sidebarFocused, true)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if model.selection == AppModel.generalTag {
                GeneralView()
            } else if let id = model.selection, let mix = model.binding(for: id) {
                MixEditor(mix: mix)
                    .id(id)
            } else {
                ContentUnavailableView("No mix selected", systemImage: "waveform",
                    description: Text("Pick a mix, or add one with +."))
            }
        }
        .sheet(isPresented: $model.showingNewMix) {
            NewMixSheet()
        }
        .onAppear {
            model.viewAppeared()
            if model.selection == nil {
                model.selection = model.setupComplete
                    ? model.store.mixes.first?.id ?? AppModel.generalTag : AppModel.generalTag
            }
            if !model.setupComplete {
                NSApplication.shared.activate()
            }
        }
        .onDisappear { model.viewDisappeared() }
    }
}

private struct MixEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var mix: Mix
    @State private var confirmingDelete = false
    @State private var draftName = ""
    @FocusState private var editingName: Bool

    var body: some View {
        let status = model.status(mix)
        Form {
            if !model.problems.isEmpty {
                Section {
                    ForEach(model.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section {
                // The microphone is renamed in other apps only when the edit is finished, so
                // their lists don't flicker through every keystroke; an empty name is refused.
                TextField("Name", text: $draftName)
                    .focused($editingName)
                    .onSubmit(commitName)
                    .onChange(of: editingName) { _, editing in
                        if !editing { commitName() }
                    }
                    .onAppear { draftName = mix.name }
                LabeledContent("Level") {
                    HStack {
                        LevelMeter(level: status.peak).frame(width: 160)
                        CheckButton(mix: mix)
                            .buttonStyle(.bordered)
                    }
                }
                LabeledContent("Status") {
                    Text(statusText(status))
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Pick \"\(mix.name)\" as the microphone in any app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sources") {
                ForEach(Array($mix.sources.enumerated()), id: \.element.id) { index, $source in
                    SourceEditor(source: $source, level: status.level(index),
                        issue: model.issue(source, at: index, in: mix)) {
                        mix.sources.removeAll { $0.id == source.id }
                    }
                }
                AddSourceButton(mix: $mix)
                if mix.sources.count == 2 {
                    Toggle(isOn: $mix.split) {
                        Text("Split by channel")
                        Text(mix.splitDescription)
                    }
                }
            }

            Section {
                Button("Delete Mix…", role: .destructive) { confirmingDelete = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete \(mix.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                let id = mix.id
                model.selection = model.store.mixes.first { $0.id != id }?.id
                model.store.delete(id: id)
            }
        } message: {
            Text(status.running
                ? "An app is using this microphone right now. It will go silent, and the microphone disappears once the app lets go of it."
                : "Apps that use this microphone will need another one.")
        }
    }

    private func statusText(_ status: MixStatus) -> String {
        if let usedBy = model.usedBy(mix) {
            return usedBy
        }
        if status.deviceReady {
            return "Not in use"
        }
        return model.setup.driver == .current ? "Waiting for the driver" : "The driver isn't installed"
    }

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            draftName = mix.name
        } else if trimmed != mix.name {
            mix.name = trimmed
        }
    }
}

private struct SourceEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var source: MixSource
    let level: Float
    let issue: SourceIssue?
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SourceIcon(source: source)
                VStack(alignment: .leading, spacing: 1) {
                    TextField("Source name", text: $source.name)
                        .textFieldStyle(.roundedBorder)
                        .help(source.instance == nil
                            ? "Rename this source; the name is only used inside Blend"
                            : "Name this copy; Blend uses the name wherever this copy appears")
                    if let instance = source.instance, !instance.isEmpty {
                        Text(instance)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    if let issue {
                        Label(issue.text, systemImage: issue.urgent ? "exclamationmark.triangle.fill" : "info.circle")
                            .font(.caption)
                            .foregroundStyle(issue.urgent ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                }
                Spacer()
                if source.kind == .app, let app = model.catalog.app(for: source) {
                    Button("Show") { app.show() }
                        .help("Bring this app's windows to the front")
                }
                Button {
                    source.muted.toggle()
                } label: {
                    Image(systemName: source.mutedSymbol)
                        .foregroundStyle(source.muted ? .red : .secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help(source.muted ? "Unmute" : "Mute")
                .accessibilityLabel(source.muted ? "Unmute \(source.name)" : "Mute \(source.name)")
                Button(role: .destructive, action: remove) {
                    Image(systemName: "minus.circle")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Remove from this mix")
                .accessibilityLabel("Remove \(source.name) from this mix")
            }
            LevelMeter(level: level)
            HStack {
                Text("Volume").font(.caption).foregroundStyle(.secondary)
                GainSlider(gainDb: $source.gainDb)
                Text(String(format: "%+.0f dB", source.gainDb))
                    .font(.caption.monospacedDigit())
                    .frame(width: 48, alignment: .trailing)
            }
            if source.kind == .device {
                Toggle("Echo cancellation", isOn: $source.processing.echoCancel)
                    .help("Removes what your speakers play from this microphone, so the other side of a call doesn't hear itself. Not needed with headphones.")
                Picker("Voice isolation", selection: $source.processing.isolation) {
                    ForEach(Isolation.allCases) { Text($0.title).tag($0) }
                }
                .help("Apple's voice isolation keeps your voice and removes background sound. It adds a little delay, and can garble speech when other voices are as loud as yours.")
            }
        }
        .padding(.vertical, 4)
        // A name given to one copy of an app follows that copy into the source picker.
        .onChange(of: source.name) { _, name in
            if source.kind == .app, let bundleID = source.bundleID, let instance = source.instance {
                model.catalog.nameCopy(bundleID: bundleID, identity: instance, name)
            }
        }
    }
}

private struct AddSourceButton: View {
    @Binding var mix: Mix
    @State private var picking = false

    var body: some View {
        Button {
            picking = true
        } label: {
            Label("Add Source…", systemImage: "plus")
        }
        .sheet(isPresented: $picking) {
            SourcePicker(offerSystem: !mix.sources.contains { $0.kind == .system }) { source in
                mix.sources.append(source)
            }
        }
    }
}

/// Microphones, then running apps by kind. Apps making sound show a live meter, and the
/// speaker button silences one copy so you can tell copies of an app apart by ear.
private struct SourcePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// A mix needs System audio only once.
    let offerSystem: Bool
    let add: (MixSource) -> Void
    @State private var levels: [String: Float] = [:]
    /// When each app last made sound; its meter stays for a minute after, so rows don't
    /// change shape while you reach for them.
    @State private var lastHeard: [String: Date] = [:]
    @State private var silenced: Set<String> = []
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private func recentlyPlaying(_ app: RunningApp) -> Bool {
        app.playing || (lastHeard[app.id].map { Date().timeIntervalSince($0) < 60 } ?? false)
    }

    var body: some View {
        let playing = model.catalog.apps.filter(recentlyPlaying)
        NavigationStack {
            List {
                Section("Microphones and inputs") {
                    ForEach(model.catalog.inputs) { input in
                        HStack {
                            Image(systemName: "mic").frame(width: 22)
                            Text(input.name)
                            Spacer()
                            Button("Add") {
                                pick(.device(uid: input.uid, name: input.name,
                                    processing: Processing(echoCancel: true, isolation: .off)))
                            }
                        }
                    }
                }
                if offerSystem {
                    Section {
                        HStack {
                            Image(systemName: "laptopcomputer").frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("System audio")
                                Text("Everything your Mac plays, except apps using this mix")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add") { pick(.system()) }
                        }
                    }
                }
                ForEach(model.catalog.groupedApps, id: \.group) { entry in
                    Section {
                        ForEach(entry.apps) { app in
                            AppRow(app: app, level: recentlyPlaying(app) ? levels[app.id] ?? 0 : nil,
                                silenced: silenced.contains(app.id), silence: toggleSilence, add: pick)
                        }
                    } header: {
                        Text(entry.group.title)
                    } footer: {
                        if entry.group == .browsers {
                            Text("A browser is added whole, with every tab.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Add a source")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(width: 460, height: 520)
        .onAppear {
            model.catalog.watch(true)
            model.engine.probe(playing)
        }
        .onDisappear {
            for app in model.catalog.apps where silenced.contains(app.id) {
                model.engine.silence(app, false)
            }
            model.catalog.watch(false)
            model.engine.probe([])
        }
        .onChange(of: playing.map(\.id)) { _, _ in
            model.engine.probe(model.catalog.apps.filter(recentlyPlaying))
        }
        .onReceive(tick) { _ in
            for app in model.catalog.apps where app.playing {
                lastHeard[app.id] = Date()
            }
            let fresh = model.engine.probeLevels()
            levels = fresh.mapValues { $0 }.merging(levels.mapValues { $0 * 0.85 }) { new, decayed in
                max(new, decayed)
            }
        }
    }

    private func pick(_ source: MixSource) {
        add(source)
        dismiss()
    }

    private func toggleSilence(_ app: RunningApp) {
        let on = !silenced.contains(app.id)
        if on {
            silenced.insert(app.id)
        } else {
            silenced.remove(app.id)
        }
        model.engine.silence(app, on)
    }
}

private struct AppRow: View {
    let app: RunningApp
    let level: Float?
    let silenced: Bool
    let silence: (RunningApp) -> Void
    let add: (MixSource) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable()
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                if let detail = app.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let level {
                    LevelMeter(level: level).frame(width: 140)
                }
            }
            Spacer()
            if app.instance != nil {
                Button("Show") { app.show() }
                    .help("Bring this copy's windows to the front")
            }
            if level != nil {
                // A toggle rather than press-and-hold, so it works from the keyboard and
                // VoiceOver; every copy is unsilenced when the picker closes.
                Toggle(isOn: Binding(get: { silenced }, set: { _ in silence(app) })) {
                    Image(systemName: "speaker.slash")
                }
                .toggleStyle(.button)
                .help(silenced ? "Let this copy play again" : "Silence this copy to hear which one it is")
                .accessibilityLabel("Silence \(app.name)")
            }
            Button("Add") { add(.app(app)) }
        }
    }
}

/// A name and a microphone; everything else is added in the mix itself, where each
/// source has its volume.
private struct NewMixSheet: View {
    enum Preset: Hashable {
        case microphone
        /// Split by channel from the start, for recording; off again for a call.
        case micAndSystem
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var preset = Preset.microphone
    @State private var name = ""
    @State private var micUID: String?

    var body: some View {
        Form {
            Section {
                Picker("Preset", selection: $preset) {
                    Text("Microphone").tag(Preset.microphone)
                    Text("Mic and system audio").tag(Preset.micAndSystem)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextField("Name", text: $name, prompt: Text(suggestedName))
                Picker("Microphone", selection: $micUID) {
                    Text("None").tag(String?.none)
                    ForEach(model.catalog.inputs) { Text($0.name).tag(Optional($0.uid)) }
                }
            } footer: {
                Text(preset == .microphone
                    ? "Other apps list it as \u{201C}\(effectiveName)\u{201D}. Add apps and other sources to it next."
                    : "Other apps list it as \u{201C}\(effectiveName)\u{201D}, with your mic on the left and system audio on the right.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { micUID = model.catalog.defaultInput?.uid }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { create() }
                    .disabled(model.store.mixes.count >= 16)
                    .help(model.store.mixes.count >= 16 ? "Blend holds 16 mixes. Delete one to add another." : "")
            }
        }
    }

    private var effectiveName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? suggestedName : trimmed
    }

    /// "Blend Mic", then "Blend Mic 2", so two mixes never share a name in other apps.
    private var suggestedName: String {
        let base = "Blend Mic"
        let taken = Set(model.store.mixes.map(\.name))
        if !taken.contains(base) {
            return base
        }
        return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) }!
    }

    private func create() {
        // Echo cancellation on, so the mix works on speakers; isolation is left to the
        // person, since it adds delay.
        var sources = model.catalog.inputs.first { $0.uid == micUID }.map { mic in
            [MixSource.device(uid: mic.uid, name: mic.name,
                processing: Processing(echoCancel: true, isolation: .off))]
        } ?? []
        if preset == .micAndSystem {
            sources.append(.system())
        }
        if let mix = model.store.create(name: effectiveName, sources: sources,
            split: preset == .micAndSystem) {
            model.selection = mix.id
        }
        dismiss()
    }
}
