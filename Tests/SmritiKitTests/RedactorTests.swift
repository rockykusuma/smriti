import XCTest
@testable import SmritiKit

final class RedactorTests: XCTestCase {

    private func redacted(_ s: String) -> String { Redactor.redact(s).text }

    // MARK: - Clean text is untouched

    func testCleanTextUnchanged() {
        let text = "Let's meet at 3pm to review the Q3 numbers and the roadmap."
        let result = Redactor.redact(text)
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.count, 0)
        XCTAssertFalse(result.didRedact)
    }

    // MARK: - Secret shapes

    func testEmail() {
        let out = redacted("Ping me at alice.smith@example.co.uk when ready")
        XCTAssertFalse(out.contains("alice.smith@example.co.uk"))
        XCTAssertTrue(out.contains("[REDACTED_EMAIL]"))
    }

    func testOpenAIStyleKey() {
        let out = redacted("key is sk-abc123DEF456ghi789JKL0mno here")
        XCTAssertFalse(out.contains("sk-abc123DEF456ghi789JKL0mno"))
        XCTAssertTrue(out.contains("[REDACTED_API_KEY]"))
    }

    func testGroqAndOpenRouterKeys() {
        XCTAssertTrue(redacted("gsk_ABCDEFGHIJKLMNOPQRSTUVWX").contains("[REDACTED_API_KEY]"))
        XCTAssertTrue(redacted("sk-or-v1-abcdefghijklmnopqrstuvwx").contains("[REDACTED_API_KEY]"))
    }

    func testGitHubToken() {
        let out = redacted("token ghp_1234567890abcdefghijklmnopqrstuvwxyz")
        XCTAssertTrue(out.contains("[REDACTED_TOKEN]"))
        XCTAssertFalse(out.contains("ghp_1234567890"))
    }

    func testSlackToken() {
        XCTAssertTrue(redacted("xoxb-123456789012-abcdefghijkl").contains("[REDACTED_TOKEN]"))
    }

    func testAWSAccessKey() {
        XCTAssertTrue(redacted("AKIAIOSFODNN7EXAMPLE").contains("[REDACTED_AWS_KEY]"))
    }

    func testBearerHeader() {
        let out = redacted("Authorization: Bearer eyabc.longtokenvalue-1234567890")
        XCTAssertFalse(out.contains("longtokenvalue"))
    }

    func testJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w"
        XCTAssertTrue(redacted("session=\(jwt)").contains("[REDACTED_JWT]"))
    }

    func testPrivateKeyBlock() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIBOwIBAAJBAKj34\nabcd\n-----END RSA PRIVATE KEY-----"
        let out = redacted("here it is:\n\(pem)\ndone")
        XCTAssertTrue(out.contains("[REDACTED_PRIVATE_KEY]"))
        XCTAssertFalse(out.contains("MIIBOwIBAAJBAKj34"))
        XCTAssertTrue(out.contains("here it is:"))
        XCTAssertTrue(out.contains("done"))
    }

    func testKeyValueSecret() {
        XCTAssertTrue(redacted("password: hunter2guess").contains("[REDACTED_SECRET]"))
        XCTAssertTrue(redacted("client_secret = abcd1234wxyz").contains("[REDACTED_SECRET]"))
    }

    // MARK: - PII

    func testSSN() {
        let out = redacted("SSN 123-45-6789 on file")
        XCTAssertTrue(out.contains("[REDACTED_SSN]"))
        XCTAssertFalse(out.contains("123-45-6789"))
    }

    func testPhoneWithSeparators() {
        XCTAssertTrue(redacted("call (415) 555-0132 tomorrow").contains("[REDACTED_PHONE]"))
    }

    // MARK: - Credit cards (Luhn-gated)

    func testValidCardRedacted() {
        // 4111 1111 1111 1111 is the well-known Visa test number (Luhn-valid).
        let out = redacted("card 4111 1111 1111 1111 exp 12/28")
        XCTAssertTrue(out.contains("[REDACTED_CARD]"))
        XCTAssertFalse(out.contains("4111 1111 1111 1111"))
    }

    func testNonLuhnLongNumberKept() {
        // A 16-digit number that fails Luhn (e.g. an order id) must survive.
        let orderId = "1111111111111111"
        XCTAssertFalse(Redactor.luhnValid(orderId))
        let out = redacted("order number \(orderId) shipped")
        XCTAssertTrue(out.contains(orderId))
        XCTAssertFalse(out.contains("[REDACTED_CARD]"))
    }

    func testLuhnHelper() {
        XCTAssertTrue(Redactor.luhnValid("4111111111111111"))
        XCTAssertFalse(Redactor.luhnValid("4111111111111112"))
        XCTAssertFalse(Redactor.luhnValid("12345")) // too short
    }

    // MARK: - Counting & multiple values

    func testCountsMultipleDistinctValues() {
        let text = "email a@b.com and key sk-abc123DEF456ghi789JKL0mno now"
        let result = Redactor.redact(text)
        XCTAssertEqual(result.count, 2)
    }
}
