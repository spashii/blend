import XCTest

final class MoveToApplicationsTests: XCTestCase {
    private let home = "/Users/someone"

    private func offers(_ path: String, debug: Bool = false, skip: Bool = false,
                        declined: Set<String> = []) -> Bool {
        MoveToApplications.shouldOffer(.init(path: path, home: home, isDebugBuild: debug,
            skippedByEnvironment: skip, declinedPaths: declined))
    }

    func testNoPromptInApplications() {
        XCTAssertFalse(offers("/Applications/Blend.app"))
        XCTAssertFalse(offers("/Applications/Utilities/Blend.app"))
        XCTAssertFalse(offers("/Users/someone/Applications/Blend.app"))
    }

    func testPromptsFromEverywhereElse() {
        XCTAssertTrue(offers("/Volumes/Blend Mic 0.7.0/Blend.app"))
        XCTAssertTrue(offers("/Users/someone/Downloads/Blend.app"))
        XCTAssertTrue(offers("/Users/someone/Desktop/Blend.app"))
        XCTAssertTrue(offers("/private/var/folders/ab/cd/T/AppTranslocation/1234/d/Blend.app"))
        // A look-alike folder is not /Applications.
        XCTAssertTrue(offers("/Applications Old/Blend.app"))
        XCTAssertTrue(offers("/Users/other/Applications/Blend.app"))
    }

    func testTranslocatedCopyOfAnAppAlreadyInApplicationsDoesNotPrompt() {
        // The original path is what counts once macOS has told us.
        XCTAssertFalse(offers("/Applications/Blend.app"))
        XCTAssertTrue(MoveToApplications.isTranslocatedPath(
            "/private/var/folders/ab/cd/T/AppTranslocation/1234/d/Blend.app"))
        XCTAssertFalse(MoveToApplications.isTranslocatedPath("/Users/someone/Downloads/Blend.app"))
    }

    func testDebugBuildsAndTheEnvironmentNeverPrompt() {
        XCTAssertFalse(offers("/Users/someone/work/blend/build/app/Blend.app", debug: true))
        XCTAssertFalse(offers("/Volumes/Blend Mic/Blend.app", skip: true))
    }

    func testNotNowIsRememberedPerPath() {
        let declined: Set<String> = ["/Users/someone/Downloads/Blend.app"]
        XCTAssertFalse(offers("/Users/someone/Downloads/Blend.app", declined: declined))
        XCTAssertTrue(offers("/Users/someone/Desktop/Blend.app", declined: declined))
    }

    func testDownloadsDetection() {
        XCTAssertTrue(MoveToApplications.isInDownloads("/Users/someone/Downloads/Blend.app", home: home))
        XCTAssertFalse(MoveToApplications.isInDownloads("/Users/someone/Desktop/Blend.app", home: home))
    }

    // MARK: Copying

    private func makeApp(at root: URL, name: String = "Blend.app", contents: String) throws -> URL {
        let app = root.appending(path: name)
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"),
            withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: app.appending(path: "Contents/marker"))
        return app
    }

    private func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    func testCopiesAndClearsQuarantineOnTheCopyOnly() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MoveTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appending(path: "Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let source = try makeApp(at: root.appending(path: "Downloads"), contents: "new")
        let value = "0083;00000000;Safari;"
        XCTAssertEqual(setxattr(source.path, "com.apple.quarantine", value, value.utf8.count, 0, 0), 0)

        let outcome = try MoveToApplications.move(source, into: applications, isRunning: { _ in false },
            elevated: { _, _, _ in XCTFail("no administrator rights needed") })
        guard case .moved(let copy) = outcome else { return XCTFail("\(outcome)") }

        XCTAssertEqual(copy, applications.appending(path: "Blend.app"))
        XCTAssertEqual(try String(contentsOf: copy.appending(path: "Contents/marker"), encoding: .utf8), "new")
        XCTAssertFalse(hasQuarantine(copy))
        XCTAssertTrue(hasQuarantine(source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: applications.appending(path: ".Blend.app.moving").path))
    }

    func testReplacesAnOlderCopyThatIsNotRunning() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MoveTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appending(path: "Applications")
        _ = try makeApp(at: applications, contents: "old")
        let source = try makeApp(at: root.appending(path: "Volume"), contents: "new")

        let outcome = try MoveToApplications.move(source, into: applications, isRunning: { _ in false })
        guard case .moved(let copy) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try String(contentsOf: copy.appending(path: "Contents/marker"), encoding: .utf8), "new")
    }

    func testNeverReplacesACopyThatIsRunning() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MoveTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appending(path: "Applications")
        let old = try makeApp(at: applications, contents: "old")
        let source = try makeApp(at: root.appending(path: "Volume"), contents: "new")

        XCTAssertThrowsError(try MoveToApplications.move(source, into: applications, isRunning: { _ in true })) {
            XCTAssertEqual($0 as? MoveToApplications.MoveError, .alreadyRunning)
        }
        XCTAssertEqual(try String(contentsOf: old.appending(path: "Contents/marker"), encoding: .utf8), "old")
    }

    func testAsksForAdministratorRightsWhenTheFolderIsNotWritable() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MoveTests-\(UUID().uuidString)")
        let applications = root.appending(path: "Applications")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: applications.path)
            try? FileManager.default.removeItem(at: root)
        }
        let source = try makeApp(at: root, contents: "new")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o555])
        var asked = false
        _ = try MoveToApplications.move(source, into: applications, isRunning: { _ in false },
            elevated: { _, _, _ in asked = true })
        XCTAssertTrue(asked)
    }

    // MARK: Versions

    private func setVersion(_ version: String, of app: URL) throws {
        let plist: [String: Any] = ["CFBundleIdentifier": "app.blend.Blend", "CFBundleVersion": version]
        try (plist as NSDictionary).write(to: app.appending(path: "Contents/Info.plist"))
    }

    func testVersionsCompareNumerically() {
        XCTAssertTrue(MoveToApplications.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertTrue(MoveToApplications.isNewer("0.7.0", than: "0.6.4"))
        XCTAssertTrue(MoveToApplications.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(MoveToApplications.isNewer("0.7.0", than: "0.7.0"))
        XCTAssertFalse(MoveToApplications.isNewer("0.7", than: "0.7.0"))
        XCTAssertFalse(MoveToApplications.isNewer("0.6.4", than: "0.7.0"))
        XCTAssertFalse(MoveToApplications.isNewer("0.9.0", than: "0.10.0"))
    }

    func testNeverDowngradesOrReplacesTheSameVersion() throws {
        for installed in ["0.7.0", "0.8.0"] {
            let root = FileManager.default.temporaryDirectory.appending(path: "MoveTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let applications = root.appending(path: "Applications")
            let old = try makeApp(at: applications, contents: "installed")
            try setVersion(installed, of: old)
            let source = try makeApp(at: root.appending(path: "Volume"), contents: "disk image")
            try setVersion("0.7.0", of: source)

            let outcome = try MoveToApplications.move(source, into: applications, isRunning: { _ in false },
                elevated: { _, _, _ in XCTFail("nothing to do as administrator") })
            guard case .keptInstalled(let kept) = outcome else { return XCTFail("\(outcome)") }
            XCTAssertEqual(kept.standardizedFileURL.path, old.standardizedFileURL.path)
            XCTAssertEqual(try String(contentsOf: old.appending(path: "Contents/marker"), encoding: .utf8), "installed")
        }
    }

    func testReplacesAnOlderVersion() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MoveTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appending(path: "Applications")
        let old = try makeApp(at: applications, contents: "installed")
        try setVersion("0.6.4", of: old)
        let source = try makeApp(at: root.appending(path: "Volume"), contents: "disk image")
        try setVersion("0.7.0", of: source)

        let outcome = try MoveToApplications.move(source, into: applications, isRunning: { _ in false })
        guard case .moved(let moved) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(moved.standardizedFileURL.path, old.standardizedFileURL.path)
        XCTAssertEqual(try String(contentsOf: old.appending(path: "Contents/marker"), encoding: .utf8), "disk image")
    }

    // MARK: Administrator rights

    func testOnlyPermissionErrorsAskForAdministratorRights() {
        XCTAssertTrue(MoveToApplications.isPermissionError(MoveToApplications.MoveError.permissionDenied))
        XCTAssertTrue(MoveToApplications.isPermissionError(POSIXError(.EACCES)))
        XCTAssertTrue(MoveToApplications.isPermissionError(POSIXError(.EPERM)))
        XCTAssertTrue(MoveToApplications.isPermissionError(CocoaError(.fileWriteNoPermission)))
        XCTAssertFalse(MoveToApplications.isPermissionError(POSIXError(.ENOSPC)))
        XCTAssertFalse(MoveToApplications.isPermissionError(CocoaError(.fileWriteOutOfSpace)))
        XCTAssertFalse(MoveToApplications.isPermissionError(MoveToApplications.MoveError.failed("No space left")))
    }

    func testAnotherFailureDoesNotAskForAdministratorRights() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "MoveTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appending(path: "Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let missingSource = root.appending(path: "Nowhere/Blend.app")
        XCTAssertThrowsError(try MoveToApplications.move(missingSource, into: applications, isRunning: { _ in false },
            elevated: { _, _, _ in XCTFail("not a permission problem") })) {
            guard case .failed = $0 as? MoveToApplications.MoveError else { return XCTFail("\($0)") }
        }
    }
}
