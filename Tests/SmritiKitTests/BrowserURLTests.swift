import XCTest
@testable import SmritiKit

final class BrowserURLTests: XCTestCase {

    func testDomainExtraction() {
        XCTAssertEqual(BrowserURL.domain(of: "https://www.example.com/path?q=1"), "example.com")
        XCTAssertEqual(BrowserURL.domain(of: "https://docs.example.com/guide"), "docs.example.com")
        XCTAssertEqual(BrowserURL.domain(of: "http://localhost:3000/"), "localhost")
        XCTAssertNil(BrowserURL.domain(of: "not a url"))
        XCTAssertNil(BrowserURL.domain(of: ""))
    }

    func testDomainMatchingIncludesSubdomains() {
        XCTAssertTrue(BrowserURL.domain("example.com", matches: "example.com"))
        XCTAssertTrue(BrowserURL.domain("docs.example.com", matches: "example.com"))
        XCTAssertTrue(BrowserURL.domain("a.b.example.com", matches: "EXAMPLE.com"))
        XCTAssertFalse(BrowserURL.domain("notexample.com", matches: "example.com"))
        XCTAssertFalse(BrowserURL.domain("example.com.evil.net", matches: "example.com"))
    }

    func testBrowserDetection() {
        XCTAssertTrue(BrowserURL.isBrowser("com.apple.Safari"))
        XCTAssertTrue(BrowserURL.isBrowser("company.thebrowser.Browser"))
        XCTAssertFalse(BrowserURL.isBrowser("com.apple.dt.Xcode"))
    }
}
