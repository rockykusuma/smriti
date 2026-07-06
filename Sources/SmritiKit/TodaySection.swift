import AppKit

/// "Today" sidebar section: shows today's chronicle (or a CTA to write one)
/// and an hour-grouped snapshot timeline for the current day.
final class TodaySection: NSObject, MainSection {
    let title = "Today"
    let symbol = "calendar.badge.clock"

    private let store: Store
    private var view: NSView?
    private var writeButton: ThemedButton?
    private var chronicleCard: ThemedView?
    private var chronicleText: NSTextView?
    private var timelineStack: NSStackView?
    private var emptyLabel: NSTextField?
    private var countLabel: NSTextField?

    var writeChronicleNow: () -> Void = {}

    init(store: Store) {
        self.store = store
        super.init()
    }

    func makeView() -> NSView {
        if let view { return view }
        let W: CGFloat = 739, H: CGFloat = 620
        let container = ThemedView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        container.fillColor = Theme.surface

        // Header
        let heading = NSTextField(labelWithString: "Today")
        heading.font = Theme.serif(24, .semibold)
        heading.textColor = Theme.ink

        countLabel = NSTextField(labelWithString: "")
        countLabel?.font = Theme.body(12)
        countLabel?.textColor = Theme.inkSecondary

        writeButton = ThemedButton(title: "", target: self, action: #selector(writeChronicle))
        writeButton?.isBordered = false
        writeButton?.fillColor = Theme.accent
        writeButton?.corner = Theme.Radius.control
        writeButton?.contentTintColor = .white
        writeButton?.attributedTitle = NSAttributedString(string: "  Write now", attributes: [
            .font: Theme.body(12, .medium), .foregroundColor: NSColor.white,
        ])
        writeButton?.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        writeButton?.imagePosition = .imageLeading
        writeButton?.translatesAutoresizingMaskIntoConstraints = false
        writeButton?.heightAnchor.constraint(equalToConstant: 28).isActive = true
        writeButton?.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let headerRow = NSStackView(views: [heading, countLabel!, writeButton!])
        headerRow.orientation = .horizontal
        headerRow.alignment = .firstBaseline
        headerRow.spacing = Theme.Space.sm
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        // Chronicle card
        let card = Theme.makeCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        chronicleCard = card

        chronicleText = NSTextView()
        chronicleText?.isEditable = false
        chronicleText?.drawsBackground = false
        chronicleText?.textColor = Theme.ink
        chronicleText?.font = Theme.body(14)
        chronicleText?.textContainerInset = NSSize(width: 20, height: 16)
        chronicleText?.isVerticallyResizable = true
        chronicleText?.isHorizontallyResizable = false
        chronicleText?.autoresizingMask = [.width]
        chronicleText?.textContainer?.widthTracksTextView = true
        let chronicleScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 680, height: 200))
        chronicleScroll.drawsBackground = false
        chronicleScroll.hasVerticalScroller = true
        chronicleScroll.documentView = chronicleText
        chronicleScroll.autoresizingMask = [.width, .height]
        chronicleScroll.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(chronicleScroll)

        emptyLabel = NSTextField(labelWithString: "No chronicle yet — write one to capture today's story.")
        emptyLabel?.font = Theme.body(13)
        emptyLabel?.textColor = Theme.inkSecondary
        emptyLabel?.alignment = .center
        emptyLabel?.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel?.isHidden = true
        card.addSubview(emptyLabel!)

        NSLayoutConstraint.activate([
            chronicleScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            chronicleScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            chronicleScroll.topAnchor.constraint(equalTo: card.topAnchor),
            chronicleScroll.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            chronicleScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),

            emptyLabel!.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            emptyLabel!.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])

        // Timeline section label
        let timelineLabel = NSTextField(labelWithString: "")
        timelineLabel.attributedStringValue = Theme.label("Snapshots")

        // Timeline stack (scrollable)
        timelineStack = NSStackView()
        timelineStack?.orientation = .vertical
        timelineStack?.alignment = .leading
        timelineStack?.spacing = Theme.Space.xs
        timelineStack?.translatesAutoresizingMaskIntoConstraints = false
        let timelineScroll = NSScrollView(frame: .zero)
        timelineScroll.drawsBackground = false
        timelineScroll.hasVerticalScroller = true
        timelineScroll.documentView = timelineStack
        timelineScroll.autoresizingMask = [.width, .height]
        timelineScroll.translatesAutoresizingMaskIntoConstraints = false
        timelineScroll.borderType = .noBorder

        // Main stack
        let mainStack = NSStackView(views: [headerRow, card, timelineLabel, timelineScroll])
        mainStack.orientation = .vertical
        mainStack.alignment = .width
        mainStack.spacing = Theme.Space.md
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.setCustomSpacing(Theme.Space.sm, after: headerRow)
        mainStack.setCustomSpacing(Theme.Space.sm, after: card)
        mainStack.setCustomSpacing(Theme.Space.xs, after: timelineLabel)

        container.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Space.xl),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Space.xl),
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Space.lg),
        ])

        view = container
        return container
    }

    func willAppear() { refresh() }

    func refresh() {
        let day = Chronicler.dayString()
        let todayCount = (try? store.countForDay(day)) ?? 0
        countLabel?.stringValue = "\(todayCount) snapshot\(todayCount == 1 ? "" : "s") captured"

        if let chronicle = try? store.getChronicle(day: day) {
            chronicleText?.textStorage?.setAttributedString(
                MarkdownRenderer.attributed(chronicle.summary))
            chronicleText?.isHidden = false
            chronicleCard?.isHidden = false
            emptyLabel?.isHidden = true
        } else {
            chronicleText?.isHidden = true
            emptyLabel?.isHidden = false
            chronicleCard?.isHidden = false
        }

        let snapshots = (try? store.snapshotsForDay(day)) ?? []
        rebuildTimeline(snapshots)
    }

    private func rebuildTimeline(_ snapshots: [Store.Snapshot]) {
        timelineStack?.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if snapshots.isEmpty {
            let empty = NSTextField(labelWithString: "No snapshots today. Smriti captures your screen automatically.")
            empty.font = Theme.body(13)
            empty.textColor = Theme.inkSecondary
            empty.alignment = .center
            timelineStack?.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalToConstant: 600).isActive = true
            return
        }

        let groups = TimelineHelpers.groupByHour(snapshots)
        for group in groups {
            let sep = NSTextField(labelWithString: "—— \(group.hour) ——")
            sep.font = Theme.body(11, .medium)
            sep.textColor = Theme.inkTertiary
            sep.translatesAutoresizingMaskIntoConstraints = false
            timelineStack?.addArrangedSubview(sep)
            sep.widthAnchor.constraint(equalToConstant: 680).isActive = true

            for snap in group.snapshots {
                let row = SnapshotRowView(snapshot: snap, showTimestamp: false)
                row.translatesAutoresizingMaskIntoConstraints = false
                timelineStack?.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: 680).isActive = true
            }
        }
    }

    @objc private func writeChronicle() { writeChronicleNow() }
}
