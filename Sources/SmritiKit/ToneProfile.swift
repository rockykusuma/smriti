import Foundation

/// Learns and stores the user's writing style so drafted replies sound like
/// them (Goldfish's "writes in your tone"). The profile is a short markdown
/// style guide distilled by Claude from captured communication windows, kept
/// as a plain file the user can read and edit.
public enum ToneProfile {

    public static var path: URL {
        Config.supportDirectory.appendingPathComponent("tone.md")
    }

    /// The stored profile, if the user has run `smriti learn-tone`.
    public static func load() -> String? {
        guard let text = try? String(contentsOf: path, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Bundle ids of apps whose windows contain the user's own writing.
    static let communicationApps: Set<String> = [
        "com.microsoft.teams2", "com.microsoft.teams",
        "com.tinyspeck.slackmacgap",
        "com.apple.MobileSMS", "com.apple.mail",
        "com.microsoft.Outlook",
        "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram",
        "com.hnc.Discord",
    ]

    /// Distill a style profile from captured snapshots and persist it.
    /// Returns the profile text.
    public static func learn(store: Store) throws -> String {
        // Sample recent communication windows; browsers are included because
        // webmail/LinkedIn/Teams-web live there.
        let all = try store.recent(minutes: 60 * 24 * 14) // two weeks
        let samples = all.filter {
            communicationApps.contains($0.bundleId)
                || BrowserURL.isBrowser($0.bundleId)
        }
        guard !samples.isEmpty else {
            throw ToneError.noSamples
        }
        var digest = ""
        for s in samples.prefix(120) {
            let block = "[\(s.app) — \(s.windowTitle)]\n\(s.content.prefix(600))\n\n"
            if digest.count + block.count > 90_000 { break }
            digest += block
        }

        let userName = NSFullUserName()
        let prompt = """
        Below are text captures of communication windows (chats, mails, \
        comment threads) from the Mac of a user named "\(userName)". The \
        captures mix messages the user WROTE with messages they RECEIVED. \
        Identify which messages are the user's own (sender name matching \
        "\(userName)" or its variants, message alignment cues, first-person \
        drafts in compose boxes) and distill HOW THE USER WRITES.

        Output a compact markdown style guide (max 20 lines) covering: \
        greeting/sign-off habits, formality by audience (colleagues vs \
        friends), typical message length, punctuation/emoji/abbreviation \
        habits, characteristic phrases, and language(s) used. Write rules, \
        not observations ("Keep replies under two sentences", not "the user \
        wrote short replies"). Output ONLY the style guide.
        """
        let profile = try ClaudeCLI.run(prompt: prompt, stdin: digest)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.isEmpty else { throw ToneError.emptyProfile }
        try profile.write(to: path, atomically: true, encoding: .utf8)
        return profile
    }

    public enum ToneError: Error, CustomStringConvertible {
        case noSamples
        case emptyProfile
        public var description: String {
            switch self {
            case .noSamples:
                return "no captured communication windows yet — chat/mail for a while with capture running, then retry"
            case .emptyProfile:
                return "claude returned an empty profile"
            }
        }
    }
}
