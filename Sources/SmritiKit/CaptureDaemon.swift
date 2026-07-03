import Foundation
import AppKit

/// Polls the frontmost window on a timer and persists deduplicated snapshots.
public final class CaptureDaemon {

    private let store: Store
    private let config: Config
    private var timer: Timer?
    private var paused = false

    /// Most recent app that produced a snapshot (for UI like "Exclude X").
    private(set) var lastCapturedApp: (name: String, bundleId: String)?

    /// Exclusions added at runtime (config is a value copy taken at launch).
    private var extraExclusions: Set<String> = []

    var isPaused: Bool { paused }

    func addExclusion(bundleId: String) {
        extraExclusions.insert(bundleId)
    }

    func setPaused(_ value: Bool) {
        paused = value
        print("smriti: capture \(paused ? "PAUSED" : "resumed")")
    }

    public init(store: Store, config: Config) {
        self.store = store
        self.config = config
    }

    public func start() {
        // SIGUSR1 toggles pause without stopping the process:
        //   kill -USR1 $(pgrep -f 'smriti capture')
        signal(SIGUSR1, SIG_IGN)
        let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        usr1.setEventHandler { [weak self] in
            guard let self else { return }
            self.paused.toggle()
            print("smriti: capture \(self.paused ? "PAUSED" : "resumed")")
        }
        usr1.resume()
        // Keep the source alive for the lifetime of the daemon.
        self.signalSource = usr1

        timer = Timer.scheduledTimer(
            withTimeInterval: config.captureIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            self?.tick()
        }
        timer?.tolerance = 1.0

        // Retention: prune once at startup, then daily.
        prune()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            self?.prune()
        }
        pruneTimer?.tolerance = 3600
    }

    private var signalSource: DispatchSourceSignal?
    private var pruneTimer: Timer?

    private func prune() {
        guard config.retentionDays > 0 else { return }
        do {
            let deleted = try store.prune(olderThanDays: config.retentionDays)
            if deleted > 0 {
                print("smriti: pruned \(deleted) snapshots older than \(config.retentionDays) days (chronicles kept)")
            }
        } catch {
            fputs("smriti: prune failed: \(error)\n", stderr)
        }
    }

    private func tick() {
        guard !paused else { return }
        guard let capture = AXReader.captureFrontmost() else { return }

        // Exclusion rules.
        if config.excludedBundleIds.contains(capture.bundleId)
            || extraExclusions.contains(capture.bundleId) { return }
        let titleLower = capture.windowTitle.lowercased()
        for blocked in config.excludedTitleSubstrings
        where titleLower.contains(blocked.lowercased()) {
            return
        }
        if !capture.url.isEmpty,
           let domain = BrowserURL.domain(of: capture.url) {
            for excluded in config.excludedDomains
            where BrowserURL.domain(domain, matches: excluded) {
                return
            }
        }

        lastCapturedApp = (capture.appName, capture.bundleId)
        let content = String(capture.content.prefix(config.maxContentLength))
        do {
            try store.upsert(
                app: capture.appName,
                bundleId: capture.bundleId,
                windowTitle: capture.windowTitle,
                content: content,
                url: capture.url
            )
        } catch {
            fputs("smriti: write failed: \(error)\n", stderr)
        }
    }
}
