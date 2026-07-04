import Foundation

/// Recover a meeting whose live transcription failed: re-transcribe the audio
/// that's still saved on disk, refresh the summary, and update the stored
/// snapshot in place. Exposed for the `smriti transcribe` command.
public enum MeetingTranscription {

    public struct Result {
        public let id: Int64
        public let title: String
        public let transcript: String
    }

    public enum Failure: Swift.Error, CustomStringConvertible {
        case noMeetings
        case notFound(Int64)
        case noAudio(Int64)

        public var description: String {
            switch self {
            case .noMeetings: return "no meetings recorded yet"
            case .notFound(let id): return "no meeting with id \(id)"
            case .noAudio(let id): return "meeting \(id) has no saved audio directory"
            }
        }
    }

    /// Re-transcribe a stored meeting's saved tracks. Pass a snapshot id, or
    /// nil for the most recent meeting.
    public static func retranscribe(store: Store, id: Int64?) throws -> Result {
        let meetings = try store.listMeetings(limit: 100)
        guard !meetings.isEmpty else { throw Failure.noMeetings }

        let row: Store.Snapshot
        if let id {
            guard let match = meetings.first(where: { $0.id == id }) else {
                throw Failure.notFound(id)
            }
            row = match
        } else {
            row = meetings[0]
        }

        guard let dir = URL(string: row.url), dir.isFileURL,
              FileManager.default.fileExists(atPath: dir.path) else {
            throw Failure.noAudio(row.id)
        }

        var transcript = Transcriber.transcript(inDirectory: dir)

        // Regenerate the decisions/action-items summary when we got real text.
        if !transcript.hasPrefix("(Transcription unavailable"),
           let summary = try? ClaudeCLI.run(
               prompt: """
               Summarize this meeting transcript in markdown: 2-3 sentence \
               overview, then '### Decisions' and '### Action items' bullet \
               lists (write 'none' if none). Be specific, no filler.
               """,
               stdin: String(transcript.prefix(60_000)),
               extraArgs: ["--model", "haiku", "--strict-mcp-config"]),
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transcript = "## Summary\n\n\(summary.trimmingCharacters(in: .whitespacesAndNewlines))\n\n---\n\n\(transcript)"
        }

        try store.updateContent(id: row.id, content: transcript)
        return Result(id: row.id, title: row.windowTitle, transcript: transcript)
    }
}
