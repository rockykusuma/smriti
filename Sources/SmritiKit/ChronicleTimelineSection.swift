import AppKit

/// Enhanced Chronicles section: a list of days on the left, and an
/// hour-grouped snapshot timeline with chronicle markdown on the right.
/// Replaces the flat MasterDetailSection used previously.
final class ChronicleTimelineSection: NSObject, MainSection, NSTableViewDataSource, NSTableViewDelegate {
    let title = "Chronicles"
    let symbol = "calendar"

    private let store: Store
    private var view: NSView?
    private let table = NSTableView()
    private var chronicles: [Store.Chronicle] = []
    private let detailContainer = NSView()
    private let detailText = NSTextView()
    private var detailScroll: NSScrollView?
    private let timelineStack = NSStackView()
    private var selectedDay: String?

    init(store: Store) {
        self.store = store
        super.init()
    }

    func makeView() -> NSView {
        if let view { return view }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 739, height: 620))

        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 739, height: 620))
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]

        // Left: day list
        let column = NSTableColumn(identifier: .init("day"))
        column.width = 240
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 48
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.style = .inset
        let listScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 620))
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.autoresizingMask = [.height]

        // Right: detail (chronicle + timeline)
        detailText.isEditable = false
        detailText.drawsBackground = false
        detailText.textColor = Theme.ink
        detailText.font = Theme.body(14)
        detailText.textContainerInset = NSSize(width: 24, height: 22)
        detailText.isVerticallyResizable = true
        detailText.isHorizontallyResizable = false
        detailText.autoresizingMask = [.width]
        detailText.textContainer?.widthTracksTextView = true

        let chronicleScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 478, height: 300))
        chronicleScroll.drawsBackground = false
        chronicleScroll.hasVerticalScroller = true
        chronicleScroll.documentView = detailText
        chronicleScroll.autoresizingMask = [.width, .height]

        timelineStack.orientation = .vertical
        timelineStack.alignment = .leading
        timelineStack.spacing = Theme.Space.xs
        timelineStack.translatesAutoresizingMaskIntoConstraints = false

        let timelineScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 478, height: 320))
        timelineScroll.drawsBackground = false
        timelineScroll.hasVerticalScroller = true
        timelineScroll.documentView = timelineStack
        timelineScroll.autoresizingMask = [.width, .height]
        timelineScroll.borderType = .noBorder

        let detailSplit = NSSplitView(frame: NSRect(x: 0, y: 0, width: 478, height: 620))
        detailSplit.isVertical = false
        detailSplit.dividerStyle = .thin
        detailSplit.autoresizingMask = [.width, .height]
        detailSplit.addSubview(chronicleScroll)
        detailSplit.addSubview(timelineScroll)
        detailSplit.setPosition(300, ofDividerAt: 0)

        detailContainer.frame = detailSplit.frame
        detailContainer.autoresizingMask = [.width, .height]
        detailContainer.addSubview(detailSplit)

        split.addSubview(listScroll)
        split.addSubview(detailContainer)
        container.addSubview(split)
        split.setPosition(260, ofDividerAt: 0)

        view = container
        return container
    }

    func willAppear() { reload() }

    private func reload() {
        chronicles = (try? store.listChronicles(limit: 200)) ?? []
        table.reloadData()
        if !chronicles.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            selectDay(chronicles[0].day)
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { chronicles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < chronicles.count else { return nil }
        let c = chronicles[row]
        let cell = NSTableCellView()

        let titleLabel = NSTextField(labelWithString: formatDay(c.day))
        titleLabel.font = Theme.body(13, .semibold)
        titleLabel.textColor = Theme.ink
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let countBadge = NSTextField(labelWithString: "\(c.snapshotCount) snaps")
        countBadge.font = Theme.body(10)
        countBadge.textColor = Theme.inkTertiary
        countBadge.translatesAutoresizingMaskIntoConstraints = false

        let preview = NSTextField(labelWithString: c.summary
            .components(separatedBy: "\n").first ?? "")
        preview.font = Theme.body(11)
        preview.textColor = Theme.inkSecondary
        preview.lineBreakMode = .byTruncatingTail
        preview.maximumNumberOfLines = 1
        preview.translatesAutoresizingMaskIntoConstraints = false

        let col = NSStackView(views: [titleLabel, preview])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 2
        col.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(col)
        cell.addSubview(countBadge)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            col.trailingAnchor.constraint(equalTo: countBadge.leadingAnchor, constant: -6),
            col.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            countBadge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            countBadge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, table.selectedRow < chronicles.count else { return }
        selectDay(chronicles[table.selectedRow].day)
    }

    // MARK: - Detail

    private func selectDay(_ day: String) {
        selectedDay = day
        let chronicle = try? store.getChronicle(day: day)

        if let chronicle {
            detailText.textStorage?.setAttributedString(
                MarkdownRenderer.attributed(chronicle.summary))
        } else {
            detailText.textStorage?.setAttributedString(NSAttributedString(
                string: "No chronicle written for \(day).",
                attributes: [.font: Theme.body(13), .foregroundColor: Theme.inkSecondary]))
        }

        let snapshots = (try? store.snapshotsForDay(day)) ?? []
        rebuildTimeline(snapshots)
    }

    private func rebuildTimeline(_ snapshots: [Store.Snapshot]) {
        timelineStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if snapshots.isEmpty {
            let empty = NSTextField(labelWithString: "No snapshots for this day.")
            empty.font = Theme.body(13)
            empty.textColor = Theme.inkSecondary
            timelineStack.addArrangedSubview(empty)
            return
        }

        let groups = TimelineHelpers.groupByHour(snapshots)
        for group in groups {
            let sep = NSTextField(labelWithString: "—— \(group.hour) ——")
            sep.font = Theme.body(11, .medium)
            sep.textColor = Theme.inkTertiary
            sep.translatesAutoresizingMaskIntoConstraints = false
            timelineStack.addArrangedSubview(sep)
            sep.widthAnchor.constraint(equalToConstant: 440).isActive = true

            for snap in group.snapshots {
                let row = SnapshotRowView(snapshot: snap, showTimestamp: false)
                row.translatesAutoresizingMaskIntoConstraints = false
                timelineStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: 440).isActive = true
            }
        }
    }

    private func formatDay(_ day: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        guard let date = fmt.date(from: day) else { return day }
        let out = DateFormatter()
        out.dateFormat = "EEEE, MMM d"
        return out.string(from: date)
    }
}
