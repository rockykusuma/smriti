import Foundation

/// Streams chat completions from a local Ollama server. Used as the reply
/// assist's fast path — fully on-device, sub-second first token once the
/// model is resident. One instance serves one request.
final class OllamaClient: NSObject, URLSessionDataDelegate {

    private let model: String
    private let base = URL(string: "http://localhost:11434")!

    private var buffer = Data()
    private var full = ""
    private var onDelta: ((String) -> Void)?
    private let done = DispatchSemaphore(value: 0)
    private var failed = false

    init(model: String) {
        self.model = model
    }

    /// Is Ollama up? Cheap check with a tight timeout.
    static func isReachable() -> Bool {
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        request.timeoutInterval = 1.0
        var ok = false
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1.5)
        return ok
    }

    /// Names of locally installed models, or [] when Ollama is down.
    static func listModels() -> [String] {
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        request.timeoutInterval = 1.5
        var names: [String] = []
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data,
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let models = obj["models"] as? [[String: Any]] {
                names = models.compactMap { $0["name"] as? String }
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 2)
        return names
    }

    /// Ask Ollama to load the model into memory and keep it there, so the
    /// first real request doesn't pay the multi-second load cost.
    static func warmUp(model: String) {
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/chat")!)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": "ok"]],
            "stream": false,
            "keep_alive": "2h",
        ])
        let started = Date()
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 {
                fputs("smriti ollama: \(model) resident (\(String(format: "%.1f", Date().timeIntervalSince(started)))s)\n", stderr)
            }
        }.resume()
    }

    /// Blocking streamed request; returns the full reply or nil on failure.
    func request(_ prompt: String, timeout: TimeInterval = 30,
                 onDelta: ((String) -> Void)?) -> String? {
        self.onDelta = onDelta
        var request = URLRequest(url: base.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": true,
            "keep_alive": "2h",
        ]) else { return nil }
        request.httpBody = body

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session.dataTask(with: request).resume()
        let outcome = done.wait(timeout: .now() + timeout)
        session.invalidateAndCancel()
        guard outcome == .success, !failed, !full.isEmpty else { return nil }
        return full
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer = Data(buffer.suffix(from: buffer.index(after: newline)))
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            else { continue }
            if let content = (event["message"] as? [String: Any])?["content"] as? String,
               !content.isEmpty {
                full += content
                onDelta?(content)
            }
            if event["done"] as? Bool == true {
                done.signal()
                return
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            fputs("smriti ollama: \(error.localizedDescription)\n", stderr)
            failed = true
        }
        done.signal()
    }
}
