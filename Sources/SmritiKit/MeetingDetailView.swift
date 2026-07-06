import AppKit

/// Structured detail view for one meeting: metadata header, summary card,
/// this meeting's action items with checkboxes, an audio player bar, and the
/// transcript collapsed behind a disclosure. Replaces the plain markdown blob
/// in the Meetings pane's right side.
final class MeetingDetailView: NSView {

    private let store: Store
    /// Called after an item is checked/unchecked (owner refreshes the badge).
    private let onItemsChanged: () -> Void

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var playerBar: AudioPlayerBar?
    private var transcriptField: NSTextField?
    private var transcriptButton: NSButton?

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    init(store: Store, onItemsChanged: @escaping () -> Void) {
        self.store = store
        self.onItemsChanged = onItemsChanged
        super.init(frame: NSRect(x: 0, y: 0, width: 478, height: 620))

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        addSubview(scroll)

        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func stopPlayback() { playerBar?.stop() }

    /// Rebuild the view for a meeting snapshot.
    func show(snapshot: Store.Snapshot) {
        playerBar?.stop()
        playerBar = nil
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        // 1. Metadata header — the stored title already carries app + time +
        // duration ("Zoom 2026-07-06 14:30 (32 min)").
        let title = NSTextField(labelWithString: snapshot.windowTitle)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = Theme.ink
        title.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(title)

        // 2. Player bar — only when the stored url resolves to saved audio.
        if let dir = URL(string: snapshot.url), dir.isFileURL,
           FileManager.default.fileExists(atPath: dir.path) {
            let bar = AudioPlayerBar(directory: dir)
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 32).isActive = true
            bar.onUnavailable = { [weak bar] in bar?.isHidden = true }
            stack.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
            playerBar = bar
        }

        let (summary, transcript) = MeetingSummary.split(snapshot.content)

        // 3. Summary card.
        if let summary {
            let card = ThemedView(frame: .zero)
            card.fillColor = Theme.surface
            card.translatesAutoresizingMaskIntoConstraints = false
            let body = NSTextField(wrappingLabelWithString: "")
            body.attributedStringValue = MarkdownRenderer.attributed(summary)
            body.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(body)
            NSLayoutConstraint.activate([
                body.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
                body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
                body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
                body.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            ])
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }

        // 4. This meeting's action items, checkable inline.
        let items = (try? store.actionItems(snapshotId: snapshot.id)) ?? []
        if !items.isEmpty {
            let header = NSTextField(labelWithString: "Action items")
            header.font = .systemFont(ofSize: 12, weight: .semibold)
            header.textColor = .secondaryLabelColor
            stack.addArrangedSubview(header)
            for item in items {
                let box = NSButton(checkboxWithTitle: item.text,
                                   target: self, action: #selector(toggleItem(_:)))
                box.state = item.done ? .on : .off
                box.tag = Int(item.id)
                box.lineBreakMode = .byWordWrapping
                stack.addArrangedSubview(box)
                box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
            }
        }

        // 5. Transcript, collapsed by default.
        let disclose = NSButton(title: "Show transcript", target: self,
                                action: #selector(toggleTranscript))
        disclose.bezelStyle = .inline
        stack.addArrangedSubview(disclose)
        transcriptButton = disclose

        let body = NSTextField(wrappingLabelWithString: "")
        body.attributedStringValue = MarkdownRenderer.attributed(transcript)
        body.isHidden = true
        stack.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        transcriptField = body

        scroll.contentView.scroll(to: .zero)
    }

    @objc private func toggleItem(_ sender: NSButton) {
        let done = sender.state == .on
        do {
            try store.setActionItemDone(id: Int64(sender.tag), done: done)
            onItemsChanged()
        } catch {
            sender.state = done ? .off : .on // revert — write failed
            fputs("smriti action-items: toggle failed for #\(sender.tag): \(error)\n", stderr)
        }
    }

    @objc private func toggleTranscript() {
        guard let transcriptField else { return }
        transcriptField.isHidden.toggle()
        transcriptButton?.title = transcriptField.isHidden
            ? "Show transcript" : "Hide transcript"
    }
}
