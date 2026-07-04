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
      smriti retention <days>    Keep raw snapshots N days (0 = forever); chronicles always kept
      smriti prune               Prune old snapshots now (normally automatic)
      smriti menubar             Menu bar app: capture + pause/resume/exclude from the bar
      smriti install-agent [m]   Start capture at login (LaunchAgent, removable);
                                 'smriti install-agent menubar' for the menu bar app
      smriti uninstall-agent     Remove the LaunchAgent completely
      smriti agent-status        Show LaunchAgent state
    """)
}

guard let command = args.first else {
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
        guard AXReader.ensureAccessibilityPermission() else {
            fputs("smriti: Accessibility permission not granted. Enable it in System Settings > Privacy & Security > Accessibility, then re-run.\n", stderr)
            exit(1)
        }
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
