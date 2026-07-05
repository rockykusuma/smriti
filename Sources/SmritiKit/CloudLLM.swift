import Foundation
import Security

// MARK: - Provider configuration

/// An OpenAI-compatible chat-completions endpoint. Groq and OpenRouter ship
/// as presets; any provider speaking the same wire format can be added with
/// `smriti cloud-add` — including a local Ollama's /v1 endpoint. A provider
/// is just three values: base URL, model, and (in the Keychain) an API key.
public struct CloudProviderConfig: Codable, Equatable {
    /// Root of the OpenAI-compatible API, e.g. "https://api.groq.com/openai/v1".
    public var baseURL: String
    /// Model id sent in requests, e.g. "openai/gpt-oss-120b".
    public var model: String

    public init(baseURL: String, model: String) {
        self.baseURL = baseURL
        self.model = model
    }

    /// Local endpoints (an Ollama /v1, LM Studio, llama.cpp server…) don't
    /// need an API key; everything else does.
    public var isLocal: Bool {
        baseURL.contains("://localhost") || baseURL.contains("://127.0.0.1")
    }
}

// MARK: - Keychain storage for API keys

/// API keys live in the login Keychain, never in config.json — config is a
/// plain-text file users share in bug reports. For people who prefer a file,
/// two fallbacks are read (in order, after the Keychain): a
/// `<PROVIDER>_API_KEY` environment variable, and the same line in
/// `~/Library/Application Support/Smriti/.env` — deliberately outside any
/// git repo so it can't be committed by accident.
public enum CloudKeyStore {
    static let service = "com.smriti.cli.cloud"

    public static var envFileURL: URL {
        Config.supportDirectory.appendingPathComponent(".env")
    }

    @discardableResult
    public static func set(_ key: String, provider: String) -> Bool {
        remove(provider: provider) // replace, don't duplicate
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
            kSecValueData as String: Data(key.utf8),
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public static func get(provider: String) -> String? {
        keychainGet(provider: provider)
            ?? environmentKey(provider: provider)
            ?? envFileKey(provider: provider)
    }

    /// Where the key for `provider` comes from: "keychain", "environment",
    /// ".env", or nil when there is none. For status displays.
    public static func source(provider: String) -> String? {
        if keychainGet(provider: provider) != nil { return "keychain" }
        if environmentKey(provider: provider) != nil { return "environment" }
        if envFileKey(provider: provider) != nil { return ".env" }
        return nil
    }

    private static func keychainGet(provider: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// "GROQ_API_KEY" for provider "groq" (non-alphanumerics become "_").
    static func envVarName(provider: String) -> String {
        provider.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
            .map(String.init).joined() + "_API_KEY"
    }

    private static func environmentKey(provider: String) -> String? {
        let value = ProcessInfo.processInfo.environment[envVarName(provider: provider)]
        return (value?.isEmpty ?? true) ? nil : value
    }

    private static func envFileKey(provider: String) -> String? {
        guard let text = try? String(contentsOf: envFileURL, encoding: .utf8)
        else { return nil }
        return parseEnv(text)[envVarName(provider: provider)]
    }

    /// Minimal dotenv parsing: KEY=VALUE lines, '#' comments, optional
    /// single/double quotes around the value, optional "export " prefix.
    static func parseEnv(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty, !value.isEmpty { result[key] = value }
        }
        return result
    }

    @discardableResult
    public static func remove(provider: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    public static func hasKey(provider: String) -> Bool {
        get(provider: provider) != nil
    }
}

// MARK: - Streaming client

/// Streams chat completions from any OpenAI-compatible endpoint (SSE).
/// Mirrors OllamaClient's shape: one instance serves one blocking request,
/// deltas are delivered as they arrive. Used as the reply assist's cloud
/// lane — Groq's TTFT is sub-second, so drafts feel instant.
public final class CloudLLMClient: NSObject, URLSessionDataDelegate {

    public struct Spec {
        public let name: String
        public let config: CloudProviderConfig
        public let apiKey: String?

        public init(name: String, config: CloudProviderConfig, apiKey: String?) {
            self.name = name
            self.config = config
            self.apiKey = apiKey
        }
    }

    private let spec: Spec
    private var buffer = Data()
    private var full = ""
    private var onDelta: ((String) -> Void)?
    private let done = DispatchSemaphore(value: 0)
    private var failed = false
    private var statusCode = 200
    private var errorBody = Data()

    public init(spec: Spec) {
        self.spec = spec
    }

    /// Model ids offered by the provider (GET /models), or [] on any failure.
    /// Sorted for stable UI listings.
    public static func listModels(config: CloudProviderConfig, apiKey: String?) -> [String] {
        guard let url = URL(string: config.baseURL + "/models") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var names: [String] = []
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data,
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let models = obj["data"] as? [[String: Any]] {
                names = models.compactMap { $0["id"] as? String }.sorted()
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 6)
        return names
    }

    /// Blocking streamed request; returns the full reply or nil on failure.
    public func request(_ prompt: String, timeout: TimeInterval = 30,
                        onDelta: ((String) -> Void)?) -> String? {
        self.onDelta = onDelta
        guard let url = URL(string: spec.config.baseURL + "/chat/completions") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = spec.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // OpenRouter attribution headers; other providers ignore them.
        request.setValue("https://github.com/rockykusuma/smriti", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Smriti", forHTTPHeaderField: "X-Title")
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "model": spec.config.model,
            "messages": [["role": "user", "content": prompt]],
            "stream": true,
        ]) else { return nil }
        request.httpBody = body

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session.dataTask(with: request).resume()
        let outcome = done.wait(timeout: .now() + timeout)
        session.invalidateAndCancel()
        guard outcome == .success, !failed, !full.isEmpty else { return nil }
        return full
    }

    // MARK: - SSE parsing

    /// One parsed server-sent-event line. Exposed for unit tests.
    struct SSEDelta: Equatable {
        var content: String?
        var done = false
        var error: String?
    }

    /// Parse a single SSE line ("data: {json}" / "data: [DONE]" / noise).
    /// Returns nil for lines that carry nothing (comments, blank, role-only
    /// first chunk).
    static func parse(line: Data) -> SSEDelta? {
        guard let text = String(data: line, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard text.hasPrefix("data:") else {
            // Mid-stream JSON error objects arrive without the SSE prefix on
            // some providers.
            if text.hasPrefix("{"), text.contains("\"error\"") {
                return SSEDelta(content: nil, done: false, error: text)
            }
            return nil
        }
        let payload = text.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" { return SSEDelta(content: nil, done: true) }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8)))
                as? [String: Any] else { return nil }
        if let error = obj["error"] {
            return SSEDelta(content: nil, done: false, error: "\(error)")
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty
        else { return nil }
        return SSEDelta(content: content)
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                           didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard statusCode == 200 else {
            errorBody.append(data) // collect the error JSON for the log
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer = Data(buffer.suffix(from: buffer.index(after: newline)))
            guard let event = CloudLLMClient.parse(line: line) else { continue }
            if let error = event.error {
                fputs("smriti cloud(\(spec.name)): stream error: \(error.prefix(300))\n", stderr)
                failed = true
                done.signal()
                return
            }
            if let content = event.content {
                full += content
                onDelta?(content)
            }
            if event.done {
                done.signal()
                return
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            fputs("smriti cloud(\(spec.name)): \(error.localizedDescription)\n", stderr)
            failed = true
        } else if statusCode != 200 {
            let body = String(data: errorBody, encoding: .utf8) ?? ""
            fputs("smriti cloud(\(spec.name)): HTTP \(statusCode) \(body.prefix(300))\n", stderr)
            failed = true
        }
        done.signal()
    }
}
