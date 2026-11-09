import XCTest

final class SupportItemsTests: XCTestCase {
    func testMenuOrder() {
        XCTAssertEqual(SupportItem.allCases.map(\.title),
                       ["Check for Updates…", "Report an Issue…", "View on GitHub"])
    }

    func testRepository() {
        XCTAssertEqual(SupportItem.repository.absoluteString, "https://github.com/spashii/blend")
    }

    func testIssueBodyHoldsOnlyTheVersions() throws {
        let url = SupportItem.issueURL(appVersion: "0.6.0", macOS: "Version 26.6.2 (Build 25G100)")
        XCTAssertEqual(url.absoluteString,
                       "https://github.com/spashii/blend/issues/new?body=App%20version:%200.6.0%0AmacOS:%20Version%2026.6.2%20(Build%2025G100)%0A%0A")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items, [URLQueryItem(name: "body",
                                            value: "App version: 0.6.0\nmacOS: Version 26.6.2 (Build 25G100)\n\n")])
    }

    /// A + would reach GitHub as a space, and an & or = would start another parameter.
    func testIssueBodyEncodesQuerySeparators() throws {
        let url = SupportItem.issueURL(appVersion: "1.0+dev&title=x", macOS: "Version 26.0")
        XCTAssertTrue(url.absoluteString.contains("1.0%2Bdev%26title%3Dx"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["body"])
        XCTAssertEqual(items.first?.value, "App version: 1.0+dev&title=x\nmacOS: Version 26.0\n\n")
    }
}
