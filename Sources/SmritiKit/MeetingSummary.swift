import Foundation

/// Builds the decisions/action-items summary that's prepended to a meeting
/// transcript. Shared by live finalize and `smriti transcribe`.
enum MeetingSummary {

    /// Prepend a summary to a transcript. Skips summarization for empty or
    /// very short transcripts — with only a few words the model replies
    /// conversationally ("I don't see a transcript…") instead of summarizing.
    static func compose(transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        guard !transcript.hasPrefix("(Transcription unavailable"), words >= 25 else {
            return transcript
        }
        guard let raw = try? ClaudeCLI.run(
            prompt: """
            Below is a raw, possibly noisy meeting transcript. Summarize ONLY \
            what it actually contains. Do not ask for input, and never say the \
            transcript is missing or empty. Output markdown: a 2-3 sentence \
            overview, then '### Decisions' and '### Action items' bullet lists \
            (write 'none' under a heading if there are none). Be specific, no filler.
            """,
            stdin: String(trimmed.prefix(60_000)),
            extraArgs: ["--model", "haiku", "--strict-mcp-config"])
        else { return transcript }

        let summary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return transcript }
        return "## Summary\n\n\(summary)\n\n---\n\n\(transcript)"
    }
}
