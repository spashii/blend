import BlendKitCore
import Foundation
import Testing

@testable import BlendKit

// No test here opens a device or a tap. BLENDKIT_LIVE=1 adds one that does.

private let kitFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite struct VersionTests {
    @Test func versionIsBlendsVersionFile() throws {
        let file = kitFolder.deletingLastPathComponent().appendingPathComponent("VERSION")
        let text = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!BlendKit.version.isEmpty)
        #expect(BlendKit.version == text)
    }

    @Test func everyComponentIsInTheNotices() throws {
        let notices = try String(
            contentsOf: kitFolder.appendingPathComponent("THIRD_PARTY_NOTICES.md"),
            encoding: .utf8)
        for component in BlendKit.thirdPartyComponents {
            #expect(notices.contains(component.name), "\(component.name) is missing")
        }
        #expect(!notices.contains("libASPL"))
    }
}

@Suite struct AppsTests {
    @Test func decodesTheEngineList() {
        let json = """
            [{"bundleID":"us.zoom.xos","name":"zoom.us","pid":412,"identity":"","label":"zoom.us",
              "playing":true,"listening":true},
             {"bundleID":"org.mozilla.firefox","name":"Firefox","pid":900,"identity":"work",
              "label":"Firefox (work)","playing":false,"listening":false}]
            """
        let apps = AudioApps.parse(Data(json.utf8))
        #expect(apps.count == 2)
        #expect(apps[0].instance == nil)
        #expect(apps[0].isPlaying && apps[0].isListening)
        #expect(apps[0].target == TapTarget(bundleID: "us.zoom.xos"))
        #expect(apps[1].instance == "work")
        #expect(apps[1].id == "org.mozilla.firefox#work")
        #expect(apps[1].target == TapTarget(bundleID: "org.mozilla.firefox", instance: "work"))
    }

    @Test func ignoresWhatItCannotRead() {
        #expect(AudioApps.parse(Data("not json".utf8)).isEmpty)
        #expect(AudioApps.parse(Data("[]".utf8)).isEmpty)
    }

    @Test func listsRunningApps() {
        // Reads the process list only. The test runner is itself an app copy at times, so
        // nothing about the content is assumed.
        for app in AudioApps.running() {
            #expect(!app.bundleID.isEmpty)
        }
    }
}

@Suite struct CallCaptureTests {
    @Test func defaultsAreWhatDictateNeeds() {
        let options = CallCaptureOptions(label: "Test", call: TapTarget(bundleID: "us.zoom.xos"))
        #expect(options.outputRate == 48000)
        #expect(options.microphoneUID == nil)
        #expect(options.echoCancellation == .automatic)
    }

    @Test func createsStopsAndDestroysWithoutADevice() {
        let capture = CallCapture(
            options: CallCaptureOptions(label: "Test", call: TapTarget(bundleID: "us.zoom.xos")),
            frames: { _, _, _ in }, events: { _ in })
        #expect(capture.diagnostics.hasPrefix("stopped"))
        capture.stop()
        capture.stop()
    }

    @Test func mapsEveryEvent() {
        let kinds: [(BKEventKind, CallCapture.Event)] = [
            (BKEventMicrophoneRestarted, .microphoneRestarted),
            (BKEventMicrophoneLost, .microphoneLost),
            (BKEventCallTapLost, .callTapLost(reason: "why")),
            (BKEventCallTapRestored, .callTapRestored),
            (BKEventCallSilent, .callSilent),
            (BKEventCallHeard, .callHeard),
            (BKEventEchoCancellationFailed, .echoCancellationFailed),
            (BKEventOverflow, .overflow),
            (BKEventAudioServiceRestarted, .audioServiceRestarted),
        ]
        for (kind, expected) in kinds {
            #expect(CallCapture.Event(kind: kind, detail: "why") == expected)
        }
        #expect(CallCapture.Event(kind: BKEventKind(rawValue: 99), detail: nil) == nil)
    }

    @Test func deliversFramesAndEventsThroughTheTrampolines() {
        final class Seen: @unchecked Sendable {
            var me: [Float] = []
            var call: [Float] = []
            var position: UInt64 = 0
            var events: [CallCapture.Event] = []
        }
        let seen = Seen()
        let context = CallCapture.Context(
            frames: { me, call, position in
                seen.me = Array(me)
                seen.call = Array(call)
                seen.position = position
            },
            events: { seen.events.append($0) })
        let raw = Unmanaged.passRetained(context)
        defer { raw.release() }
        let me: [Float] = [1, 2, 3], call: [Float] = [-1, -2, -3]
        CallCapture.deliverFrames(raw.toOpaque(), me, call, 3, 480)
        CallCapture.deliverEvent(raw.toOpaque(), BKEventCallTapLost, "gone")
        #expect(seen.me == me && seen.call == call && seen.position == 480)
        #expect(seen.events == [.callTapLost(reason: "gone")])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BLENDKIT_LIVE"] == "1"))
    func liveCaptureOfTheDefaultMicrophone() throws {
        let capture = CallCapture(
            options: CallCaptureOptions(
                label: "Live", call: TapTarget(bundleID: "com.apple.Safari")),
            frames: { _, _, _ in }, events: { _ in })
        do {
            try capture.start()
            Thread.sleep(forTimeInterval: 2)
            capture.stop()
        } catch CallCaptureError.callUnavailable {
        }
    }
}

@Suite struct ProbesTests {
    @Test func startsEmptyAndStaysEmpty() {
        let probes = LevelProbes(label: "Test")
        #expect(probes.levels().isEmpty)
        probes.set([])
        #expect(probes.levels().isEmpty)
        probes.mute(index: 3, true)
    }
}
