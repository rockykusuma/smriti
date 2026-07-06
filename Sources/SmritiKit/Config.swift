import Foundation

/// User configuration, stored as JSON at
/// ~/Library/Application Support/Smriti/config.json
public struct Config: Codable {
    /// App bundle ids that must never be captured.
    public var excludedBundleIds: Set<String>
    /// Substrings of window titles that must never be captured
    /// (keyword blocking; catches private windows before a URL is known).
    public var excludedTitleSubstrings: [String]
    /// Domains that must never be captured in browsers. Matches the domain
    /// itself and all subdomains (example.com also blocks docs.example.com).
    /// Older configs lack this key; it decodes to [] then.
    public var excludedDomains: [String] = []
    /// How often the daemon samples the focused window.
    public var captureIntervalSeconds: Double
    /// Max characters of text stored per snapshot.
    public var maxContentLength: Int
    /// Days to keep raw snapshots before the daemon prunes them
    /// (chronicles are kept forever). 0 disables pruning.
    public var retentionDays: Int = 90
    /// Reply-assist model backend: "auto" (cloud when a key is set, else
    /// Ollama when running, else Claude), "cloud", "ollama", or "claude".
    /// Chronicles/tone/summaries always use Claude for quality.
    public var assistBackend: String = "auto"
    /// Local model for the assist when Ollama is used.
    public var ollamaModel: String = "llama3.2:latest"
    /// Active cloud provider — a key into `cloudProviders`.
    public var cloudProvider: String = "groq"
    /// OpenAI-compatible endpoints. Presets: groq, openrouter. Add more
    /// with `smriti cloud-add <name> <baseURL> <model>`. API keys live in
    /// the Keychain (`smriti key set <provider> <key>`), never here.
    public var cloudProviders: [String: CloudProviderConfig] = Config.defaultCloudProviders

    static let defaultCloudProviders: [String: CloudProviderConfig] = [
        "groq": CloudProviderConfig(
            baseURL: "https://api.groq.com/openai/v1", model: "openai/gpt-oss-120b"),
        "openrouter": CloudProviderConfig(
            baseURL: "https://openrouter.ai/api/v1", model: "openrouter/auto"),
    ]
    /// App appearance: "system" (follow macOS), "light", or "dark".
    public var appearanceMode: String = "system"
    /// App bundle ids whose text must never be sent to the cloud assist lane;
    /// reply drafts triggered in these apps stay on local models. This is
    /// distinct from `excludedBundleIds`, which blocks capture entirely.
    public var cloudExcludedBundleIds: Set<String> = []
    /// Scrub secrets/PII from the reply-assist prompt before it leaves the
    /// machine. Applies to every non-local lane — a cloud provider and Claude;
    /// a localhost Ollama (or a cloud provider pointed at localhost) is exempt.
    public var redactRemoteEgress: Bool = true
    /// Watch for calls and offer to record them. Off means only manual voice
    /// notes record — useful if dictation tools keep tripping the detector.
    public var autoRecordMeetings: Bool = true
    /// Whether the first-launch onboarding wizard has been completed.
    public var hasCompletedOnboarding: Bool = false

    public var databasePath: String {
        Config.supportDirectory.appendingPathComponent("smriti.sqlite").path
    }

    static let defaults = Config(
        excludedBundleIds: [
            // Sensible privacy defaults — extend with `smriti exclude <bundleId>`.
            "com.apple.Passwords",
            "com.apple.keychainaccess",
            "com.1password.1password",
            "com.agilebits.onepassword7",
        ],
        excludedTitleSubstrings: [
            "Private Browsing",
            "Incognito",
        ],
        captureIntervalSeconds: 5,
        maxContentLength: 20_000
    )

    static var supportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Smriti", isDirectory: true)
    }

    private static var configURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    public static func load() throws -> Config {
        try FileManager.default.createDirectory(
            at: supportDirectory, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: configURL) else {
            let config = Config.defaults
            try config.save()
            return config
        }
        let decoder = JSONDecoder()
        do {
            var config = try decoder.decode(Config.self, from: data)
            config.ensurePresetProviders()
            return config
        } catch {
            // Older config without newer keys: decode leniently via partial.
            let partial = try decoder.decode(PartialConfig.self, from: data)
            var config = Config.defaults
            partial.excludedBundleIds.map { config.excludedBundleIds = $0 }
            partial.excludedTitleSubstrings.map { config.excludedTitleSubstrings = $0 }
            partial.excludedDomains.map { config.excludedDomains = $0 }
            partial.captureIntervalSeconds.map { config.captureIntervalSeconds = $0 }
            partial.maxContentLength.map { config.maxContentLength = $0 }
            partial.retentionDays.map { config.retentionDays = $0 }
            partial.assistBackend.map { config.assistBackend = $0 }
            partial.ollamaModel.map { config.ollamaModel = $0 }
            partial.appearanceMode.map { config.appearanceMode = $0 }
            partial.cloudProvider.map { config.cloudProvider = $0 }
            partial.cloudProviders.map { config.cloudProviders = $0 }
            partial.cloudExcludedBundleIds.map { config.cloudExcludedBundleIds = $0 }
            partial.redactRemoteEgress.map { config.redactRemoteEgress = $0 }
            partial.autoRecordMeetings.map { config.autoRecordMeetings = $0 }
            partial.hasCompletedOnboarding.map { config.hasCompletedOnboarding = $0 }
            config.ensurePresetProviders()
            try config.save() // rewrite with full key set
            return config
        }
    }

    /// Presets (groq, openrouter) reappear after upgrades from older configs;
    /// user edits to an existing entry always win.
    public mutating func ensurePresetProviders() {
        for (name, preset) in Config.defaultCloudProviders
        where cloudProviders[name] == nil {
            cloudProviders[name] = preset
        }
    }

    /// Every field optional — used to upgrade configs from older versions.
    private struct PartialConfig: Codable {
        var excludedBundleIds: Set<String>?
        var excludedTitleSubstrings: [String]?
        var excludedDomains: [String]?
        var captureIntervalSeconds: Double?
        var maxContentLength: Int?
        var retentionDays: Int?
        var assistBackend: String?
        var ollamaModel: String?
        var appearanceMode: String?
        var cloudProvider: String?
        var cloudProviders: [String: CloudProviderConfig]?
        var cloudExcludedBundleIds: Set<String>?
        var redactRemoteEgress: Bool?
        var autoRecordMeetings: Bool?
        var hasCompletedOnboarding: Bool?
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Config.configURL, options: .atomic)
    }
}
