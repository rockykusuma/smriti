import AppKit

/// The action-items hub: open items from every meeting in one checkable
/// list, grouped by source meeting (newest first). Check-off only — no
/// manual add, no edit. Lives behind the "Action items" segment of the
/// Meetings pane.
final class ActionItemsView: NSView {

    private let store: Store
    private let jumpToMeeting: (Int64) -> Void
    /// Called after any toggle so the owner can refresh the segment badge.
    private let onCountChanged: () -> Void

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let showCompleted = NSButton(checkboxWithTitle: "Show completed",
                                         target: nil, action: nil)

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    init(store: Store, jumpToMeeting: @escaping (Int64) -> Void,
         onCountChanged: @escaping () -> Void) {
        self.store = store
        self.jumpToMeeting = jumpToMeeting
        self.onCountChanged = onCountChanged
        super.init(frame: NSRect(x: 0, y: 0, width: 739, height: 572))

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        let footerHeight: CGFloat = 36
        scroll.frame = NSRect(x: 0, y: footerHeight, width: 739,
                              height: bounds.height - footerHeight)
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

        showCompleted.target = self
        showCompleted.action = #selector(refreshAction)
        showCompleted.frame = NSRect(x: 24, y: 8, width: 200, height: 20)
        showCompleted.autoresizingMask = [.maxXMargin, .maxYMargin]
        addSubview(showCompleted)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func refreshAction() { refresh() }

    /// Re-query and rebuild the grouped list.
    func refresh() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rows = (try? store.allActionItems(
            includeDone: showCompleted.state == .on)) ?? []

        guard !rows.isEmpty else {
            let empty = NSTextField(wrappingLabelWithString:
                "No action items yet. They're extracted automatically from meeting summaries — record a call or a voice note and they'll land here.")
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
            return
        }

        // Group consecutive rows by meeting (query is ordered by meeting).
        var groups: [(id: Int64, title: String, items: [Store.ActionItem])] = []
        for (item, title) in rows {
            if let last = groups.indices.last, groups[last].id == item.snapshotId {
                groups[last].items.append(item)
            } else {
                groups.append((item.snapshotId, title, [item]))
            }
        }

        for group in groups {
            let header = NSButton(title: group.title, target: self,
                                  action: #selector(jump(_:)))
            header.isBordered = false
            header.contentTintColor = .linkColor
            header.font = .systemFont(ofSize: 12, weight: .semibold)
            header.tag = Int(group.id)
            stack.addArrangedSubview(header)
            for item in group.items {
                let box = NSButton(checkboxWithTitle: item.text,
                                   target: self, action: #selector(toggle(_:)))
                box.state = item.done ? .on : .off
                box.tag = Int(item.id)
                box.lineBreakMode = .byWordWrapping
                stack.addArrangedSubview(box)
                box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64).isActive = true
            }
        }
    }

    @objc private func jump(_ sender: NSButton) {
        jumpToMeeting(Int64(sender.tag))
    }

    @objc private func toggle(_ sender: NSButton) {
        let done = sender.state == .on
        do {
            try store.setActionItemDone(id: Int64(sender.tag), done: done)
            onCountChanged()
        } catch {
            sender.state = done ? .off : .on
            fputs("smriti action-items: toggle failed for #\(sender.tag): \(error)\n", stderr)
        }
    }
}
