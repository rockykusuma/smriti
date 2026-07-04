import AppKit

/// An NSTextView that shows placeholder text when empty (AppKit has none).
final class PlaceholderTextView: NSTextView {
    var placeholderString = ""
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        (placeholderString as NSString).draw(
            at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
            withAttributes: attrs)
    }
}

/// "Ask Smriti": a chat window over your captured memory. Each question runs
/// an agentic Sonnet turn (via `MemoryChat`) that calls Smriti's own MCP tools
/// to find answers, streams the reply, and lists what it looked at. Snapshot
/// ids in answers are clickable and open the full capture.
final class AskSection: NSObject, MainSection, NSTextViewDelegate {
    let title = "Ask Smriti"
    let symbol = "sparkles"

    private let store: Store
    private let chat = MemoryChat()
    private var view: NSView?
    private let transcript = NSTextView()
    private let inputView = PlaceholderTextView()
    private let sendButton = NSButton()
    private let newChatButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var suggestions: NSView?
    private var busy = false
    private var answerStart = 0
    private var warmed = false

    private let suggestionQuestions = [
        "What did I work on today?",
        "Summarize what I did yesterday",
        "What projects have I been working on this week?",
    ]

    init(store: Store) {
        self.store = store
        super.init()
    }

    // MARK: - View

    func makeView() -> NSView {
        if let view { return view }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 739, height: 620))

        // Multiline input (Enter sends, Shift+Enter newline).
        inputView.placeholderString = "Ask about anything you've seen…   (Shift+Enter for a new line)"
        inputView.font = .systemFont(ofSize: 13)
        inputView.isRichText = false
        inputView.textContainerInset = NSSize(width: 4, height: 6)
        inputView.isVerticallyResizable = true
        inputView.isHorizontallyResizable = false
        inputView.autoresizingMask = [.width]
        inputView.textContainer?.widthTracksTextView = true
        inputView.delegate = self
        let inputScroll = NSScrollView(frame: NSRect(x: 16, y: 10, width: 739 - 16 - 92, height: 54))
        inputScroll.borderType = .bezelBorder
        inputScroll.hasVerticalScroller = true
        inputScroll.documentView = inputView
        inputScroll.autoresizingMask = [.width, .maxYMargin]

        sendButton.title = "Ask"
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.frame = NSRect(x: 739 - 16 - 76, y: 12, width: 76, height: 30)
        sendButton.autoresizingMask = [.minXMargin, .maxYMargin]

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 18, y: 68, width: 739 - 36, height: 15)
        statusLabel.autoresizingMask = [.width, .maxYMargin]

        newChatButton.title = "New chat"
        newChatButton.bezelStyle = .rounded
        newChatButton.controlSize = .small
        newChatButton.target = self
        newChatButton.action = #selector(newChat)
        newChatButton.frame = NSRect(x: 739 - 16 - 90, y: 588, width: 90, height: 24)
        newChatButton.autoresizingMask = [.minXMargin, .minYMargin]
        newChatButton.isHidden = true

        transcript.delegate = self
        transcript.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        let scroll = MasterDetailSection.makeTextScroll(
            transcript, frame: NSRect(x: 0, y: 90, width: 739, height: 620 - 90 - 42))
        scroll.autoresizingMask = [.width, .height]

        container.addSubview(scroll)
        container.addSubview(newChatButton)
        container.addSubview(statusLabel)
        container.addSubview(inputScroll)
        container.addSubview(sendButton)
        showEmptyState(in: container)

        view = container
        return container
    }

    func willAppear() {
        if !warmed {
            warmed = true
            DispatchQueue.global(qos: .userInitiated).async { [chat] in chat.prewarm() }
        }
        DispatchQueue.main.async { [weak self] in
            self?.inputView.window?.makeFirstResponder(self?.inputView)
        }
    }

    private func showEmptyState(in container: NSView) {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 10
        box.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "Ask Smriti")
        heading.font = .systemFont(ofSize: 22, weight: .bold)
        let sub = NSTextField(wrappingLabelWithString:
            "Ask anything about what you've seen on your Mac. Smriti searches your captured screen memory and daily chronicles to answer — grounded in what you actually did.")
        sub.font = .systemFont(ofSize: 13)
        sub.textColor = .secondaryLabelColor
        sub.preferredMaxLayoutWidth = 520
        box.addArrangedSubview(heading)
        box.addArrangedSubview(sub)
        box.setCustomSpacing(18, after: sub)

        for q in suggestionQuestions {
            let b = NSButton(title: q, target: self, action: #selector(suggestionClicked(_:)))
            b.bezelStyle = .rounded
            box.addArrangedSubview(b)
        }

        container.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),
            box.topAnchor.constraint(equalTo: container.topAnchor, constant: 56),
            box.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -40),
        ])
        suggestions = box
    }

    // MARK: - Actions

    @objc private func suggestionClicked(_ sender: NSButton) {
        inputView.string = sender.title
        send()
    }

    @objc private func newChat() {
        guard !busy else { return }
        chat.reset()
        transcript.textStorage?.setAttributedString(NSAttributedString(string: ""))
        statusLabel.stringValue = ""
        newChatButton.isHidden = true
        if let container = view { showEmptyState(in: container) }
        inputView.window?.makeFirstResponder(inputView)
    }

    @objc private func send() {
        let q = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        inputView.string = ""
        inputView.needsDisplay = true
        suggestions?.removeFromSuperview()
        suggestions = nil
        newChatButton.isHidden = false

        busy = true
        sendButton.isEnabled = false
        appendUser(q)
        beginAnswer()
        statusLabel.stringValue = "Thinking…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self, chat] in
            guard let self else { return }
            var tools: [MemoryChat.ToolCall] = []
            let answer = chat.ask(
                q,
                onDelta: { frag in DispatchQueue.main.async { self.appendAnswerDelta(frag) } },
                onTool: { call in
                    tools.append(call)
                    DispatchQueue.main.async { self.statusLabel.stringValue = self.activity(for: call) }
                })
            DispatchQueue.main.async {
                self.finishAnswer(answer, tools: tools)
                self.busy = false
                self.sendButton.isEnabled = true
                self.statusLabel.stringValue = ""
            }
        }
    }

    // MARK: - NSTextViewDelegate (Enter to send, link clicks)

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === inputView, commandSelector == #selector(NSResponder.insertNewline(_:))
        else { return false }
        let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if shiftHeld { return false } // let it insert a newline
        send()
        return true
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        guard let url, url.scheme == "smriti-snapshot" else { return false }
        let idString = url.absoluteString.replacingOccurrences(of: "smriti-snapshot:", with: "")
        if let id = Int64(idString) { openSnapshot(id: id) }
        return true
    }

    // MARK: - Transcript rendering

    private func appendUser(_ text: String) {
        guard let ts = transcript.textStorage else { return }
        let label = NSMutableParagraphStyle()
        label.paragraphSpacingBefore = 18
        label.paragraphSpacing = 3
        ts.append(NSAttributedString(string: "You\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: label,
        ]))
        let body = NSMutableParagraphStyle()
        body.lineSpacing = 3
        body.paragraphSpacing = 8
        ts.append(NSAttributedString(string: text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: body,
        ]))
        scrollToBottom()
    }

    private func beginAnswer() {
        guard let ts = transcript.textStorage else { return }
        let label = NSMutableParagraphStyle()
        label.paragraphSpacingBefore = 4
        label.paragraphSpacing = 3
        ts.append(NSAttributedString(string: "Smriti\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.systemPink, .paragraphStyle: label,
        ]))
        answerStart = ts.length
        scrollToBottom()
    }

    private func appendAnswerDelta(_ fragment: String) {
        guard let ts = transcript.textStorage else { return }
        ts.append(NSAttributedString(string: fragment, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
        ]))
        scrollToBottom()
    }

    private func finishAnswer(_ answer: String?, tools: [MemoryChat.ToolCall]) {
        guard let ts = transcript.textStorage else { return }
        let range = NSRange(location: answerStart, length: ts.length - answerStart)
        if let answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ts.replaceCharacters(in: range, with: linkifySnapshots(MarkdownRenderer.attributed(answer)))
            if !tools.isEmpty { ts.append(sourcesFooter(tools)) }
        } else {
            ts.replaceCharacters(in: range, with: NSAttributedString(
                string: "I couldn't get an answer. Check that the Claude CLI is logged in (Settings → Claude account).\n",
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        scrollToBottom()
    }

    /// Turn `#123` snapshot references into clickable links.
    private func linkifySnapshots(_ attributed: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: attributed)
        let ns = m.string as NSString
        guard let regex = try? NSRegularExpression(pattern: "#(\\d+)") else { return m }
        let matches = regex.matches(in: m.string, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let id = ns.substring(with: match.range(at: 1))
            guard let url = URL(string: "smriti-snapshot:\(id)") else { continue }
            m.addAttribute(.link, value: url, range: match.range)
        }
        return m
    }

    private func sourcesFooter(_ tools: [MemoryChat.ToolCall]) -> NSAttributedString {
        let items = tools.map { $0.summary.isEmpty ? $0.name : "\($0.name): \($0.summary)" }
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0).inserted }
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = 6
        para.paragraphSpacing = 14
        return NSAttributedString(string: "🔎 " + unique.joined(separator: "   ·   ") + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: para,
        ])
    }

    private func activity(for call: MemoryChat.ToolCall) -> String {
        switch call.name {
        case "search_memory":
            return call.summary.isEmpty ? "Searching your memory…" : "Searching memory: \(call.summary)…"
        case "get_chronicle": return "Reading the chronicle for \(call.summary)…"
        case "list_chronicles": return "Looking over your chronicles…"
        case "get_recent_activity": return "Checking recent activity…"
        case "get_snapshot": return "Reading snapshot \(call.summary)…"
        default: return "Searching your memory…"
        }
    }

    private func scrollToBottom() {
        transcript.scrollToEndOfDocument(nil)
    }

    // MARK: - Snapshot viewer

    private var snapshotPanel: NSPanel?
    private let snapshotText = NSTextView()

    private func openSnapshot(id: Int64) {
        let body: String
        if let snap = try? store.getSnapshot(id: id) {
            let urlLine = snap.url.isEmpty ? "" : "\(snap.url)\n"
            body = "\(snap.app) — \(snap.windowTitle)\n\(snap.lastSeenAt)\n\(urlLine)\(String(repeating: "─", count: 40))\n\n\(snap.content)"
        } else {
            body = "Snapshot #\(id) is no longer in the store (it may have been pruned)."
        }
        let panel = snapshotPanel ?? makeSnapshotPanel()
        snapshotPanel = panel
        snapshotText.string = body
        snapshotText.scrollToBeginningOfDocument(nil)
        panel.title = "Snapshot #\(id)"
        panel.makeKeyAndOrderFront(nil)
        panel.center()
    }

    private func makeSnapshotPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        let scroll = MasterDetailSection.makeTextScroll(
            snapshotText, frame: NSRect(x: 0, y: 0, width: 560, height: 460))
        scroll.autoresizingMask = [.width, .height]
        snapshotText.isEditable = false
        panel.contentView = scroll
        return panel
    }
}
