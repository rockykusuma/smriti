import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Watches for meetings (any app opening the microphone — Teams, Meet,
/// FaceTime, WhatsApp, Zoom, Slack…), asks the user for permission to
/// record with a 10-second consent window, and — only on an explicit yes —
/// records and transcribes into Smriti's memory. No answer means NO.
public final class MeetingWatcher {

    private let store: Store
    /// Hint for naming: the capture daemon's view of the frontmost window.
    var contextHint: (() -> AXReader.WindowCapture?)?

    private let recorder = MeetingRecorder()
    private var pollTimer: Timer?

    private enum State {
        case idle
        case micActive(since: Date)
        case prompting
        case recording
        case declined // until mic goes idle again
    }
    private var state: State = .idle
    private var micIdleSince: Date?

    /// Apps whose mic use we treat as a meeting/call.
    static let callerApps: [String: String] = [
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "us.zoom.xos": "Zoom",
        "com.apple.FaceTime": "FaceTime",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "Cisco-Systems.Spark": "Webex",
    ]

    public init(store: Store) {
        self.store = store
    }

    /// Whether the meeting features (mic-activity watching *and* speech
    /// recognition) should run. Both go through TCC checks — Microphone and
    /// Speech Recognition — that *abort the whole process* on a build that
    /// can't satisfy them, as with an ad-hoc-signed `swift run` binary under
    /// `.build/`. So they're off for dev builds and when `SMRITI_NO_MEETINGS=1`;
    /// force them on with `SMRITI_MEETINGS=1`. The installed/signed binary
    /// (in /usr/local/bin or an .app bundle) runs them normally.
    public static var meetingFeaturesEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["SMRITI_NO_MEETINGS"] == "1" { return false }
        if env["SMRITI_MEETINGS"] == "1" { return true }
        return !isUnsignedDevBuild
    }

    /// An ad-hoc-signed build running out of the SwiftPM/Xcode build dir — it
    /// can't hold Microphone/Speech TCC grants, so the mic poll and Speech auth
    /// abort there.
    public static var isUnsignedDevBuild: Bool {
        let path = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        return path.contains("/.build/") || path.contains("/DerivedData/")
    }

    /// Manual voice notes only need the microphone (AVAudioEngine) plus Speech
    /// requested on demand — they don't use the crash-prone CoreAudio
    /// call-detection poll. So they stay available even when the meeting watcher
    /// is disabled (e.g. SMRITI_NO_MEETINGS), just not on unsigned dev builds.
    public static var voiceNotesEnabled: Bool { !isUnsignedDevBuild }

    public func start() {
        guard MeetingWatcher.meetingFeaturesEnabled else {
            let path = Bundle.main.executablePath ?? ""
            fputs("smriti meetings: disabled (dev build or SMRITI_NO_MEETINGS at \(path)) — avoids Microphone/Speech TCC aborts on unsigned builds.\n", stderr)
            return
        }

        // The mic-activity poll reads a CoreAudio property that is TCC-gated on
        // modern macOS. Gate on the mic authorization status first — reading the
        // status never prompts or crashes — and only start polling once
        // authorized, requesting access via the sanctioned prompt when
        // undetermined.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginPolling()
        case .notDetermined:
            // Ask once via the sanctioned API — this shows the system prompt on
            // a properly signed/installed build (which carries the embedded
            // usage string), and simply returns a denial on a build that can't,
            // instead of crashing.
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.beginPolling()
                    } else {
                        fputs("smriti meetings: mic access not granted — watcher idle\n", stderr)
                    }
                }
            }
        default:
            fputs("smriti meetings: mic access denied — watcher idle (enable Microphone in System Settings to record meetings)\n", stderr)
        }
    }

    private func beginPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        fputs("smriti meetings: watching for calls (mic activity)\n", stderr)
    }

    public var isRecording: Bool { recorder.isRecording }

    /// Manual stop from the menu.
    public func stopRecording() {
        guard case .recording = state else { return }
        finalize()
    }

    // MARK: - State machine

    private func poll() {
        let active = MeetingWatcher.microphoneInUse()

        switch state {
        case .idle:
            guard active else { return }
            state = .micActive(since: Date())

        case .micActive(let since):
            guard active else { state = .idle; return }
            // Debounce: 3s of continuous mic use = a real call, not a blip.
            if Date().timeIntervalSince(since) >= 3 {
                state = .prompting
                askConsent(appName: currentCallerName())
            }

        case .prompting:
            if !active { consentPanel?.orderOut(nil); consentPanel = nil; state = .idle }

        case .recording:
            if active {
                micIdleSince = nil
            } else {
                // The call ended when the mic stays idle for 8s.
                if let idle = micIdleSince {
                    if Date().timeIntervalSince(idle) >= 8 { finalize() }
                } else {
                    micIdleSince = Date()
                }
            }

        case .declined:
            // Re-arm only after the call (mic) actually ends.
            if !active { state = .idle }
        }
    }

    private func currentCallerName() -> String {
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier,
               let name = MeetingWatcher.callerApps[id] {
                return name
            }
        }
        // Browser meeting (Google Meet etc.) — use the captured URL/title.
        if let hint = contextHint?(), !hint.url.isEmpty,
           let domain = BrowserURL.domain(of: hint.url) {
            if domain.contains("meet.google") { return "Google Meet" }
            return domain
        }
        return "Call"
    }

    // MARK: - Consent (10 seconds, silence = no)

    private var consentPanel: NSPanel?
    private var countdownTimer: Timer?

    private func askConsent(appName: String) {
        NSSound(named: "Submarine")?.play()
        fputs("smriti meetings: \(appName) call detected — asking consent (10s)\n", stderr)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 320, height: 96))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12

        let title = NSTextField(labelWithString: "🎙  \(appName) call — record & transcribe?")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 16, y: 62, width: 290, height: 20)
        effect.addSubview(title)

        let countdown = NSTextField(labelWithString: "No response in 10s = don't record. Stays on this Mac.")
        countdown.font = .systemFont(ofSize: 11)
        countdown.textColor = .secondaryLabelColor
        countdown.frame = NSRect(x: 16, y: 42, width: 290, height: 16)
        effect.addSubview(countdown)

        let record = NSButton(title: "Record (10)", target: self, action: #selector(consentYes))
        record.bezelStyle = .rounded
        record.keyEquivalent = "\r"
        record.frame = NSRect(x: 16, y: 8, width: 130, height: 28)
        effect.addSubview(record)

        let no = NSButton(title: "Don't record", target: self, action: #selector(consentNo))
        no.bezelStyle = .rounded
        no.frame = NSRect(x: 156, y: 8, width: 130, height: 28)
        effect.addSubview(no)

        panel.contentView = effect
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 336, y: f.maxY - 112))
        }
        panel.orderFrontRegardless()
        consentPanel = panel

        var remaining = 10
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            remaining -= 1
            record.title = "Record (\(remaining))"
            if remaining <= 0 {
                timer.invalidate()
                self?.consentNo() // silence = no recording
            }
        }
    }

    @objc private func consentYes() {
        dismissConsent()
        state = .recording
        micIdleSince = nil
        do {
            try recorder.start(appName: currentCallerName())
        } catch {
            fputs("smriti meetings: recorder failed: \(error)\n", stderr)
            state = .declined
        }
    }

    @objc private func consentNo() {
        dismissConsent()
        fputs("smriti meetings: not recording (no consent)\n", stderr)
        state = .declined
    }

    private func dismissConsent() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        consentPanel?.orderOut(nil)
        consentPanel = nil
    }

    // MARK: - Finalize → transcript → memory

    private func finalize() {
        guard let recording = recorder.stop() else { state = .idle; return }
        state = .idle
        micIdleSince = nil

        DispatchQueue.global(qos: .utility).async { [store] in
            fputs("smriti meetings: transcribing on-device…\n", stderr)
            // Auto-summary (decisions/action items) prepended, via claude.
            let transcript = MeetingSummary.compose(
                transcript: Transcriber.meetingTranscript(recording: recording))

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let secs = Int(Date().timeIntervalSince(recording.startedAt))
            let dur = secs < 60 ? "\(secs)s" : "\(secs / 60) min"
            let title = "\(recording.appName) \(formatter.string(from: recording.startedAt)) (\(dur))"
            do {
                try store.upsert(
                    app: "Meeting",
                    bundleId: "sh.smriti.meeting",
                    windowTitle: title,
                    content: transcript,
                    url: recording.directory.absoluteString)
                fputs("smriti meetings: transcript stored — \(title)\n", stderr)
                NSSound(named: "Glass")?.play()
            } catch {
                fputs("smriti meetings: store failed: \(error)\n", stderr)
            }
        }
    }

    // MARK: - CoreAudio

    /// Is any app using the default input device right now?
    static func microphoneInUse() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown
        else { return false }

        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }
}
