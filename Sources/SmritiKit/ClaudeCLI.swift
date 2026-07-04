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

    /// Whether the CLI is authenticated. Runs a tiny prompt and checks for the
    /// "not logged in" banner. Costs one cheap request when logged in, so call
    /// on demand (e.g. a Settings button), not on every view load.
    public static func isLoggedIn() -> Bool {
        guard path() != nil else { return false }
        let out = ((try? run(prompt: "Reply with exactly: ok",
                             stdin: "", extraArgs: ["--model", "haiku"])) ?? "")
            .lowercased()
        if out.isEmpty { return false }
        return !out.contains("not logged in")
            && !out.contains("please run /login")
            && !out.contains("invalid api key")
    }

    /// Open Terminal running the CLI so the user can complete the interactive
    /// `/login` OAuth flow (which needs a TTY and a browser round-trip).
    @discardableResult
    public static func openLoginInTerminal() -> Bool {
        guard let cli = path() else { return false }
        let script = """
        tell application "Terminal"
            activate
            do script "clear; echo 'Smriti: complete Claude login below, then type  /login  if prompted.'; '\(cli)'"
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        return err == nil
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
