import Foundation
import AppKit
import SmritiKit

// launchd redirects stdout to a log file; line-buffer it so log lines appear
// immediately instead of on exit.
setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Smriti CLI entry point
//
// Commands:
//   smriti capture            Run the capture daemon (foreground)
//   smriti recent [minutes]   Show snapshots from the last N minutes (default 30)
//   smriti search <terms...>  Full-text search across captured snapshots
//   smriti stats              Database statistics
//   smriti exclude <bundleId> Add an app bundle id to the exclusion list
//   smriti exclusions         List current exclusions

let args = CommandLine.arguments.dropFirst()

func printUsage() {
    print("""
    smriti — a local memory for your Mac (स्मृति)

    USAGE:
      smriti capture             Run capture daemon in foreground
      smriti recent [minutes]    Recent snapshots (default: 30 min)
      smriti search <terms...>   Full-text search
      smriti stats               DB statistics
      smriti exclude <bundleId>  Exclude an app (e.g. com.apple.Passwords)
      smriti exclude-domain <d>  Exclude a web domain incl. subdomains (e.g. mybank.com)
      smriti exclusions          List exclusions
      smriti mcp                 Run stdio MCP server (for Claude Desktop/Cowork)
      smriti chronicle [day]     Summarize a day via `claude -p` (default: today; or YYYY-MM-DD / yesterday)
      smriti chronicles          List stored chronicles
      smriti learn-tone          Distill your writing style from captured chats (via claude)
      smriti tone                Show the stored tone profile
      smriti meetings            List recorded meeting transcripts
      smriti transcribe [id]     Re-transcribe a saved meeting's audio (default: latest)
      smriti mic-check [secs]    Record a few seconds and report the mic level (default: 3)
      smriti key set <provider> <key>    Store a cloud API key in the Keychain (e.g. smriti key set groq gsk_…)
      smriti key remove <provider>       Delete a stored key
      smriti key status                  Which providers have keys (keys never printed)
      smriti cloud                       Show cloud providers and the active one
      smriti cloud <provider> [model]    Switch active provider (and optionally its model)
      smriti cloud-add <name> <url> <m>  Add/update an OpenAI-compatible provider (base URL + model)
      smriti cloud-remove <name>         Remove a custom provider (presets reset instead)
      smriti cloud-models [provider]     List model ids offered by a provider's API
      smriti cloud-test [provider]       Send a test prompt; report first-token and total latency
      smriti retention <days>    Keep raw snapshots N days (0 = forever); chronicles always kept
      smriti prune               Prune old snapshots now (normally automatic)
      smriti menubar             Menu bar app: capture + pause/resume/exclude from the bar
      smriti install-agent [m]   Start capture at login (LaunchAgent, removable);
                                 'smriti install-agent menubar' for the menu bar app
      smriti uninstall-agent     Remove the LaunchAgent completely
      smriti agent-status        Show LaunchAgent state
    """)
}

// Resolve the command. When launched with no args as a bundled app
// (double-clicking Smriti.app), default to the menu bar experience.
let command: String
if let first = args.first {
    command = first
} else if Bundle.main.bundlePath.hasSuffix(".app") {
    command = "menubar"
} else {
    printUsage()
    exit(0)
}

do {
    let config = try Config.load()
    let store = try Store(dbPath: config.databasePath)

    switch command {
    case "capture":
        guard AXReader.ensureAccessibilityPermission() else {
            fputs("smriti: Accessibility permission not granted. Enable it in System Settings > Privacy & Security > Accessibility, then re-run.\n", stderr)
            exit(1)
        }
        let daemon = CaptureDaemon(store: store, config: config)
        print("smriti: capture started (interval \(config.captureIntervalSeconds)s, db: \(config.databasePath))")
        print("smriti: excluded apps: \(config.excludedBundleIds.sorted().joined(separator: ", "))")
        daemon.start()
        RunLoop.main.run() // Blocks forever; Ctrl-C to stop.

    case "recent":
        let minutes = args.dropFirst().first.flatMap { Int($0) } ?? 30
        let rows = try store.recent(minutes: minutes)
        if rows.isEmpty { print("No snapshots in the last \(minutes) minutes.") }
        for row in rows { print(row.oneLineSummary) }

    case "search":
        let terms = args.dropFirst().joined(separator: " ")
        guard !terms.isEmpty else { printUsage(); exit(1) }
        let rows = try store.search(terms, limit: 20)
        if rows.isEmpty { print("No matches for \"\(terms)\".") }
        for row in rows { print(row.oneLineSummary) }

    case "stats":
        let s = try store.stats()
        print("snapshots: \(s.snapshotCount)")
        print("apps:      \(s.distinctApps)")
        print("oldest:    \(s.oldest ?? "-")")
        print("newest:    \(s.newest ?? "-")")
        print("db path:   \(config.databasePath)")

    case "exclude":
        guard let bundleId = args.dropFirst().first else { printUsage(); exit(1) }
        var updated = config
        updated.excludedBundleIds.insert(bundleId)
        try updated.save()
        print("Excluded: \(bundleId)")

    case "exclude-domain":
        guard let domain = args.dropFirst().first?.lowercased() else { printUsage(); exit(1) }
        var updated = config
        if !updated.excludedDomains.contains(domain) {
            updated.excludedDomains.append(domain)
        }
        try updated.save()
        print("Excluded domain: \(domain) (and subdomains)")

    case "exclusions":
        print("apps:")
        for id in config.excludedBundleIds.sorted() { print("  \(id)") }
        print("domains:")
        for d in config.excludedDomains.sorted() { print("  \(d)") }
        print("title substrings:")
        for t in config.excludedTitleSubstrings { print("  \(t)") }

    case "chronicle":
        let arg = args.dropFirst().first
        let day: String
        switch arg {
        case nil, "today": day = Chronicler.dayString()
        case "yesterday": day = Chronicler.dayString(daysAgo: 1)
        case let d?: day = d
        }
        print("smriti: chronicling \(day) via claude -p …")
        let summary = try Chronicler.chronicle(day: day, store: store)
        print(summary)

    case "chronicles":
        let all = try store.listChronicles()
        if all.isEmpty { print("No chronicles yet. Run: smriti chronicle") }
        for c in all {
            let preview = c.summary.replacingOccurrences(of: "\n", with: " ").prefix(100)
            print("\(c.day) (\(c.snapshotCount) snapshots, written \(c.createdAt)) :: \(preview)")
        }

    case "key":
        let sub = Array(args.dropFirst())
        switch sub.first {
        case "set":
            guard sub.count == 3 else {
                fputs("usage: smriti key set <provider> <key>\n", stderr); exit(1)
            }
            let provider = sub[1].lowercased()
            guard config.cloudProviders[provider] != nil else {
                fputs("smriti: unknown provider '\(provider)'. Known: \(config.cloudProviders.keys.sorted().joined(separator: ", ")). Add one with: smriti cloud-add\n", stderr)
                exit(1)
            }
            guard CloudKeyStore.set(sub[2], provider: provider) else {
                fputs("smriti: could not write to the Keychain\n", stderr); exit(1)
            }
            print("Key for \(provider) stored in the login Keychain (never in config.json).")
            if config.assistBackend == "auto" || config.assistBackend == "cloud" {
                let model = config.cloudProviders[provider]?.model ?? "?"
                print("Reply drafts will use \(provider)/\(model)\(config.cloudProvider == provider ? "" : " after: smriti cloud \(provider)").")
            }
        case "remove":
            guard sub.count == 2 else {
                fputs("usage: smriti key remove <provider>\n", stderr); exit(1)
            }
            let provider = sub[1].lowercased()
            print(CloudKeyStore.remove(provider: provider)
                ? "Keychain key removed." : "No Keychain key stored for \(provider).")
            if let source = CloudKeyStore.source(provider: provider) {
                print("Note: a key is still being picked up from \(source)"
                    + (source == ".env" ? " — edit \(CloudKeyStore.envFileURL.path)" : "") + ".")
            }
        case "status", nil:
            for name in config.cloudProviders.keys.sorted() {
                let mark = CloudKeyStore.source(provider: name)
                    .map { "✓ key (\($0))" } ?? "— no key"
                print("\(name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(mark)")
            }
            print("file fallback: \(CloudKeyStore.envFileURL.path) (GROQ_API_KEY=… lines)")
        default:
            fputs("usage: smriti key set|remove|status\n", stderr); exit(1)
        }

    case "cloud":
        let sub = Array(args.dropFirst())
        if sub.isEmpty {
            print("active provider: \(config.cloudProvider) (backend: \(config.assistBackend))")
            for (name, p) in config.cloudProviders.sorted(by: { $0.key < $1.key }) {
                let active = name == config.cloudProvider ? "→" : " "
                let key = CloudKeyStore.hasKey(provider: name) ? "key ✓" : (p.isLocal ? "local" : "no key")
                print("\(active) \(name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(p.model.padding(toLength: 32, withPad: " ", startingAt: 0)) \(key)  \(p.baseURL)")
            }
            print("switch: smriti cloud <provider> [model] · keys: smriti key set <provider> <key>")
        } else {
            let provider = sub[0].lowercased()
            guard config.cloudProviders[provider] != nil else {
                fputs("smriti: unknown provider '\(provider)'. Known: \(config.cloudProviders.keys.sorted().joined(separator: ", "))\n", stderr)
                exit(1)
            }
            var updated = config
            updated.cloudProvider = provider
            if sub.count > 1 { updated.cloudProviders[provider]?.model = sub[1] }
            try updated.save()
            let model = updated.cloudProviders[provider]?.model ?? "?"
            print("Active cloud provider: \(provider) (model: \(model))")
            if !CloudKeyStore.hasKey(provider: provider),
               updated.cloudProviders[provider]?.isLocal == false {
                print("No API key stored yet — add one with: smriti key set \(provider) <key>")
            }
        }

    case "cloud-add":
        let sub = Array(args.dropFirst())
        guard sub.count == 3, let url = URL(string: sub[1]), url.scheme != nil else {
            fputs("usage: smriti cloud-add <name> <baseURL> <model>\ne.g.   smriti cloud-add together https://api.together.xyz/v1 meta-llama/Llama-3.3-70B-Instruct-Turbo\n", stderr)
            exit(1)
        }
        let name = sub[0].lowercased()
        var updated = config
        updated.cloudProviders[name] = CloudProviderConfig(baseURL: sub[1], model: sub[2])
        try updated.save()
        print("Provider \(name) saved. Activate with: smriti cloud \(name)"
            + (CloudKeyStore.hasKey(provider: name) ? "" : " · add a key: smriti key set \(name) <key>"))

    case "cloud-remove":
        guard let name = args.dropFirst().first?.lowercased() else {
            fputs("usage: smriti cloud-remove <name>\n", stderr); exit(1)
        }
        var updated = config
        guard updated.cloudProviders.removeValue(forKey: name) != nil else {
            fputs("smriti: no provider named '\(name)'\n", stderr); exit(1)
        }
        updated.ensurePresetProviders() // presets can't be removed, only edited
        if updated.cloudProvider == name, updated.cloudProviders[name] == nil {
            updated.cloudProvider = "groq"
        }
        try updated.save()
        CloudKeyStore.remove(provider: name)
        print(updated.cloudProviders[name] != nil
            ? "\(name) is a built-in preset — reset to defaults instead of removed."
            : "Provider \(name) removed (and its Keychain key, if any).")

    case "cloud-models":
        let provider = (args.dropFirst().first ?? config.cloudProvider).lowercased()
        guard let p = config.cloudProviders[provider] else {
            fputs("smriti: unknown provider '\(provider)'\n", stderr); exit(1)
        }
        let models = CloudLLMClient.listModels(
            config: p, apiKey: CloudKeyStore.get(provider: provider))
        if models.isEmpty {
            print("No models returned — is the API key set and the endpoint reachable? (smriti key set \(provider) <key>)")
        } else {
            for id in models { print(id + (id == p.model ? "   ← current" : "")) }
        }

    case "cloud-test":
        let provider = (args.dropFirst().first ?? config.cloudProvider).lowercased()
        guard let p = config.cloudProviders[provider] else {
            fputs("smriti: unknown provider '\(provider)'\n", stderr); exit(1)
        }
        let key = CloudKeyStore.get(provider: provider)
        guard key != nil || p.isLocal else {
            fputs("smriti: no API key for \(provider). Run: smriti key set \(provider) <key>\n", stderr)
            exit(1)
        }
        print("Testing \(provider)/\(p.model) …")
        let spec = CloudLLMClient.Spec(name: provider, config: p, apiKey: key)
        let started = Date()
        var firstToken: TimeInterval?
        let reply = CloudLLMClient(spec: spec).request(
            "Reply with one short sentence confirming you can hear me.",
            timeout: 30) { _ in
            if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
        }
        if let reply {
            let total = Date().timeIntervalSince(started)
            print("reply: \(reply.trimmingCharacters(in: .whitespacesAndNewlines))")
            print(String(format: "first token: %.2fs · total: %.2fs", firstToken ?? total, total))
        } else {
            print("FAILED — see the error above. Check the key, model id, and network.")
            exit(1)
        }

    case "retention":
        guard let arg = args.dropFirst().first, let days = Int(arg), days >= 0 else {
            printUsage(); exit(1)
        }
        var updated = config
        updated.retentionDays = days
        try updated.save()
        print(days == 0
            ? "Retention disabled — raw snapshots kept forever."
            : "Raw snapshots kept \(days) days; older ones pruned by the capture daemon. Chronicles always kept.")

    case "prune":
        guard config.retentionDays > 0 else {
            print("Retention is disabled (retentionDays = 0). Set it with: smriti retention 90")
            exit(0)
        }
        let deleted = try store.prune(olderThanDays: config.retentionDays)
        print("Pruned \(deleted) snapshots older than \(config.retentionDays) days. Chronicles kept.")

    case "menubar":
        // Prompt for Accessibility if needed, but stay alive either way — the
        // menu bar item persists and capture begins once permission is granted,
        // rather than the app vanishing on first launch.
        _ = AXReader.ensureAccessibilityPermission()
        MenuBarApp.run(store: store, config: config) // blocks forever

    case "install-agent":
        let binaryPath = "/usr/local/bin/smriti"
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            fputs("smriti: install the binary first: sudo install -m 755 .build/release/smriti \(binaryPath)\n", stderr)
            exit(1)
        }
        let mode = args.dropFirst().first == "menubar" ? "menubar" : "capture"
        try LaunchAgent.install(binaryPath: binaryPath, mode: mode)
        print("""
        LaunchAgent installed and started (\(LaunchAgent.label)).
        Capture now runs at login. If macOS prompts for Accessibility
        permission for 'smriti', grant it, then run: smriti agent-status
        Remove anytime with: smriti uninstall-agent
        """)

    case "uninstall-agent":
        try LaunchAgent.uninstall()
        print("LaunchAgent removed. Capture no longer starts at login.")

    case "agent-status":
        print(LaunchAgent.status())

    case "learn-tone":
        print("smriti: learning your writing tone via claude -p …")
        let profile = try ToneProfile.learn(store: store)
        print(profile)
        print("\nSaved to \(ToneProfile.path.path) — edit it anytime.")

    case "tone":
        if let profile = ToneProfile.load() {
            print(profile)
        } else {
            print("No tone profile yet. Run: smriti learn-tone")
        }

    case "meetings":
        let rows = try store.listMeetings()
        if rows.isEmpty { print("No recorded meetings yet. The menu bar app asks before recording any call.") }
        for row in rows {
            print("#\(row.id) \(row.windowTitle)")
        }

    case "transcribe":
        // Recover a meeting whose live transcription failed by re-processing
        // its saved audio. Default to the most recent meeting.
        let idArg = args.dropFirst().first.flatMap { Int64($0) }
        Transcriber.requestAuthorization()
        Thread.sleep(forTimeInterval: 0.5) // let authorization settle
        do {
            let result = try MeetingTranscription.retranscribe(store: store, id: idArg)
            print(result.transcript)
            fputs("\nsmriti: updated meeting #\(result.id) — \(result.title)\n", stderr)
        } catch {
            fputs("smriti transcribe: \(error)\n", stderr)
            exit(1)
        }

    case "mic-check":
        let secs = args.dropFirst().first.flatMap { Double($0) } ?? 3
        let ok = MicCheck().run(seconds: max(1, min(secs, 30)))
        exit(ok ? 0 : 1)

    case "mcp":
        // stdout is the JSON-RPC channel — no prints here, only stderr.
        MCPServer(store: store).run()

    default:
        printUsage()
        exit(1)
    }
} catch {
    fputs("smriti: error: \(error)\n", stderr)
    exit(1)
}
