import Foundation

/// Scrubs secrets and personal identifiers out of text before it leaves the
/// machine for a *third-party* cloud endpoint.
///
/// Smriti's reply assist can send the visible window text (plus a few memory
/// snippets and your tone profile) to a BYOK cloud lane — Groq, OpenRouter,
/// or any OpenAI-compatible provider. That's the one place Smriti hands your
/// screen contents to someone else's server, which is exactly the trust
/// problem Smriti was built to avoid. This is the last gate before that:
/// it collapses API keys, tokens, private keys, card numbers, emails and the
/// like down to labeled placeholders so the model still understands the shape
/// of the text without receiving the secret itself.
///
/// The local lanes (Ollama on your Mac, and your own Claude subscription)
/// always get the raw, unredacted prompt — this only guards egress to other
/// people's infrastructure.
///
/// Pure and deterministic, so it's unit-tested and previewable from the CLI
/// (`smriti redact "<text>"`).
public enum Redactor {

    public struct Result: Equatable {
        public let text: String
        public let count: Int
        public var didRedact: Bool { count > 0 }
    }

    /// A named redaction rule: a regex, the placeholder its matches collapse
    /// to, and an optional extra check on the matched substring (used for the
    /// Luhn test on candidate card numbers).
    private struct Rule {
        let label: String
        let regex: NSRegularExpression
        let validate: ((String) -> Bool)?

        init(_ label: String, _ pattern: String,
             options: NSRegularExpression.Options = [],
             validate: ((String) -> Bool)? = nil) {
            self.label = label
            // Patterns are compile-time constants; a failure here is a
            // programming error and is caught by the test suite.
            self.regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.validate = validate
        }
    }

    /// Scrub `text`, returning the redacted string and how many values were
    /// removed. Rules run high-confidence secret shapes first, then PII, then
    /// the broad `key = value` catch-all last.
    public static func redact(_ text: String) -> Result {
        var out = text
        var count = 0
        for rule in rules {
            let ns = out as NSString
            let matches = rule.regex.matches(
                in: out, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            // Replace right-to-left so earlier match ranges stay valid.
            for match in matches.reversed() {
                let matched = ns.substring(with: match.range)
                if let validate = rule.validate, !validate(matched) { continue }
                out = (out as NSString).replacingCharacters(
                    in: match.range, with: "[REDACTED_\(rule.label)]")
                count += 1
            }
        }
        return Result(text: out, count: count)
    }

    /// Convenience for call sites that only want the scrubbed string.
    public static func scrub(_ text: String) -> String { redact(text).text }

    // MARK: - Rules

    private static let rules: [Rule] = [
        // --- High-confidence secret shapes (unambiguous prefixes) ---
        Rule("PRIVATE_KEY",
             "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----"),
        Rule("JWT",
             "\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\b"),
        Rule("AWS_KEY", "\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b"),
        Rule("TOKEN", "\\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}\\b"),
        Rule("TOKEN", "\\bxox[baprs]-[A-Za-z0-9-]{10,}\\b"),
        Rule("API_KEY", "\\bsk-[A-Za-z0-9_-]{16,}\\b"),
        Rule("API_KEY", "\\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{10,}\\b"),
        Rule("API_KEY", "\\bAIza[0-9A-Za-z_-]{35}\\b"),
        Rule("API_KEY", "\\bgsk_[A-Za-z0-9]{20,}\\b"),          // Groq
        Rule("API_KEY", "\\bsk-or-v1-[A-Za-z0-9]{20,}\\b"),     // OpenRouter
        Rule("TOKEN", "Bearer\\s+[A-Za-z0-9._-]{12,}",
             options: [.caseInsensitive]),

        // --- Personal identifiers ---
        Rule("EMAIL",
             "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b"),
        Rule("SSN", "\\b\\d{3}-\\d{2}-\\d{4}\\b"),
        // Candidate card numbers: 13–19 digits, optionally spaced/dashed in
        // groups. Only redacted if they pass the Luhn checksum, so ordinary
        // long numbers (order ids, timestamps) are left alone.
        Rule("CARD", "\\b\\d(?:[ -]?\\d){12,18}\\b", validate: luhnValid),
        // Phone numbers, but only with separators — bare 10-digit runs are
        // too often ids to redact safely.
        Rule("PHONE",
             "(?:\\+?\\d{1,3}[ .-]?)?(?:\\(\\d{3}\\)|\\d{3})[ .-]\\d{3}[ .-]\\d{4}"),

        // --- Broad catch-all: secret-looking assignments ---
        // Matches key: value / key = value where the key names a credential.
        // Runs last so a more specific rule above wins when it applies.
        Rule("SECRET",
             "(?i)\\b(?:password|passwd|pwd|secret|token|api[_-]?key|apikey|"
             + "access[_-]?key|secret[_-]?key|client[_-]?secret|"
             + "authorization|auth[_-]?token)\\b\\s*[:=]\\s*['\"]?[^\\s'\";,]{3,}['\"]?"),
    ]

    // MARK: - Luhn

    /// True when the digits of `s` (ignoring spaces/dashes) form a 13–19 digit
    /// string that passes the Luhn checksum — the shape of a real card number.
    static func luhnValid(_ s: String) -> Bool {
        let digits = s.compactMap { $0.wholeNumberValue }
        guard digits.count >= 13, digits.count <= 19 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }
}
