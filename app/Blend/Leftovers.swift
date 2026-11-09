import Foundation

/// What Blend keeps in the user's Library besides its mixes: preferences, the URL cache and
/// Sparkle's downloads, URL session storage and window state, each named after the bundle
/// identifier. Some are written while Blend quits (cfprefsd flushes the preferences, AppKit
/// saves the open window), so Uninstall removes them from a process that outlives Blend.
enum Leftovers {
    /// Blend's own files and folders only: each one is named after the bundle identifier or
    /// is Blend's folder in Application Support, so another app's data never matches.
    static func paths(domain: String, library: URL, userCache: URL?) -> [URL] {
        let inLibrary = [
            "Application Support/Blend",
            "Preferences/\(domain).plist",
            "Caches/\(domain)",
            "HTTPStorages/\(domain)",
            "HTTPStorages/\(domain).binarycookies",
            "Saved Application State/\(domain).savedState",
            "WebKit/\(domain)",
        ].map { library.appending(path: $0) }
        // The system's per-app caches (Metal shaders and the like) sit in /var/folders.
        return inLibrary + (userCache.map { [$0.appending(path: domain)] } ?? [])
    }

    /// Removes Blend's files once this process has exited.
    static func removeAfterQuit(domain: String) {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        removeAfterExit(of: getpid(), domain: domain,
            paths: paths(domain: domain, library: library, userCache: userCacheDirectory))
    }

    /// Starts the removal in a session of its own, holding none of Blend's files open, so it
    /// keeps running after Blend quits. Returns the process, which nothing needs to wait for.
    @discardableResult
    static func removeAfterExit(of pid: pid_t, domain: String, paths: [URL]) -> pid_t? {
        let arguments = ["/bin/sh", "-c", script, "sh", String(pid), domain] + paths.map(\.path)
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        var child: pid_t = 0
        return posix_spawn(&child, "/bin/sh", &actions, &attributes, argv, envp) == 0 ? child : nil
    }

    /// Waits for the app to exit, five minutes at most, since a Blend still running then
    /// didn't finish uninstalling and still uses these files. The preferences go through
    /// `defaults` first: cfprefsd holds the domain in memory and would write it back over a
    /// file removed behind its back. cfprefsd can write the emptied domain out as a 42-byte
    /// file after `defaults` returns, so everything is removed once more a second later.
    static let script = """
        pid=$1 domain=$2
        shift 2
        i=0
        while kill -0 "$pid" 2>/dev/null; do
          [ $i -lt 1500 ] || exit 0
          sleep 0.2
          i=$((i + 1))
        done
        /usr/bin/defaults delete "$domain" >/dev/null 2>&1
        rm -rf -- "$@"
        sleep 1
        rm -rf -- "$@"
        """

    /// The per-user cache folder in /var/folders.
    private static var userCacheDirectory: URL? {
        let size = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, size) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
