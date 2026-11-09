import XCTest

final class LeftoversTests: XCTestCase {
    /// Uninstall reaches only Blend's own files: each is named after its bundle identifier or
    /// is its folder in Application Support.
    func testPathsAreBlendsOwn() {
        let library = URL(fileURLWithPath: "/Users/someone/Library")
        let cache = URL(fileURLWithPath: "/var/folders/xx/yy/C", isDirectory: true)
        let paths = Leftovers.paths(domain: "app.blend.Blend", library: library, userCache: cache)
        XCTAssertTrue(paths.contains(library.appending(path: "Preferences/app.blend.Blend.plist")))
        XCTAssertTrue(paths.contains(library.appending(path: "Application Support/Blend")))
        XCTAssertTrue(paths.contains(cache.appending(path: "app.blend.Blend")))
        for path in paths {
            XCTAssertTrue(path.lastPathComponent.hasPrefix("app.blend.Blend")
                || path.path.hasSuffix("/Library/Application Support/Blend"), path.path)
        }
    }

    /// Nothing goes while the app runs; once it exits its files go and a neighbour's stay.
    /// The domain is one no app uses, so the `defaults delete` it runs touches nothing real.
    func testRemovesOnlyAfterTheAppExits() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appending(path: "LeftoversTests-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let domain = "app.blend.tests.\(UUID().uuidString)"
        let paths = Leftovers.paths(domain: domain, library: root.appending(path: "Library"),
            userCache: root.appending(path: "C"))
        for path in paths {
            try files.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: path)
        }
        let neighbour = root.appending(path: "Library/Preferences/com.example.Other.plist")
        try Data("x".utf8).write(to: neighbour)

        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["1"]
        try app.run()
        let cleanup = try XCTUnwrap(Leftovers.removeAfterExit(of: app.processIdentifier, domain: domain,
            paths: paths))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(paths.allSatisfy { files.fileExists(atPath: $0.path) })

        app.waitUntilExit()
        var status: Int32 = 0
        XCTAssertEqual(waitpid(cleanup, &status, 0), cleanup)
        XCTAssertEqual(paths.filter { files.fileExists(atPath: $0.path) }, [])
        XCTAssertTrue(files.fileExists(atPath: neighbour.path))
    }
}
