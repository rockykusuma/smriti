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

    /// Whether the CLI is authenticated. Uses `claude auth status`, which
    /// prints JSON and costs nothing (no model request, no MCP servers), so
    /// it's cheap enough to call on view load.
    public static func isLoggedIn() -> Bool {
        guard let path = path() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["auth", "status"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let logged = obj["loggedIn"] as? Bool {
            return logged
        }
        return false
    }

    /// Open Terminal running `claude auth login` — a focused OAuth flow that
    /// exits when done (unlike the full interactive session, it spawns no MCP
    /// servers, so closing the window afterwards won't prompt to kill anything).
    @discardableResult
    public static func openLoginInTerminal() -> Bool {
        guard let cli = path() else { return false }
        let command = "clear; '\(cli)' auth login --claudeai; "
            + "echo; echo 'Login finished — you can close this window.'; exit"
        let script = """
        tell application "Terminal"
            activate
            do script "\(command)"
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
