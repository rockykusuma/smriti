import Foundation

/// Keeps a pre-warmed `claude` process ready so reply drafting costs ~2s of
/// model time instead of ~10s of CLI startup.
///
/// Lifecycle: spawn (stream-json mode) → fire a dummy warmup turn (the first
/// turn carries lazy init cost) → sit ready. Each real request is served as
/// the next turn, then the process is discarded and a fresh one is warmed in
/// the background — every request gets a clean session.
public final class WarmClaude {

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    /// Serializes warmup and requests; a request blocks until warmup is done.
    private let lock = NSLock()

    public init() {
        respawn()
    }

    /// Send one request; returns the reply text, or nil on failure/timeout.
    /// Always leaves a fresh process warming for the next request.
    public func request(_ text: String, timeout: TimeInterval = 90) -> String? {
        lock.lock()
        defer {
            respawn()
            lock.unlock()
        }
        guard process?.isRunning == true else { return nil }
        return turn(text, timeout: timeout)
    }

    // MARK: - Process management

    private func respawn() {
        process?.terminate()
        process = nil

        guard let path = ClaudeCLI.path() else {
            fputs("smriti warm: claude CLI not found\n", stderr)
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--model", "haiku",
            "--strict-mcp-config",
            "--verbose",
        ]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.qualityOfService = .userInitiated // don't inherit background throttling
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe
        do {
            try p.run()
        } catch {
            fputs("smriti warm: spawn failed: \(error)\n", stderr)
            return
        }
        process = p
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading

        // Warmup turn in the background; requests queue behind the lock.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            let started = Date()
            if self.turn("Reply with exactly: ok", timeout: 120) != nil {
                let secs = String(format: "%.1f", Date().timeIntervalSince(started))
                fputs("smriti warm: ready (warmup \(secs)s)\n", stderr)
            } else {
                fputs("smriti warm: warmup failed\n", stderr)
            }
        }
    }

    // MARK: - Protocol

    /// Write one user message, block until the matching `result` event.
    private func turn(_ text: String, timeout: TimeInterval) -> String? {
        guard let stdinHandle, let stdoutHandle else { return nil }
        let message: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]],
            ],
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        data.append(0x0A)
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            return nil
        }

        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk = stdoutHandle.availableData // blocks until data or EOF
            if chunk.isEmpty { return nil } // process exited
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer = Data(buffer.suffix(from: buffer.index(after: newline)))
                guard
                    let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                    event["type"] as? String == "result"
                else { continue }
                if let result = event["result"] as? String {
                    return result
                }
                return nil // result event without text = error result
            }
        }
        return nil // timeout
    }
}
