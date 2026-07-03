import Foundation

/// Rolls one day of raw snapshots into a written "chronicle" by piping a
/// compacted digest through the Claude Code CLI (`claude -p`). Runs on the
/// user's existing subscription — Smriti itself contains no LLM.
public enum Chronicler {

    enum ChroniclerError: Error, CustomStringConvertible {
        case claudeNotFound
        case claudeFailed(status: Int32, stderr: String)
        case emptySummary

        var description: String {
            switch self {
            case .claudeNotFound:
                return "claude CLI not found. Install Claude Code (https://claude.com/claude-code) or add it to PATH."
            case .claudeFailed(let status, let stderr):
                return "claude -p exited with status \(status): \(stderr.prefix(500))"
            case .emptySummary:
                return "claude returned an empty summary"
            }
        }
    }

    /// Generate (or regenerate) the chronicle for a day and persist it.
    /// Returns the summary text.
    public static func chronicle(day: String, store: Store) throws -> String {
        let snapshots = try store.snapshotsForDay(day)
        guard !snapshots.isEmpty else {
            throw ChroniclerError.emptySummary
        }
        let digest = buildDigest(snapshots)
        let summary = try runClaude(prompt: prompt(day: day), stdin: digest)
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChroniclerError.emptySummary }
        try store.upsertChronicle(day: day, summary: trimmed, snapshotCount: snapshots.count)
        return trimmed
    }

    /// Local calendar date string for "today" / "yesterday".
    public static func dayString(daysAgo: Int = 0) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return formatter.string(from: date)
    }

    // MARK: - Digest

    /// Compact a day's snapshots into a bounded plain-text digest.
    /// Chronological, one block per snapshot, content clipped per block and
    /// capped overall so the prompt stays well inside the context window.
    private static func buildDigest(
        _ snapshots: [Store.Snapshot],
        perSnapshotLimit: Int = 700,
        totalLimit: Int = 120_000
    ) -> String {
        var blocks: [String] = []
        var used = 0
        for s in snapshots {
            let content = s.content
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(perSnapshotLimit)
            let location = s.url.isEmpty ? "" : " <\(s.url)>"
            let block = "[\(s.lastSeenAt)] \(s.app) — \(s.windowTitle)\(location)\n\(content)"
            if used + block.count > totalLimit {
                blocks.append("… (\(snapshots.count - blocks.count) later snapshots omitted for length)")
                break
            }
            blocks.append(block)
            used += block.count
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func prompt(day: String) -> String {
        """
        You are writing a private daily chronicle from a log of text captured \
        from the user's Mac screen on \(day). Each block is one window \
        snapshot: timestamp, app, window title, optional URL, then the \
        visible text.

        Write a concise markdown chronicle of the day with these sections:
        ## Summary — 2-3 sentences on what the day was about.
        ## Work & projects — what was worked on, per project/task, with \
        concrete detail (files, PRs, sites, documents). Merge repeated \
        sightings of the same thing.
        ## Timeline — short bullet timeline of major activity shifts (HH:MM).
        ## Notable — anything worth remembering later: decisions, errors \
        seen, things ordered/booked, articles read.

        Rules: be specific, no filler, no speculation beyond what the text \
        shows, ignore UI chrome (menus, sidebars, button labels). The reader \
        is the user themselves — write in second person ("you worked on…").
        """
    }

    // MARK: - claude CLI

    private static func claudePath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runClaude(prompt: String, stdin: String) throws -> String {
        guard let path = claudePath() else { throw ChroniclerError.claudeNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-p", prompt]
        // Run outside any project directory so no CLAUDE.md leaks in.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
        stdinPipe.fileHandleForWriting.closeFile()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ChroniclerError.claudeFailed(
                status: process.terminationStatus,
                stderr: String(data: errData, encoding: .utf8) ?? "")
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
