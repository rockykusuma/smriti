import Foundation

/// Shared runner for the Claude Code CLI (`claude -p`). Used by the
/// chronicler (daily summaries) and the reply assistant. Smriti contains no
/// LLM — everything runs on the user's own Claude subscription.
public enum ClaudeCLI {

    public enum CLIError: Error, CustomStringConvertible {
        case notFound
        case failed(status: Int32, stderr: String)

        public var description: String {
            switch self {
            case .notFound:
                return "claude CLI not found. Install Claude Code (https://claude.com/claude-code) or add it to PATH."
            case .failed(let status, let stderr):
                return "claude -p exited with status \(status): \(stderr.prefix(500))"
            }
        }
    }

    static func path() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run `claude -p <prompt>` with `stdin` as piped context.
    /// `extraArgs` are inserted before -p (e.g. ["--model", "haiku"]).
    public static func run(
        prompt: String, stdin: String, extraArgs: [String] = []
    ) throws -> String {
        guard let path = path() else { throw CLIError.notFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = extraArgs + ["-p", prompt]
        // Run outside any project directory so no CLAUDE.md leaks in.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.qualityOfService = .userInitiated

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
            throw CLIError.failed(
                status: process.terminationStatus,
                stderr: String(data: errData, encoding: .utf8) ?? "")
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
