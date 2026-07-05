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
    private var meetings: MeetingWatcher!
    private let voiceRecorder = VoiceNoteRecorder()
    private lazy var mainWindow: MainWindow = {
        let w = MainWindow(store: store, config: config)
        w.isPaused = { [weak self] in self?.daemon.isPaused ?? false }
        w.setPaused = { [weak self] paused in
            self?.daemon.setPaused(paused)
            self?.statusItem.button?.appearsDisabled = paused
        }
        w.writeChronicleNow = { [weak self] in self?.chronicleToday() }
        w.learnToneNow = { [weak self] in self?.learnTone() }
        w.onConfigChange = { [weak self] updated in self?.applySettings(updated) }
        w.isRecordingVoiceNote = { [weak self] in self?.voiceRecorder.isRecording ?? false }
        w.startVoiceNote = { [weak self] in self?.startVoiceNote() }
        w.stopVoiceNote = { [weak self] in self?.stopVoiceNote() }
        return w
    }()

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
        Theme.applyAppearance(config.appearanceMode)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "brain", accessibilityDescription: "Smriti")
            button.image?.isTemplate = true
        }
        menu.delegate = self
        statusItem.menu = menu

        daemon.start()

        // Second connection: WAL allows concurrent readers; never share one
        // sqlite handle across threads.
        assist.memoryStore = try? Store(dbPath: config.databasePath)
        assist.contextSource = { [weak self] in
            guard let last = self?.daemon.lastWindowCapture,
                  Date().timeIntervalSince(last.at) < 10,
                  last.capture.bundleId
                      == NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            else { return nil }
            return last.capture
        }
        assist.onGeneratingChange = { [weak self] generating in
            self?.statusItem.button?.image = NSImage(
                systemSymbolName: generating ? "ellipsis.bubble" : "brain",
                accessibilityDescription: "Smriti")
            self?.statusItem.button?.image?.isTemplate = true
            if !generating { self?.hideDraftHUD() }
        }
        // Show the caret-anchored "drafting…" pill once the target field is known.
        assist.draftAnchor = { [weak self] caret in self?.showDraftHUD(anchor: caret) }
        configureAssistBackends(config)
        assist.start()

        meetings = MeetingWatcher(store: store)
        meetings.contextHint = { [weak self] in self?.daemon.lastWindowCapture?.capture }
        meetings.voiceNoteActive = { [weak self] in self?.voiceRecorder.isRecording ?? false }
        meetings.start()
        // Speech Recognition authorization is a TCC request that aborts unsigned
        // dev builds (same class of crash as the mic check), and it's only
        // needed for meeting transcription — so gate it on the same switch.
        if MeetingWatcher.meetingFeaturesEnabled {
            Transcriber.requestAuthorization()
        }

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

        if meetings.isRecording {
            let stop = NSMenuItem(
                title: "● Recording meeting — Stop",
                action: #selector(stopMeeting), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        }

        menu.addItem(.separator())

        let openMain = NSMenuItem(
            title: "Open Smriti", action: #selector(openMainWindow), keyEquivalent: "o")
        openMain.target = self
        menu.addItem(openMain)

        // Fire-and-forget: runs in the background with a notification, so it's
        // worth keeping in the tray even though Home has the same button.
        let chronicle = NSMenuItem(
            title: "Write today's chronicle",
            action: #selector(chronicleToday), keyEquivalent: "")
        chronicle.target = self
        menu.addItem(chronicle)

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

    @objc private func openMainWindow() {
        mainWindow.show(section: 0)
    }

    private func applySettings(_ updated: Config) {
        config = updated
        configureAssistBackends(updated)
    }

    /// Points the assist at its lanes per the configured backend.
    /// Fallback chain inside the assist: cloud → ollama → warm Claude.
    private func configureAssistBackends(_ config: Config) {
        assist.cloudSpec = nil
        assist.ollamaModel = nil
        assist.cloudExcludedBundleIds = config.cloudExcludedBundleIds
        assist.redactRemoteEgress = config.redactRemoteEgress

        // The cloud lane is "ready" when the active provider exists and
        // either has a Keychain key or is a local endpoint.
        let cloudSpec: CloudLLMClient.Spec? = {
            guard let provider = config.cloudProviders[config.cloudProvider]
            else { return nil }
            let key = CloudKeyStore.get(provider: config.cloudProvider)
            guard key != nil || provider.isLocal else { return nil }
            return CloudLLMClient.Spec(
                name: config.cloudProvider, config: provider, apiKey: key)
        }()

        switch config.assistBackend {
        case "claude":
            break
        case "ollama":
            assist.ollamaModel = config.ollamaModel
            OllamaClient.warmUp(model: config.ollamaModel)
        case "cloud":
            if let cloudSpec {
                assist.cloudSpec = cloudSpec
            } else {
                fputs("smriti assist: no API key for \(config.cloudProvider) — run: smriti key set \(config.cloudProvider) <key>. Using Claude.\n", stderr)
            }
        default: // auto: cloud when a key is set, plus ollama when running
            assist.cloudSpec = cloudSpec
            if OllamaClient.isReachable() {
                assist.ollamaModel = config.ollamaModel
                OllamaClient.warmUp(model: config.ollamaModel)
            }
        }
        let lanes = [
            assist.cloudSpec.map { "\($0.name)/\($0.config.model)" },
            assist.ollamaModel.map { "ollama/\($0)" },
            "claude",
        ].compactMap { $0 }.joined(separator: " → ")
        fputs("smriti assist: backend=\(config.assistBackend) lanes: \(lanes)\n", stderr)
    }

    @objc private func stopMeeting() {
        meetings.stopRecording()
    }

    // MARK: - Manual voice notes (mic-only, from the Meetings pane)

    private func startVoiceNote() {
        do {
            try voiceRecorder.start()
            NSSound(named: "Pop")?.play()
        } catch {
            fputs("smriti voice-note: could not start: \(error)\n", stderr)
            NSSound.beep()
        }
    }

    private func stopVoiceNote() {
        guard let result = voiceRecorder.stop() else { return }
        NSSound(named: "Glass")?.play()
        let dir = result.directory
        let startedAt = result.startedAt
        // Transcribe on-device and store as a meeting entry, off the main thread.
        DispatchQueue.global(qos: .utility).async { [store, weak self] in
            // Request Speech authorization on demand (user-initiated, app
            // active) rather than at startup. If it's unavailable, we still
            // store the audio with an "unavailable" note — recording is never
            // lost.
            if !Transcriber.ensureAuthorized() {
                fputs("smriti voice-note: speech recognition not authorized — storing audio without a transcript\n", stderr)
            }
            let transcript = Transcriber.transcript(inDirectory: dir)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let secs = Int(Date().timeIntervalSince(startedAt))
            let dur = secs < 60 ? "\(secs)s" : "\(secs / 60) min"
            let title = "Voice note \(formatter.string(from: startedAt)) (\(dur))"
            do {
                try store.upsert(
                    app: "Meeting",
                    bundleId: "sh.smriti.meeting",
                    windowTitle: title,
                    content: transcript,
                    url: dir.absoluteString)
                fputs("smriti voice-note: stored — \(title)\n", stderr)
            } catch {
                fputs("smriti voice-note: store failed: \(error)\n", stderr)
            }
            DispatchQueue.main.async { self?.mainWindow.reloadMeetings() }
        }
    }

    @objc private func learnTone() {
        notify(title: "Smriti", body: "Learning your writing tone…")
        DispatchQueue.global(qos: .utility).async { [store] in
            do {
                _ = try ToneProfile.learn(store: store)
                self.notify(title: "Smriti", body: "Tone profile saved — replies will sound like you.")
            } catch {
                self.notify(title: "Smriti", body: "Tone learning failed: \(error)")
            }
        }
    }

    @objc private func chronicleToday() {
        let day = Chronicler.dayString()
        notify(title: "Smriti", body: "Writing chronicle for \(day)…")
        DispatchQueue.global(qos: .utility).async { [store] in
            do {
                _ = try Chronicler.chronicle(day: day, store: store)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.notify(title: "Smriti", body: "Chronicle for \(day) written.")
                    // Reveal it: chronicles are day-DESC, so today's is row 0
                    // and the Chronicles section auto-selects it on open.
                    self.mainWindow.show(
                        section: self.mainWindow.sectionIndex(titled: "Chronicles"))
                }
            } catch {
                self.notify(title: "Smriti", body: "Chronicle failed: \(error)")
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Drafting indicator (a small pill at the text caret)

    private let draftLabel = NSTextField(labelWithString: "")
    private var draftDotsTimer: Timer?
    private var draftDotPhase = 0

    /// A compact "Smriti drafting…" pill shown right where text will appear,
    /// so the feedback is at the cursor rather than off in a corner.
    private lazy var draftHUD: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 196, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true

        draftLabel.font = .systemFont(ofSize: 12, weight: .medium)
        draftLabel.textColor = .labelColor
        draftLabel.frame = NSRect(x: 10, y: 6, width: 176, height: 18)
        effect.addSubview(draftLabel)
        panel.contentView = effect
        return panel
    }()

    private func showDraftHUD(anchor: CGRect?) {
        positionDraftHUD(anchor: anchor)
        draftDotPhase = 0
        updateDraftLabel()
        draftHUD.orderFrontRegardless()
        draftDotsTimer?.invalidate()
        draftDotsTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            self.draftDotPhase = (self.draftDotPhase + 1) % 4
            self.updateDraftLabel()
        }
    }

    private func hideDraftHUD() {
        draftDotsTimer?.invalidate()
        draftDotsTimer = nil
        draftHUD.orderOut(nil)
    }

    private func updateDraftLabel() {
        // Pad to a fixed 3-dot width so the trailing hint doesn't jitter.
        let dots = String(repeating: ".", count: draftDotPhase)
            + String(repeating: " ", count: 3 - draftDotPhase)
        draftLabel.stringValue = "🧠  Smriti drafting\(dots)  ⎋ esc"
    }

    /// Place the pill just below the caret. AX gives a top-left-origin rect;
    /// flip it into Cocoa's bottom-left space, fall back to the mouse, and
    /// clamp onto the screen it lands on.
    private func positionDraftHUD(anchor: CGRect?) {
        let size = draftHUD.frame.size
        var origin: NSPoint
        if let ax = anchor {
            // AX rect is top-left origin; place the pill just above the anchor's
            // top edge, left-aligned to it, in Cocoa's bottom-left space.
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let topEdgeCocoaY = primaryH - ax.origin.y
            origin = NSPoint(x: ax.origin.x, y: topEdgeCocoaY + 4)
        } else {
            let m = NSEvent.mouseLocation
            origin = NSPoint(x: m.x + 12, y: m.y + 10)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
            origin.y = min(max(origin.y, vf.minY + 4), vf.maxY - size.height - 4)
        }
        draftHUD.setFrameOrigin(origin)
    }

    // MARK: - Toast (visible feedback for background actions)

    private let toastLabel = NSTextField(labelWithString: "")
    private var toastDismiss: DispatchWorkItem?

    private lazy var toastPanel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true

        toastLabel.font = .systemFont(ofSize: 13, weight: .medium)
        toastLabel.textColor = .labelColor
        toastLabel.lineBreakMode = .byTruncatingTail
        effect.addSubview(toastLabel)
        panel.contentView = effect
        return panel
    }()

    /// Show a short-lived toast just below the menu bar. Safe from any thread.
    private func toast(_ message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.toast(message) }
            return
        }
        toastLabel.stringValue = message
        toastLabel.sizeToFit()
        let width = min(max(toastLabel.frame.width + 28, 140), 520)
        let height: CGFloat = 34
        toastPanel.setContentSize(NSSize(width: width, height: height))
        toastLabel.frame = NSRect(x: 14, y: 8, width: width - 28, height: 18)
        if let vf = NSScreen.main?.visibleFrame {
            toastPanel.setFrameOrigin(NSPoint(x: vf.midX - width / 2, y: vf.maxY - height - 8))
        }
        toastPanel.orderFrontRegardless()

        toastDismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toastPanel.orderOut(nil) }
        toastDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    /// Background actions report progress here. Shows a toast (real
    /// notifications aren't available to this unbundled binary) and logs.
    private func notify(title: String, body: String) {
        print("smriti: \(body)")
        toast(body)
    }
}
