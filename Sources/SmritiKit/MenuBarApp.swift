import AppKit
import Foundation

/// Menu bar cockpit for Smriti (`smriti menubar`). Hosts the capture daemon
/// in-process — the status item is the daemon — so pause state is always
/// accurate and the Accessibility grant on the smriti binary covers both.
public final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let store: Store
    private var config: Config
    private let daemon: CaptureDaemon
    private let assist = AssistListener()

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    init(store: Store, config: Config) {
        self.store = store
        self.config = config
        self.daemon = CaptureDaemon(store: store, config: config)
        super.init()
    }

    /// Blocks forever running the app.
    public static func run(store: Store, config: Config) {
        let app = NSApplication.shared
        let delegate = MenuBarApp(store: store, config: config)
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        app.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "brain", accessibilityDescription: "Smriti")
            button.image?.isTemplate = true
        }
        menu.delegate = self
        statusItem.menu = menu

        daemon.start()

        assist.onGeneratingChange = { [weak self] generating in
            self?.statusItem.button?.image = NSImage(
                systemSymbolName: generating ? "ellipsis.bubble" : "brain",
                accessibilityDescription: "Smriti")
            self?.statusItem.button?.image?.isTemplate = true
        }
        assist.start()

        print("smriti: menubar started (capture interval \(config.captureIntervalSeconds)s, reply assist: double-tap right ⌥)")
    }

    // Rebuild the menu each time it opens so counts and state are fresh.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let state = NSMenuItem(
            title: daemon.isPaused ? "Smriti — paused" : "Smriti — capturing",
            action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)

        let today = Chronicler.dayString()
        if let count = try? store.countForDay(today) {
            let item = NSMenuItem(
                title: "Today: \(count) snapshots", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: daemon.isPaused ? "Resume capture" : "Pause capture",
            action: #selector(togglePause), keyEquivalent: "p")
        toggle.target = self
        menu.addItem(toggle)

        let assistToggle = NSMenuItem(
            title: "Reply assist (double-tap right ⌥)",
            action: #selector(toggleAssist), keyEquivalent: "")
        assistToggle.state = assist.isEnabled ? .on : .off
        assistToggle.target = self
        menu.addItem(assistToggle)

        if let last = daemon.lastCapturedApp,
           !config.excludedBundleIds.contains(last.bundleId) {
            let exclude = NSMenuItem(
                title: "Never capture \(last.name)",
                action: #selector(excludeLastApp), keyEquivalent: "")
            exclude.target = self
            menu.addItem(exclude)
        }

        menu.addItem(.separator())

        let chronicle = NSMenuItem(
            title: "Write today's chronicle",
            action: #selector(chronicleToday), keyEquivalent: "")
        chronicle.target = self
        menu.addItem(chronicle)

        if let latest = try? store.listChronicles(limit: 1).first {
            let open = NSMenuItem(
                title: "Open latest chronicle (\(latest.day))",
                action: #selector(openLatestChronicle), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Smriti", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func toggleAssist() {
        assist.setEnabled(!assist.isEnabled)
    }

    @objc private func togglePause() {
        daemon.setPaused(!daemon.isPaused)
        statusItem.button?.appearsDisabled = daemon.isPaused
    }

    @objc private func excludeLastApp() {
        guard let last = daemon.lastCapturedApp else { return }
        config.excludedBundleIds.insert(last.bundleId)
        try? config.save()
        // The in-process daemon holds its own Config copy; restarting the
        // process would also work, but patching the exclusion live is nicer.
        daemon.addExclusion(bundleId: last.bundleId)
        notify(title: "Smriti", body: "\(last.name) will never be captured.")
    }

    @objc private func chronicleToday() {
        let day = Chronicler.dayString()
        notify(title: "Smriti", body: "Writing chronicle for \(day)…")
        DispatchQueue.global(qos: .utility).async { [store] in
            do {
                _ = try Chronicler.chronicle(day: day, store: store)
                self.notify(title: "Smriti", body: "Chronicle for \(day) written.")
            } catch {
                self.notify(title: "Smriti", body: "Chronicle failed: \(error)")
            }
        }
    }

    @objc private func openLatestChronicle() {
        guard let latest = try? store.listChronicles(limit: 1).first else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smriti-chronicle-\(latest.day).md")
        try? latest.summary.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Lightweight notification via NSUserNotification's modern replacement
    /// isn't available to unbundled binaries, so fall back to stdout + beep.
    private func notify(title: String, body: String) {
        print("smriti: \(body)")
        DispatchQueue.main.async { NSSound.beep() }
    }
}
