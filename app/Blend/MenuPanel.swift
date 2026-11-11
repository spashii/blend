import SwiftUI

/// The menu bar panel, modeled on Control Center's Sound module: one row per mix, expanding
/// to its sources.
struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Blend Mic").font(.headline)
                Spacer()
                Button {
                    model.showingNewMix = true
                    openSettings()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New mix")
            }

            ForEach(model.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !model.setupComplete {
                Button {
                    model.selection = AppModel.generalTag
                    openSettings()
                } label: {
                    Label(model.setup.driver == .current ? "Finish setting up Blend Mic…" : "Install the audio driver…",
                        systemImage: "exclamationmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
            }

            if model.store.mixes.isEmpty {
                Text("No mixes yet. Click + to make a microphone from your voice and the sound of other apps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.store.mixes) { mix in
                MixRow(mix: mix, expanded: expanded.contains(mix.id)) {
                    if expanded.contains(mix.id) {
                        expanded.remove(mix.id)
                    } else {
                        expanded.insert(mix.id)
                    }
                }
            }

            Divider()
            // One column, so the support items sit under Settings… and above Quit, as in a menu.
            VStack(alignment: .leading, spacing: 0) {
                Button("Settings…") { openSettings() }
                ForEach(SupportItem.allCases, id: \.self) { item in
                    Button(item.title) { open(item) }
                        .disabled(item == .checkForUpdates && !model.updates.canCheck)
                }
                Button("Quit Blend Mic") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(MenuItemButtonStyle())
            // The highlights reach past the text, which stays in line with the rest of the panel.
            .padding(.horizontal, -MenuItemLook.inset.width)
            .padding(.vertical, -MenuItemLook.inset.height)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            model.viewAppeared()
            // With a single mix, its sliders are the panel.
            if model.store.mixes.count == 1, let only = model.store.mixes.first {
                expanded.insert(only.id)
            }
        }
        .onDisappear { model.viewDisappeared() }
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApplication.shared.activate()
    }

    private func open(_ item: SupportItem) {
        switch item {
        case .checkForUpdates: model.updates.check()
        case .reportIssue: NSWorkspace.shared.open(SupportItem.issueURL)
        case .viewOnGitHub: NSWorkspace.shared.open(SupportItem.repository)
        }
    }
}

private struct MixRow: View {
    @Environment(AppModel.self) private var model
    let mix: Mix
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let status = model.status(mix)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(expanded ? "Hide sources of \(mix.name)" : "Show sources of \(mix.name)")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(mix.name).fontWeight(.medium)
                        if let usedBy = model.usedBy(mix) {
                            Text(usedBy)
                                .font(.caption2)
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.green.opacity(0.2), in: Capsule())
                        } else if !status.deviceReady && model.setup.driver == .current {
                            Text("Starting…").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    LevelMeter(level: status.peak)
                }
                CheckButton(mix: mix, compact: true)
                Button {
                    var updated = mix
                    updated.muted.toggle()
                    model.store.update(updated)
                } label: {
                    Image(systemName: mix.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(mix.muted ? .red : .primary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help(mix.muted ? "Unmute \(mix.name)" : "Mute \(mix.name) (everything in it)")
                .accessibilityLabel(mix.muted ? "Unmute \(mix.name)" : "Mute \(mix.name)")
            }
            if !expanded {
                // A source that is costing sound right now shows even when the row is closed.
                ForEach(Array(mix.sources.enumerated()), id: \.element.id) { index, source in
                    if let issue = model.issue(source, at: index, in: mix), issue.urgent {
                        Label("\(source.name): \(issue.text)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.leading, 28)
                    }
                }
            }
            if expanded {
                ForEach(Array(mix.sources.enumerated()), id: \.element.id) { index, source in
                    SourceSlider(mixID: mix.id, source: source, level: status.level(index),
                        issue: model.issue(source, at: index, in: mix))
                        .padding(.leading, 20)
                }
                if mix.sources.count == 2 {
                    SplitToggle(mix: mix)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .padding(.leading, 20)
                }
                if mix.canDuck(isMicrophone: model.catalog.isMicrophone) {
                    DuckToggle(mix: mix)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .padding(.leading, 20)
                }
                if mix.sources.isEmpty {
                    Text("Nothing in this mix yet. Add your mic or an app in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }
        }
    }
}

private struct SourceSlider: View {
    @Environment(AppModel.self) private var model
    let mixID: String
    let source: MixSource
    let level: Float
    let issue: SourceIssue?

    var body: some View {
        HStack {
            SourceIcon(source: source)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.caption)
                if let issue {
                    Label(issue.text, systemImage: issue.urgent ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.caption2)
                        .foregroundStyle(issue.urgent ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                LevelMeter(level: level)
                GainSlider(gainDb: gain)
                    .controlSize(.mini)
            }
            Button {
                edit { $0.muted.toggle() }
            } label: {
                Image(systemName: source.mutedSymbol)
                    .foregroundStyle(source.muted ? .red : .secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(source.muted ? "Unmute \(source.name)" : "Mute \(source.name)")
        }
    }

    private var gain: Binding<Double> {
        Binding(get: { source.gainDb }, set: { value in edit { $0.gainDb = value } })
    }

    private func edit(_ change: (inout MixSource) -> Void) {
        guard var mix = model.store.mix(id: mixID),
              let index = mix.sources.firstIndex(where: { $0.id == source.id }) else {
            return
        }
        change(&mix.sources[index])
        model.store.update(mix)
    }
}

/// Only a mix of exactly two sources can be split, so the toggle exists only for those.
struct SplitToggle: View {
    @Environment(AppModel.self) private var model
    let mix: Mix

    var body: some View {
        Toggle("Split by channel", isOn: Binding(get: { mix.split }, set: { on in
            var updated = mix
            updated.split = on
            model.store.update(updated)
        }))
        .help(mix.splitDescription)
    }
}

/// Shown only where ducking can apply: a physical mic and another source, and not split.
struct DuckToggle: View {
    @Environment(AppModel.self) private var model
    let mix: Mix

    var body: some View {
        Toggle("Lower other sources while I talk", isOn: Binding(get: { mix.duck }, set: { on in
            var updated = mix
            updated.duck = on
            model.store.update(updated)
        }))
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            let db = level > 0 ? 20 * log10(Double(level)) : -60
            let fraction = max(0, min(1, (db + 60) / 60))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                // Red only where the limiter is holding the level at -1 dBFS.
                Capsule()
                    .fill(db > -1.2 ? Color.red : db > -12 ? Color.yellow : Color.green)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(level > 0 ? String(format: "%.0f decibels", 20 * log10(Double(level))) : "silent")
    }
}

/// Volume from -40 to +12 dB that snaps to 0 dB near the middle mark.
struct GainSlider: View {
    @Binding var gainDb: Double

    var body: some View {
        Slider(value: Binding(get: { gainDb }, set: { gainDb = abs($0) < 1.5 ? 0 : $0.rounded() }),
            in: -40...12)
            .accessibilityLabel("Volume")
            .accessibilityValue(String(format: "%+.0f decibels", gainDb))
            .help(String(format: "%+.0f dB", gainDb))
    }
}

extension MixSource {
    var symbol: String {
        switch kind {
        case .device: "mic"
        case .app: "app.dashed"
        case .system: "laptopcomputer"
        }
    }

    var mutedSymbol: String {
        switch (kind, muted) {
        case (.device, true): "mic.slash.fill"
        case (.device, false): "mic.fill"
        case (.app, true), (.system, true): "speaker.slash.fill"
        case (.app, false), (.system, false): "speaker.wave.2.fill"
        }
    }
}

struct SourceIcon: View {
    @Environment(AppModel.self) private var model
    let source: MixSource

    var body: some View {
        Group {
            if source.kind == .app, let icon = model.catalog.icon(for: source) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: source.symbol)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// Starts or stops a check of a mix and says what it is doing.
struct CheckButton: View {
    @Environment(AppModel.self) private var model
    let mix: Mix
    var compact = false

    var body: some View {
        let phase = model.check.phase(for: mix)
        Button {
            model.check.toggle(mix)
        } label: {
            if compact {
                Image(systemName: phase == .idle ? "headphones" : "stop.circle.fill")
                    .foregroundStyle(phase == .idle ? Color.primary : Color.accentColor)
                    .frame(width: 20, height: 20)
            } else {
                Text(title(phase))
            }
        }
        .modifier(Compact(on: compact))
        .accessibilityLabel(phase == .idle ? "Check \(mix.name)" : title(phase))
        .help(phase == .idle ? "Check this mix: hear it live on headphones, or record and play back on speakers" : title(phase))
    }

    private func title(_ phase: MixCheck.Phase) -> String {
        switch phase {
        case .idle: "Check"
        case .listening: "Listening live · Stop"
        case let .recording(left): "Speak now… \(left) · Stop"
        case .playing: "Playing back · Stop"
        }
    }
}

private struct Compact: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content.buttonStyle(.borderless)
        } else {
            content
        }
    }
}
