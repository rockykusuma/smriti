import AppKit

/// "Ask Smriti": a chat window over your captured memory. Each question runs
/// an agentic Sonnet turn (via `MemoryChat`) that calls Smriti's own MCP tools
/// to find answers, streams the reply, and lists what it looked at.
final class AskSection: NSObject, MainSection {
    let title = "Ask Smriti"
    let symbol = "sparkles"

    private let chat = MemoryChat()
    private var view: NSView?
    private let transcript = NSTextView()
    private let input = NSTextField()
    private let sendButton = NSButton()
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

    // MARK: - View

    func makeView() -> NSView {
        if let view { return view }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 739, height: 620))

        input.placeholderString = "Ask about anything you've seen…"
        input.font = .systemFont(ofSize: 13)
        input.target = self
        input.action = #selector(send)
        input.frame = NSRect(x: 16, y: 12, width: 739 - 16 - 92, height: 26)
        input.autoresizingMask = [.width, .maxYMargin]

        sendButton.title = "Ask"
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.frame = NSRect(x: 739 - 16 - 76, y: 9, width: 76, height: 30)
        sendButton.autoresizingMask = [.minXMargin, .maxYMargin]

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 18, y: 44, width: 739 - 36, height: 15)
        statusLabel.autoresizingMask = [.width, .maxYMargin]

        let scroll = MasterDetailSection.makeTextScroll(
            transcript, frame: NSRect(x: 0, y: 66, width: 739, height: 620 - 66))
        scroll.autoresizingMask = [.width, .height]

        container.addSubview(scroll)
        container.addSubview(statusLabel)
        container.addSubview(input)
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
            self?.input.window?.makeFirstResponder(self?.input)
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
        input.stringValue = sender.title
        send()
    }

    @objc private func send() {
        let q = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        input.stringValue = ""
        suggestions?.removeFromSuperview()
        suggestions = nil

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
            ts.replaceCharacters(in: range, with: MarkdownRenderer.attributed(answer))
            if !tools.isEmpty { ts.append(sourcesFooter(tools)) }
        } else {
            ts.replaceCharacters(in: range, with: NSAttributedString(
                string: "I couldn't get an answer. Check that the Claude CLI is logged in (Settings → Claude account).\n",
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        scrollToBottom()
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
        case "get_chronicle":
            return "Reading the chronicle for \(call.summary)…"
        case "list_chronicles":
            return "Looking over your chronicles…"
        case "get_recent_activity":
            return "Checking recent activity…"
        case "get_snapshot":
            return "Reading snapshot \(call.summary)…"
        default:
            return "Searching your memory…"
        }
    }

    private func scrollToBottom() {
        transcript.scrollToEndOfDocument(nil)
    }
}
