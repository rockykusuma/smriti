import AppKit
import ApplicationServices
import Foundation

/// Recognizes a double-tap of the right Option key from a stream of events.
/// Pure logic, kept separate from AppKit so it can be unit-tested.
struct DoubleTapDetector {
    let window: TimeInterval
    private var lastTap: TimeInterval = -1
    private var brokenByOtherKey = true

    init(window: TimeInterval = 0.45) {
        self.window = window
    }

    /// Feed an Option-key-down moment; returns true when it completes a double-tap.
    mutating func optionDown(at time: TimeInterval) -> Bool {
        defer { brokenByOtherKey = false }
        if !brokenByOtherKey, lastTap >= 0, time - lastTap <= window {
            lastTap = -1
            return true
        }
        lastTap = time
        return false
    }

    /// Any other key or modifier breaks the sequence (typing ⌥-symbols etc.).
    mutating func interrupt() {
        brokenByOtherKey = true
        lastTap = -1
    }
}

/// The reply assistant: double-tap right ⌥ while focused in any text field, and
/// Smriti reads the surrounding window text (the conversation you're in),
/// asks Claude (Haiku) to draft the reply, and types it at your cursor.
/// You always review and hit send yourself.
public final class AssistListener {

    public private(set) var isEnabled = true
    /// Called on the main queue when generation starts/stops (for icon state).
    public var onGeneratingChange: ((Bool) -> Void)?

    private var pollTimer: Timer?
    private let warmClaude = WarmClaude()
    private var detector = DoubleTapDetector()
    private var generating = false
    private var rightOptionWasDown = false
    private var lastTapTime: TimeInterval = -1

    /// Device-dependent flag bit for the RIGHT Option key
    /// (NX_DEVICERALTKEYMASK). Left ⌥ (0x20) stays free for typing symbols.
    private static let rightOptionDeviceBit: UInt64 = 0x40

    public init() {}

    public func start() {
        // Event taps and NSEvent global monitors are unreliable for
        // launchd-spawned agents, so poll the session's aggregate modifier
        // state instead (30ms). No event stream needed; the double-tap is
        // recognized from key-down transitions of the right Option key.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.poll()
        }
        pollTimer?.tolerance = 0.01
        fputs("smriti assist: listening (double-tap right option, polling)\n", stderr)
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled { detector.interrupt() }
    }

    // MARK: - Modifier polling

    private func poll() {
        guard isEnabled else { return }

        let flags = CGEventSource.flagsState(.combinedSessionState)
        let raw = flags.rawValue
        let othersHeld = !flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty
        let rightDown = flags.contains(.maskAlternate)
            && (raw & AssistListener.rightOptionDeviceBit) != 0
            && !othersHeld

        defer { rightOptionWasDown = rightDown }
        guard rightDown, !rightOptionWasDown else { return } // key-down edge only

        let now = Date().timeIntervalSinceReferenceDate

        // If any normal key was pressed since the previous tap, the user is
        // typing ⌥-symbols or shortcuts — not tapping. Break the sequence.
        if lastTapTime > 0 {
            let sinceKeyDown = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: .keyDown)
            if sinceKeyDown < (now - lastTapTime) {
                detector.interrupt()
            }
        }
        lastTapTime = now

        if detector.optionDown(at: now) {
            if generating {
                // Heard you, but a draft is already in flight.
                fputs("smriti assist: busy — still drafting previous reply\n", stderr)
                NSSound(named: "Basso")?.play()
                return
            }
            fputs("smriti assist: triggered\n", stderr)
            NSSound(named: "Pop")?.play() // audible: gesture recognized
            trigger()
        }
    }

    // MARK: - The assist flow

    private func trigger() {
        // Everything here is AX IPC and subprocess work — keep it off the
        // main thread so the menu bar (and the poll timer) stay alive.
        setGenerating(true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer { self.setGenerating(false) }

            // 1. Where is the cursor? Must be an editable text element.
            guard let focused = self.focusedElement() else {
                fputs("smriti assist: no focused element\n", stderr)
                NSSound.beep()
                return
            }
            guard self.isEditable(focused) else {
                let role = (self.copyAttribute(focused, kAXRoleAttribute) as? String) ?? "?"
                fputs("smriti assist: focus not editable (role=\(role))\n", stderr)
                NSSound.beep()
                return
            }
            let draft = (self.copyAttribute(focused, kAXValueAttribute) as? String) ?? ""

            // 2. What is the conversation? Reuse the capture pipeline,
            //    time-boxed so huge Electron trees can't stall us.
            guard let capture = AXReader.captureFrontmost(timeBudget: 2.0) else {
                fputs("smriti assist: could not read window context\n", stderr)
                NSSound.beep()
                return
            }
            fputs("smriti assist: context \(capture.content.count) chars from \(capture.appName), drafting…\n", stderr)

            // 3. Draft the reply, then insert. --strict-mcp-config skips the
            //    user's MCP servers — a reply draft doesn't need them and
            //    they can add many seconds of startup.
            let started = Date()
            do {
                let fullPrompt = AssistListener.prompt(capture: capture, draft: draft)
                    + "\n(Disregard any earlier warmup exchange in this session.)"
                    + "\n\n--- WINDOW TEXT ---\n"
                    + String(capture.content.suffix(12_000))
                let raw: String
                if let warm = self.warmClaude.request(fullPrompt) {
                    raw = warm
                } else {
                    fputs("smriti assist: warm claude unavailable, cold run\n", stderr)
                    raw = try ClaudeCLI.run(
                        prompt: AssistListener.prompt(capture: capture, draft: draft),
                        stdin: String(capture.content.suffix(12_000)),
                        extraArgs: ["--model", "haiku", "--strict-mcp-config"])
                }
                let reply = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                fputs("smriti assist: drafted in \(String(format: "%.1f", Date().timeIntervalSince(started)))s\n", stderr)
                guard !reply.isEmpty, !reply.contains("NO_REPLY_CONTEXT") else {
                    fputs("smriti assist: nothing to reply to here\n", stderr)
                    NSSound.beep()
                    return
                }
                DispatchQueue.main.async {
                    self.insert(reply, into: focused)
                    NSSound(named: "Glass")?.play() // audible: reply delivered
                    fputs("smriti assist: reply typed (\(reply.count) chars)\n", stderr)
                }
            } catch {
                fputs("smriti assist: \(error)\n", stderr)
                NSSound.beep()
            }
        }
    }

    private static func prompt(capture: AXReader.WindowCapture, draft: String) -> String {
        var p = """
        You are drafting a reply on behalf of the user, who has their cursor \
        in a text input in \(capture.appName) (window: "\(capture.windowTitle)"\
        \(capture.url.isEmpty ? "" : ", page: \(capture.url)")). \
        Below (after --- WINDOW TEXT ---) is the visible text of that \
        window — a chat thread, comment section, or similar. Identify what the user is replying to \
        (the most recent message addressed to them, or the post nearest \
        their input) and write the reply they would plausibly send.

        Rules:
        - Output ONLY the reply text. No preamble, no quotes around it, no markdown.
        - Almost always draft a reply — chats, comment threads, emails, DMs, \
          forum posts, and AI-assistant conversations all count. Only if the \
          text is clearly not communication at all (a settings page, a code \
          editor, a file listing), output exactly: NO_REPLY_CONTEXT
        - Match the conversation's language, tone, and formality.
        - Be concise — the length of a real chat message or comment, not an essay.
        - Never invent facts, commitments, or dates the context doesn't support.
        """
        if !draft.isEmpty {
            p += """


            The user already started typing this draft — continue in its \
            spirit and produce only the COMPLETION (the text that should \
            follow what they typed): "\(draft.prefix(500))"
            """
        }
        return p
    }

    // MARK: - Insertion

    private func insert(_ text: String, into element: AXUIElement) {
        // Electron/web fields often accept AXSelectedText and render nothing,
        // so type synthesized unicode keystrokes instead — indistinguishable
        // from real typing. Re-assert focus on the original field first in
        // case it wandered during generation.
        AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(80_000)
        typeUnicode(text)
    }

    private func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)
        var index = 0
        while index < utf16.count {
            let chunk = Array(utf16[index ..< min(index + 20, utf16.count)])
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
            index += 20
            usleep(8_000) // keep event order stable in slow web views
        }
    }

    // MARK: - AX helpers

    private func focusedElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        if let focused = copyElement(appElement, kAXFocusedUIElementAttribute) {
            return focused
        }

        // Electron/Chromium apps return NoValue until their accessibility
        // tree is switched on. Flip the manual switch and retry briefly.
        AXUIElementSetAttributeValue(
            appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(
            appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        for _ in 0..<3 {
            usleep(150_000)
            if let focused = copyElement(appElement, kAXFocusedUIElementAttribute) {
                return focused
            }
        }

        // Last resort: walk the focused window for the element that claims
        // keyboard focus (AXFocused == true).
        if let window = copyElement(appElement, kAXFocusedWindowAttribute),
           let focused = findFocusDescendant(window, depth: 0) {
            return focused
        }
        fputs("smriti assist: no focused element in \(app.localizedName ?? "?")\n", stderr)
        return nil
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else { return nil }
        return (ref as! AXUIElement)
    }

    private func findFocusDescendant(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 30 else { return nil }
        if let focused = copyAttribute(element, kAXFocusedAttribute) as? Bool, focused,
           isEditable(element) {
            return element
        }
        guard let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }
        for child in children {
            if let found = findFocusDescendant(child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        let role = (copyAttribute(element, kAXRoleAttribute) as? String) ?? ""
        if role == kAXTextAreaRole || role == kAXTextFieldRole || role == kAXComboBoxRole {
            return true
        }
        // Web content (LinkedIn comment boxes etc.) often reports generic
        // roles but supports selected-text editing.
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable)
        return settable.boolValue
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    private func setGenerating(_ value: Bool) {
        DispatchQueue.main.async {
            self.generating = value
            self.onGeneratingChange?(value)
        }
    }
}
