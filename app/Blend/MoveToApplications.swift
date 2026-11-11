import AppKit
import Foundation

/// Offers to move Blend into /Applications when it was opened from somewhere else, such as
/// the mounted disk image (a read-only volume), a translocated copy or ~/Downloads. Anywhere
/// outside /Applications and ~/Applications counts. Updates, Login Items and the
/// driver's Setup all assume a copy that stays where it is. It runs at launch, before the
/// model exists, so nothing touches the driver from a copy that is about to be replaced.
enum MoveToApplications {
    /// Everything the decision depends on, so tests can state each case.
    struct Situation {
        /// Where the person put the app. For a translocated copy, the original location when
        /// macOS tells us, otherwise the random path it runs from.
        var path: String
        var home: String
        var isDebugBuild: Bool
        /// BLEND_SKIP_MOVE is set, for running a Release build from a build folder.
        var skippedByEnvironment: Bool
        var declinedPaths: Set<String>
    }

    static func shouldOffer(_ situation: Situation) -> Bool {
        if situation.isDebugBuild || situation.skippedByEnvironment {
            return false
        }
        if isInApplications(situation.path, home: situation.home) {
            return false
        }
        return !situation.declinedPaths.contains(situation.path)
    }

    /// /Applications and ~/Applications count, subfolders included.
    static func isInApplications(_ path: String, home: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// The path macOS runs a quarantined app from until the person moves it, which is
    /// different on every launch and so can't be remembered.
    static func isTranslocatedPath(_ path: String) -> Bool {
        path.hasPrefix("/private/var/folders/") && path.contains("/AppTranslocation/")
    }

    static func isInDownloads(_ path: String, home: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(home + "/Downloads/")
    }

    // MARK: Moving

    enum MoveError: Error, Equatable {
        /// A copy in the destination folder is running, and replacing it would pull it from
        /// under its own process.
        case alreadyRunning
        /// The person dismissed the administrator prompt.
        case cancelled
        /// EACCES or EPERM: the only failure that administrator rights can fix.
        case permissionDenied
        case failed(String)
    }

    enum Outcome: Equatable {
        case moved(URL)
        /// The copy in Applications is the same version or newer, so it stays.
        case keptInstalled(URL)
    }

    /// Versions compare numerically, part by part: 0.10.0 is newer than 0.9.0. A part that
    /// isn't a number counts as 0, and a missing part as 0.
    static func isNewer(_ version: String, than other: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        var a = parts(version), b = parts(other)
        let length = max(a.count, b.count)
        a += Array(repeating: 0, count: length - a.count)
        b += Array(repeating: 0, count: length - b.count)
        return a.lexicographicallyPrecedes(b) ? false : a != b
    }

    static func bundleVersion(of app: URL) -> String? {
        Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    static func isPermissionError(_ error: Error) -> Bool {
        if case MoveError.permissionDenied = error { return true }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            return ns.code == Int(EACCES) || ns.code == Int(EPERM)
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }

    /// Copies `source` to `applications`/Blend.app and returns the copy. The copy is made beside
    /// its destination and swapped in, so an older Blend stays if anything fails. The
    /// quarantine attribute comes off the copy only; the original is left as it was found.
    /// `elevated` runs the same steps as root after the system's administrator prompt, and
    /// only when the first attempt failed for lack of permission. A copy in Applications that
    /// is the same version or newer is never replaced, so an old disk image can't downgrade it.
    static func move(
        _ source: URL,
        into applications: URL = URL(fileURLWithPath: "/Applications"),
        isRunning: (URL) -> Bool,
        elevated: (_ source: URL, _ staging: URL, _ destination: URL) throws -> Void = runElevated
    ) throws -> Outcome {
        let files = FileManager.default
        let destination = applications.appendingPathComponent("Blend.app")
        let staging = applications.appendingPathComponent(".Blend.app.moving")
        if files.fileExists(atPath: destination.path), isRunning(destination) {
            throw MoveError.alreadyRunning
        }
        if let installed = bundleVersion(of: destination), let mine = bundleVersion(of: source),
           !isNewer(mine, than: installed) {
            return .keptInstalled(destination)
        }
        try? files.removeItem(at: staging)
        do {
            try run("/usr/bin/ditto", [source.path, staging.path])
            try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staging.path])
            if files.fileExists(atPath: destination.path) {
                _ = try files.replaceItemAt(destination, withItemAt: staging)
            } else {
                try files.moveItem(at: staging, to: destination)
            }
        } catch {
            try? files.removeItem(at: staging)
            guard isPermissionError(error) else {
                throw error as? MoveError ?? MoveError.failed(error.localizedDescription)
            }
            do {
                try elevated(source, staging, destination)
            } catch let error as MoveError {
                throw error
            } catch {
                throw MoveError.failed(error.localizedDescription)
            }
        }
        return .moved(destination)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if text.contains("Permission denied") || text.contains("Operation not permitted") {
                throw MoveError.permissionDenied
            }
            throw MoveError.failed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The system's own administrator prompt, as `do shell script ... with administrator
    /// privileges` shows it. Cancelling it is not an error worth a dialog.
    private static func runElevated(source: URL, staging: URL, destination: URL) throws {
        let source = shellQuote(source.path), staging = shellQuote(staging.path)
        let destination = shellQuote(destination.path)
        let command = "{ rm -rf \(staging) && /usr/bin/ditto \(source) \(staging)"
            + " && /usr/bin/xattr -dr com.apple.quarantine \(staging)"
            + " && chown -R \(getuid()):\(getgid()) \(staging)"
            + " && rm -rf \(destination) && mv \(staging) \(destination); }"
            + " || { rm -rf \(staging); exit 1; }"
        let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 {
                throw MoveError.cancelled
            }
            throw MoveError.failed(error[NSAppleScript.errorMessage] as? String ?? "Administrator access failed.")
        }
    }

    // MARK: At launch

    private static let declinedKey = "moveToApplicationsDeclined"

    /// Asks, moves and relaunches. Returns only when Blend should carry on from where it is.
    @MainActor
    static func offerIfNeeded() {
        let bundle = Bundle.main.bundleURL
        let home = NSHomeDirectory()
        let original = originalPath(of: bundle) ?? bundle.path
        let translocated = isTranslocatedPath(original)
        let declined = Set(UserDefaults.standard.stringArray(forKey: declinedKey) ?? [])
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        let situation = Situation(path: original, home: home, isDebugBuild: debug,
            skippedByEnvironment: ProcessInfo.processInfo.environment["BLEND_SKIP_MOVE"] != nil,
            declinedPaths: declined)
        guard shouldOffer(situation) else { return }

        let trashOriginal = isInDownloads(original, home: home)
        let alert = NSAlert()
        alert.messageText = "Move Blend Mic to Applications?"
        alert.informativeText = "Blend Mic copies itself to Applications and opens from there."
            + (trashOriginal ? " This copy in Downloads goes to the Trash." : "")
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApplication.shared.activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            if !translocated {
                UserDefaults.standard.set(Array(declined.union([original])), forKey: declinedKey)
            }
            return
        }

        do {
            switch try move(bundle, isRunning: { destination in
                otherInstances().contains { $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL }
            }) {
            case .moved(let copy):
                if trashOriginal {
                    try? FileManager.default.trashItem(at: URL(fileURLWithPath: original), resultingItemURL: nil)
                }
                relaunch(copy)
            case .keptInstalled(let installed):
                relaunch(installed)
            }
            exit(0)
        } catch MoveError.alreadyRunning {
            explainAlreadyOpen()
        } catch MoveError.cancelled {
            return
        } catch {
            let note = NSAlert()
            note.alertStyle = .warning
            note.messageText = "Blend Mic couldn't move itself"
            note.informativeText = "You can drag Blend Mic into Applications yourself."
            note.runModal()
        }
    }

    private static func otherInstances() -> [NSRunningApplication] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != own && !$0.isTerminated }
    }

    private static func explainAlreadyOpen() {
        let note = NSAlert()
        note.messageText = "Blend Mic is already open"
        note.informativeText = "Quit it from its menu bar icon, then open this copy again."
        NSApplication.shared.activate()
        note.runModal()
        exit(0)
    }

    /// Two copies would both drive the same audio devices, so a second one explains and
    /// quits, wherever the first runs from. A copy that is still exiting, as after an update,
    /// gets a few seconds. Debug builds are exempt so development can run beside an install.
    @MainActor
    static func yieldToRunningCopy() {
        #if DEBUG
        return
        #else
        for _ in 0..<30 where !otherInstances().isEmpty {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if !otherInstances().isEmpty {
            explainAlreadyOpen()
        }
        #endif
    }

    /// Opens the copy once this process has exited, so two Blends never run at once.
    private static func relaunch(_ app: URL) {
        let script = "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$1\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", app.path]
        try? process.run()
    }

    /// Where a translocated app really lives, through the Security framework's private
    /// translocation calls, which have no header. Nil when it isn't translocated.
    private static func originalPath(of url: URL) -> String? {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isTranslocatedSymbol = dlsym(handle, "SecTranslocateIsTranslocatedURL"),
              let originalSymbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else {
            return nil
        }
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        var translocated = false
        let isTranslocated = unsafeBitCast(isTranslocatedSymbol, to: IsTranslocated.self)
        guard isTranslocated(url as CFURL, &translocated, nil), translocated else { return nil }
        let original = unsafeBitCast(originalSymbol, to: OriginalPath.self)
        guard let result = original(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        return (result as URL).path
    }
}
