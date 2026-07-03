import Foundation

/// Minimal stdio MCP server (JSON-RPC 2.0, newline-delimited).
///
/// Exposes Smriti's snapshot store to Claude Desktop/Cowork:
///   - search_memory(query, limit)         FTS5 search across snapshots
///   - get_recent_activity(minutes, limit) what was on screen recently
///   - get_snapshot(id)                    full content of one snapshot
///
/// No LLM here — Claude does the thinking. stdout carries only JSON-RPC;
/// diagnostics go to stderr.
public final class MCPServer {

    private let store: Store
    private let protocolVersion = "2024-11-05"

    public init(store: Store) {
        self.store = store
    }

    /// Blocking read-eval loop over stdin. Returns on EOF.
    public func run() {
        FileHandle.standardError.write(Data("smriti mcp: ready (stdio)\n".utf8))
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            guard
                let data = line.data(using: .utf8),
                let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                send(errorId: NSNull(), code: -32700, message: "parse error")
                continue
            }
            handle(msg)
        }
    }

    // MARK: - Dispatch

    private func handle(_ msg: [String: Any]) {
        let method = msg["method"] as? String ?? ""
        let id = msg["id"]

        // Notifications (no id) get no response.
        guard let id else { return }

        switch method {
        case "initialize":
            send(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "smriti", "version": "0.1.0"],
            ])

        case "ping":
            send(id: id, result: [:])

        case "tools/list":
            send(id: id, result: ["tools": MCPServer.toolDefinitions])

        case "tools/call":
            let params = msg["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try callTool(name: name, args: args)
                send(id: id, result: [
                    "content": [["type": "text", "text": text]],
                    "isError": false,
                ])
            } catch let error as ToolError {
                send(id: id, result: [
                    "content": [["type": "text", "text": error.message]],
                    "isError": true,
                ])
            } catch {
                send(id: id, result: [
                    "content": [["type": "text", "text": "smriti error: \(error)"]],
                    "isError": true,
                ])
            }

        default:
            send(errorId: id, code: -32601, message: "method not found: \(method)")
        }
    }

    // MARK: - Tools

    private struct ToolError: Error { let message: String }

    func callTool(name: String, args: [String: Any]) throws -> String {
        switch name {
        case "search_memory":
            guard let query = args["query"] as? String, !query.isEmpty else {
                throw ToolError(message: "search_memory requires a non-empty 'query' string")
            }
            let limit = clamp(args["limit"], default: 10, max: 50)
            let rows = try store.search(query, limit: limit)
            return render(rows, emptyMessage: "No snapshots match \"\(query)\".")

        case "get_recent_activity":
            let minutes = clamp(args["minutes"], default: 30, max: 60 * 24 * 7)
            let limit = clamp(args["limit"], default: 20, max: 50)
            let rows = try store.recent(minutes: minutes)
            return render(Array(rows.prefix(limit)),
                          emptyMessage: "No snapshots in the last \(minutes) minutes.")

        case "get_snapshot":
            guard let idValue = args["id"], let id = Int64("\(idValue)") else {
                throw ToolError(message: "get_snapshot requires an integer 'id'")
            }
            guard let row = try store.getSnapshot(id: id) else {
                throw ToolError(message: "No snapshot with id \(id).")
            }
            let urlLine = row.url.isEmpty ? "" : "url: \(row.url)\n"
            return """
                id: \(row.id)
                app: \(row.app) (\(row.bundleId))
                window: \(row.windowTitle)
                \(urlLine)first seen: \(row.capturedAt)
                last seen:  \(row.lastSeenAt)

                \(row.content)
                """

        case "get_chronicle":
            guard let day = args["day"] as? String, !day.isEmpty else {
                throw ToolError(message: "get_chronicle requires 'day' (YYYY-MM-DD)")
            }
            guard let c = try store.getChronicle(day: day) else {
                throw ToolError(message: "No chronicle for \(day). Ask the user to run: smriti chronicle \(day)")
            }
            return "Chronicle for \(c.day) (\(c.snapshotCount) snapshots, written \(c.createdAt)):\n\n\(c.summary)"

        case "list_chronicles":
            let all = try store.listChronicles()
            guard !all.isEmpty else { return "No chronicles stored yet." }
            return all.map {
                "\($0.day) — \($0.snapshotCount) snapshots, written \($0.createdAt)"
            }.joined(separator: "\n")

        default:
            throw ToolError(message: "unknown tool: \(name)")
        }
    }

    /// Compact listing: id + metadata + content preview. Claude can follow up
    /// with get_snapshot(id) for full text, keeping responses token-frugal.
    private func render(_ rows: [Store.Snapshot], emptyMessage: String) -> String {
        guard !rows.isEmpty else { return emptyMessage }
        return rows.map { row in
            let preview = row.content
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(300)
            let location = row.url.isEmpty ? "" : " <\(row.url)>"
            return "#\(row.id) [\(row.lastSeenAt)] \(row.app) — \(row.windowTitle)\(location)\n\(preview)"
        }.joined(separator: "\n\n")
    }

    private func clamp(_ value: Any?, default def: Int, max: Int) -> Int {
        let n = (value as? Int) ?? (value as? Double).map(Int.init) ?? def
        return Swift.max(1, Swift.min(n, max))
    }

    private static let toolDefinitions: [[String: Any]] = [
        [
            "name": "search_memory",
            "description": "Full-text search across everything Smriti has seen on screen (window text captured locally). Returns matching snapshots with id, timestamp, app, window title, and a content preview. Use get_snapshot(id) for full text.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Search terms (FTS5 match, terms are ANDed)"],
                    "limit": ["type": "integer", "description": "Max results (default 10, max 50)"],
                ],
                "required": ["query"],
            ],
        ],
        [
            "name": "get_recent_activity",
            "description": "What was on the user's screen recently. Returns snapshots from the last N minutes, newest first, with id, timestamp, app, window title, and a content preview.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "minutes": ["type": "integer", "description": "Look-back window in minutes (default 30)"],
                    "limit": ["type": "integer", "description": "Max results (default 20, max 50)"],
                ],
            ],
        ],
        [
            "name": "get_snapshot",
            "description": "Fetch the full captured text of a single snapshot by id (ids come from search_memory / get_recent_activity results).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "integer", "description": "Snapshot id"],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "get_chronicle",
            "description": "Fetch the stored daily chronicle (Claude-written summary of that day's screen activity) for a given local date. Use list_chronicles to see which days exist.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "day": ["type": "string", "description": "Local date, YYYY-MM-DD"],
                ],
                "required": ["day"],
            ],
        ],
        [
            "name": "list_chronicles",
            "description": "List which days have stored chronicles (daily summaries), newest first.",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
    ]

    // MARK: - JSON-RPC plumbing

    private func send(id: Any, result: [String: Any]) {
        emit(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(errorId: Any, code: Int, message: String) {
        emit(["jsonrpc": "2.0", "id": errorId, "error": ["code": code, "message": message]])
    }

    private func emit(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A) // newline-delimited framing
        FileHandle.standardOutput.write(data)
    }
}
