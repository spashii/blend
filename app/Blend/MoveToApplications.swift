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
        case failed(String)
    }

    /// Copies `source` to `applications`/Blend.app and returns the copy. The copy is made beside
    /// its destination and swapped in, so an older Blend stays if anything fails. The
    /// quarantine attribute comes off the copy only; the original is left as it was found.
    /// `elevated` runs the same steps as root after the system's administrator prompt.
    static func move(
        _ source: URL,
        into applications: URL = URL(fileURLWithPath: "/Applications"),
        isRunning: (URL) -> Bool,
        elevated: (_ source: URL, _ staging: URL, _ destination: URL) throws -> Void = runElevated
    ) throws -> URL {
        let files = FileManager.default
        let destination = applications.appendingPathComponent("Blend.app")
        let staging = applications.appendingPathComponent(".Blend.app.moving")
        if files.fileExists(atPath: destination.path), isRunning(destination) {
            throw MoveError.alreadyRunning
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
            do {
                try elevated(source, staging, destination)
            } catch let error as MoveError {
                throw error
            } catch {
                throw MoveError.failed(error.localizedDescription)
            }
        }
        return destination
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
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            throw MoveError.failed(text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? tool)
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
        let command = "rm -rf \(staging) && /usr/bin/ditto \(source) \(staging)"
            + " && /usr/bin/xattr -dr com.apple.quarantine \(staging)"
            + " && chown -R \(getuid()):\(getgid()) \(staging)"
            + " && rm -rf \(destination) && mv \(staging) \(destination)"
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

        let ownID = Bundle.main.bundleIdentifier
        do {
            let copy = try move(bundle, isRunning: { destination in
                NSRunningApplication.runningApplications(withBundleIdentifier: ownID ?? "")
                    .contains { $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL }
            })
            if trashOriginal {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: original), resultingItemURL: nil)
            }
            relaunch(copy)
            exit(0)
        } catch MoveError.alreadyRunning {
            let note = NSAlert()
            note.messageText = "Blend Mic is already open from Applications"
            note.informativeText = "Quit it from its menu, then open this copy again to replace it."
            note.runModal()
            exit(0)
        } catch MoveError.cancelled {
            return
        } catch {
            let note = NSAlert()
            note.alertStyle = .warning
            note.messageText = "Blend Mic couldn't move itself"
            note.informativeText = "\(error)"
            note.runModal()
        }
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
