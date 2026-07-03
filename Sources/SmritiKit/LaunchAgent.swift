import Foundation

/// Installs/removes a user LaunchAgent so `smriti capture` starts at login.
///
/// Deliberately transparent (the anti-Goldfish): only ever created by an
/// explicit `smriti install-agent`, plist lives in the user's own
/// ~/Library/LaunchAgents, logs to ~/Library/Logs/smriti.log, and
/// `smriti uninstall-agent` removes every trace.
public enum LaunchAgent {

    public static let label = "com.smriti.capture"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var logPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/smriti.log").path
    }

    public static func install(binaryPath: String, mode: String = "capture") throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryPath, mode],
            "RunAtLoad": true,
            // No KeepAlive: if capture exits (e.g. Accessibility permission
            // missing), don't respawn-loop — the user fixes it and re-runs
            // `smriti install-agent` or logs in again.
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "ProcessType": "Background",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)

        // Reload if already present, then bootstrap into the user domain.
        _ = launchctl("bootout", "gui/\(getuid())/\(label)") // ignore failure
        let result = launchctl("bootstrap", "gui/\(getuid())", plistURL.path)
        guard result.status == 0 else {
            throw AgentError.launchctl("bootstrap failed: \(result.output)")
        }
    }

    public static func uninstall() throws {
        _ = launchctl("bootout", "gui/\(getuid())/\(label)") // ok if not loaded
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    public static func status() -> String {
        let installed = FileManager.default.fileExists(atPath: plistURL.path)
        let result = launchctl("print", "gui/\(getuid())/\(label)")
        let running = result.status == 0
        var lines = [
            "plist:   \(installed ? plistURL.path : "not installed")",
            "loaded:  \(running ? "yes" : "no")",
        ]
        if running,
           let pidLine = result.output
               .split(separator: "\n")
               .first(where: { $0.contains("pid = ") }) {
            lines.append("pid:    \(pidLine.trimmingCharacters(in: .whitespaces))")
        }
        lines.append("log:     \(logPath)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    enum AgentError: Error, CustomStringConvertible {
        case launchctl(String)
        var description: String {
            if case .launchctl(let msg) = self { return "launchctl: \(msg)" }
            return "agent error"
        }
    }

    private static func launchctl(_ args: String...) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (127, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
