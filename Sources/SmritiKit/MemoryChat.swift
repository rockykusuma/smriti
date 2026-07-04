import Foundation

/// A persistent, agentic "Ask Smriti" session: a long-lived `claude` process
/// (Sonnet) pointed at Smriti's own MCP server, so Claude answers questions
/// about the user's captured memory by calling search_memory / get_chronicle /
/// etc. itself. Multi-turn — the process stays alive so follow-ups keep context.
///
/// Everything runs on the user's Claude subscription; Smriti contains no LLM.
public final class MemoryChat {

    /// A tool the agent invoked while answering (surfaced as activity + sources).
    public struct ToolCall: Equatable {
        public let name: String     // e.g. "search_memory"
        public let summary: String  // e.g. "strix" or "2026-07-04"
    }

    /// One meaningful thing decoded from the claude stream-json output.
    enum Event: Equatable {
        case delta(String)        // streamed answer text
        case tools([ToolCall])    // the agent called memory tools
        case result(String?)      // turn finished (final text, or nil on error)
        case ignore               // everything else
    }

    /// Pure decode of one stream-json event dict — kept separate from the I/O
    /// loop so it can be unit-tested.
    static func parse(_ event: [String: Any]) -> Event {
        switch event["type"] as? String {
        case "stream_event":
            if let inner = event["event"] as? [String: Any],
               inner["type"] as? String == "content_block_delta",
               let delta = inner["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let fragment = delta["text"] as? String {
                return .delta(fragment)
            }
            return .ignore
        case "assistant":
            if let msg = event["message"] as? [String: Any],
               let content = msg["content"] as? [[String: Any]] {
                let calls = content
                    .filter { $0["type"] as? String == "tool_use" }
                    .map { describe($0) }
                if !calls.isEmpty { return .tools(calls) }
            }
            return .ignore
        case "result":
            return .result(event["result"] as? String)
        default:
            return .ignore
        }
    }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private let lock = NSLock()
    private let mcpConfigPath: String

    private static let smritiTools = [
        "mcp__smriti__search_memory",
        "mcp__smriti__get_recent_activity",
        "mcp__smriti__get_snapshot",
        "mcp__smriti__get_chronicle",
        "mcp__smriti__list_chronicles",
    ]
    // Built-ins the agent should never wander into — keeps it fast and on-task.
    private static let blockedTools = [
        "ToolSearch", "Task", "Bash", "BashOutput", "KillShell",
        "WebSearch", "WebFetch", "Read", "Write", "Edit", "Glob", "Grep",
        "TodoWrite", "NotebookEdit",
    ]

    public init() {
        mcpConfigPath = NSTemporaryDirectory() + "smriti-ask-mcp.json"
        writeMCPConfig()
    }

    /// Ask a question. Blocking — call from a background queue. `onDelta` streams
    /// answer text; `onTool` fires as the agent calls memory tools. Returns the
    /// full answer text, or nil on failure.
    @discardableResult
    public func ask(
        _ question: String,
        timeout: TimeInterval = 120,
        onDelta: @escaping (String) -> Void,
        onTool: @escaping (ToolCall) -> Void
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if process?.isRunning != true { spawn() }
        guard process?.isRunning == true else { return nil }
        return turn(question, timeout: timeout, onDelta: onDelta, onTool: onTool)
    }

    /// Spawn the process ahead of the first question so it answers faster.
    public func prewarm() {
        lock.lock()
        defer { lock.unlock() }
        if process?.isRunning != true { spawn() }
    }

    /// Start a fresh conversation (clears context).
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        process?.terminate()
        process = nil
    }

    // MARK: - Config

    private func writeMCPConfig() {
        let binary = Bundle.main.executablePath ?? "/usr/local/bin/smriti"
        let config: [String: Any] = [
            "mcpServers": ["smriti": ["command": binary, "args": ["mcp"]]],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: config) {
            try? data.write(to: URL(fileURLWithPath: mcpConfigPath))
        }
    }

    private func systemPrompt() -> String {
        """
        You are Smriti, a private assistant that answers the user's questions \
        about their own Mac activity, using ONLY what Smriti has captured. \
        Your tools: search_memory (full-text over captured on-screen text), \
        get_recent_activity (recent snapshots), get_snapshot (full text by id), \
        list_chronicles and get_chronicle (Claude-written daily summaries).

        Always call a tool before answering. For broad or time-based questions \
        (a day, this week, "what did I work on"), prefer chronicles; for \
        specific lookups (a repo, a person, an error), use search_memory and \
        open the most relevant results with get_snapshot. Ground every claim in \
        what the tools return — if you find nothing relevant, say so plainly \
        rather than guessing. Be concise and specific; cite dates, apps, and \
        snapshot ids. Use markdown. Today is \(Chronicler.dayString()).
        """
    }

    // MARK: - Process

    private func spawn() {
        process?.terminate()
        guard let path = ClaudeCLI.path() else {
            fputs("smriti ask: claude CLI not found\n", stderr)
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", "sonnet",
            "--mcp-config", mcpConfigPath,
            "--strict-mcp-config",
            "--allowedTools", MemoryChat.smritiTools.joined(separator: ","),
            "--disallowedTools", MemoryChat.blockedTools.joined(separator: ","),
            "--permission-mode", "bypassPermissions",
            "--append-system-prompt", systemPrompt(),
        ]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.qualityOfService = .userInitiated
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe
        do {
            try p.run()
        } catch {
            fputs("smriti ask: spawn failed: \(error)\n", stderr)
            return
        }
        process = p
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
    }

    private func turn(
        _ text: String, timeout: TimeInterval,
        onDelta: (String) -> Void, onTool: (ToolCall) -> Void
    ) -> String? {
        guard let stdinHandle, let stdoutHandle else { return nil }
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]],
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        data.append(0x0A)
        do { try stdinHandle.write(contentsOf: data) } catch { return nil }

        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk = stdoutHandle.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: nl)
                buffer = Data(buffer.suffix(from: buffer.index(after: nl)))
                guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                else { continue }
                switch MemoryChat.parse(event) {
                case .delta(let fragment): onDelta(fragment)
                case .tools(let calls): calls.forEach(onTool)
                case .result(let text): return text
                case .ignore: break
                }
            }
        }
        return nil
    }

    private static func describe(_ block: [String: Any]) -> ToolCall {
        let rawName = (block["name"] as? String) ?? "tool"
        let name = rawName.replacingOccurrences(of: "mcp__smriti__", with: "")
        let input = block["input"] as? [String: Any] ?? [:]
        let summary: String
        switch name {
        case "search_memory": summary = (input["query"] as? String) ?? ""
        case "get_chronicle": summary = (input["day"] as? String) ?? ""
        case "get_snapshot": summary = input["id"].map { "#\($0)" } ?? ""
        case "get_recent_activity": summary = (input["minutes"]).map { "\($0) min" } ?? ""
        default: summary = ""
        }
        return ToolCall(name: name, summary: summary)
    }
}
