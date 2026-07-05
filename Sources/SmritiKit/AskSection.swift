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
        (placeholderString as NSString).draw(
            at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
            withAttributes: [.font: font ?? Theme.body(14), .foregroundColor: Theme.inkTertiary])
    }
}

/// "Ask Smriti": a chat window over your captured memory, styled to feel calm
/// and editorial. Each question runs an agentic Sonnet turn (via `MemoryChat`)
/// that calls Smriti's own MCP tools; snapshot ids in answers are clickable.
final class AskSection: NSObject, MainSection, NSTextViewDelegate {
    let title = "Ask Smriti"
    let symbol = "sparkles"

    private let store: Store
    private let chat = MemoryChat()
    private var view: NSView?
    private let transcript = NSTextView()
    private let inputView = PlaceholderTextView()
    private let composerCard = Theme.makeCard()
    private let sendButton = ThemedButton()
    private let newChatButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var emptyState: NSView?
    private var busy = false
    private var answerStart = 0
    private var warmed = false

    private let suggestionQuestions = [
        "What did I work on today?",
        "Summarize what I did yesterday",
        "What have I been working on this week?",
    ]

    init(store: Store) {
        self.store = store
        super.init()
    }

    // MARK: - View

    func makeView() -> NSView {
        if let view { return view }
        let W: CGFloat = 739, H: CGFloat = 620
        let container = ThemedView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        container.fillColor = Theme.surface

        // Composer card, docked at the bottom.
        let cardH: CGFloat = 104
        composerCard.frame = NSRect(x: Theme.Space.lg, y: Theme.Space.md,
                                    width: W - 2*Theme.Space.lg, height: cardH)
        composerCard.autoresizingMask = [.width, .maxYMargin]

        inputView.placeholderString = "Ask about anything you've seen…"
        inputView.font = Theme.body(14)
        inputView.textColor = Theme.ink
        inputView.isRichText = false
        inputView.drawsBackground = false
        inputView.textContainerInset = NSSize(width: 6, height: 4)
        inputView.isVerticallyResizable = true
        inputView.isHorizontallyResizable = false
        inputView.autoresizingMask = [.width]
        inputView.textContainer?.widthTracksTextView = true
        inputView.delegate = self
        let inputScroll = NSScrollView(frame: NSRect(x: 14, y: 42, width: composerCard.frame.width - 28, height: cardH - 42 - 8))
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = true
        inputScroll.documentView = inputView
        inputScroll.autoresizingMask = [.width, .height]
        composerCard.addSubview(inputScroll)

        let sSize: CGFloat = 32
        sendButton.frame = NSRect(x: composerCard.frame.width - 14 - sSize, y: 12, width: sSize, height: sSize)
        sendButton.autoresizingMask = [.minXMargin]
        sendButton.isBordered = false
        sendButton.bezelStyle = .regularSquare
        sendButton.title = ""
        sendButton.circular = true
        sendButton.fillColor = Theme.accent
        sendButton.contentTintColor = .white
        let arrow = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Send")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        sendButton.image = arrow
        sendButton.imagePosition = .imageOnly
        sendButton.target = self
        sendButton.action = #selector(send)
        composerCard.addSubview(sendButton)

        let hint = NSTextField(labelWithString: "⏎ send   ·   ⇧⏎ new line")
        hint.font = Theme.body(10)
        hint.textColor = Theme.inkTertiary
        hint.frame = NSRect(x: 16, y: 15, width: 220, height: 14)
        hint.autoresizingMask = [.maxXMargin]
        composerCard.addSubview(hint)

        statusLabel.font = Theme.body(11)
        statusLabel.textColor = Theme.accent
        statusLabel.frame = NSRect(x: Theme.Space.lg + 4, y: Theme.Space.md + cardH + 6, width: W - 2*Theme.Space.lg, height: 15)
        statusLabel.autoresizingMask = [.width, .maxYMargin]

        newChatButton.title = "New chat"
        newChatButton.bezelStyle = .rounded
        newChatButton.controlSize = .small
        newChatButton.target = self
        newChatButton.action = #selector(newChat)
        newChatButton.frame = NSRect(x: W - 16 - 84, y: H - 34, width: 84, height: 22)
        newChatButton.autoresizingMask = [.minXMargin, .minYMargin]
        newChatButton.isHidden = true

        transcript.delegate = self
        transcript.isEditable = false
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 30, height: 26)
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        transcript.linkTextAttributes = [.foregroundColor: Theme.accent, .cursor: NSCursor.pointingHand]
        let tScroll = NSScrollView(frame: NSRect(x: 0, y: Theme.Space.md + cardH + 26, width: W, height: H - (Theme.Space.md + cardH + 26)))
        tScroll.drawsBackground = false
        tScroll.hasVerticalScroller = true
        tScroll.documentView = transcript
        tScroll.autoresizingMask = [.width, .height]

        container.addSubview(tScroll)
        container.addSubview(newChatButton)
        container.addSubview(statusLabel)
        container.addSubview(composerCard)
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
        box.alignment = .centerX
        box.spacing = Theme.Space.sm
        box.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "What's on your mind?")
        heading.font = Theme.serif(28, .medium)
        heading.textColor = Theme.ink
        heading.alignment = .center
        let sub = NSTextField(labelWithString: "Ask anything about what you've seen — grounded in your real work.")
        sub.font = Theme.body(13)
        sub.textColor = Theme.inkSecondary
        sub.alignment = .center
        box.addArrangedSubview(heading)
        box.addArrangedSubview(sub)
        box.setCustomSpacing(Theme.Space.lg, after: sub)

        for q in suggestionQuestions {
            box.addArrangedSubview(makePill(q))
        }

        container.addSubview(box)
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            box.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: 40),
            box.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 40),
        ])
        emptyState = box
    }

    private func makePill(_ text: String) -> NSButton {
        let b = ThemedButton(title: "", target: self, action: #selector(suggestionClicked(_:)))
        b.isBordered = false
        b.fillColor = Theme.card
        b.strokeColor = Theme.border
        b.corner = 15
        b.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: Theme.body(13), .foregroundColor: Theme.ink,
        ])
        let width = (text as NSString).size(withAttributes: [.font: Theme.body(13)]).width + 32
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        b.widthAnchor.constraint(equalToConstant: ceil(width)).isActive = true
        return b
    }

    // MARK: - Actions

    @objc private func suggestionClicked(_ sender: NSButton) {
        inputView.string = sender.attributedTitle.string
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
        emptyState?.removeFromSuperview()
        emptyState = nil
        newChatButton.isHidden = false

        busy = true
        sendButton.isEnabled = false
        sendButton.fillColor = Theme.inkTertiary
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
                self.sendButton.fillColor = Theme.accent
                self.statusLabel.stringValue = ""
            }
        }
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === inputView, commandSelector == #selector(NSResponder.insertNewline(_:))
        else { return false }
        let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        if shiftHeld { return false }
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
        label.paragraphSpacingBefore = 22
        label.paragraphSpacing = 3
        ts.append(NSAttributedString(string: "YOU\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: Theme.inkTertiary, .kern: 1.2, .paragraphStyle: label,
        ]))
        let body = NSMutableParagraphStyle()
        body.lineSpacing = 4
        body.paragraphSpacing = 8
        ts.append(NSAttributedString(string: text + "\n", attributes: [
            .font: Theme.body(15), .foregroundColor: Theme.ink, .paragraphStyle: body,
        ]))
        scrollToBottom()
    }

    private func beginAnswer() {
        guard let ts = transcript.textStorage else { return }
        let label = NSMutableParagraphStyle()
        label.paragraphSpacingBefore = 6
        label.paragraphSpacing = 3
        ts.append(NSAttributedString(string: "SMRITI\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: Theme.accent, .kern: 1.2, .paragraphStyle: label,
        ]))
        answerStart = ts.length
        scrollToBottom()
    }

    private func appendAnswerDelta(_ fragment: String) {
        guard let ts = transcript.textStorage else { return }
        ts.append(NSAttributedString(string: fragment, attributes: [
            .font: Theme.body(15), .foregroundColor: Theme.ink,
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
                attributes: [.font: Theme.body(13), .foregroundColor: Theme.inkSecondary]))
        }
        scrollToBottom()
    }

    private func linkifySnapshots(_ attributed: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: attributed)
        let ns = m.string as NSString
        guard let regex = try? NSRegularExpression(pattern: "#(\\d+)") else { return m }
        for match in regex.matches(in: m.string, range: NSRange(location: 0, length: ns.length)).reversed() {
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
        para.paragraphSpacingBefore = 8
        para.paragraphSpacing = 14
        return NSAttributedString(string: "🔎  " + unique.joined(separator: "   ·   ") + "\n", attributes: [
            .font: Theme.body(10), .foregroundColor: Theme.inkTertiary, .paragraphStyle: para,
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

    private func scrollToBottom() { transcript.scrollToEndOfDocument(nil) }

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
        Theme.style(window: panel, background: Theme.surface)
        let scroll = MasterDetailSection.makeTextScroll(
            snapshotText, frame: NSRect(x: 0, y: 0, width: 560, height: 460))
        scroll.autoresizingMask = [.width, .height]
        snapshotText.isEditable = false
        snapshotText.drawsBackground = false
        snapshotText.textColor = Theme.ink
        panel.contentView = scroll
        return panel
    }
}
