import AppKit

// MARK: - Home

final class HomeSection: NSObject, MainSection {
    let title = "Overview"
    let symbol = "square.grid.2x2"
    private let store: Store
    private weak var owner: MainWindow?
    private var view: NSView?

    private let dot = NSView()
    private let statusText = NSTextField(labelWithString: "Capturing")
    private let statusCaption = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()
    private let todayValue = NSTextField(labelWithString: "—")
    private let totalValue = NSTextField(labelWithString: "—")
    private let appsValue = NSTextField(labelWithString: "—")
    private let spanLabel = NSTextField(labelWithString: "")

    init(store: Store, owner: MainWindow) {
        self.store = store
        self.owner = owner
    }

    func makeView() -> NSView {
        if let view { return view }
        let heading = NSTextField(labelWithString: "Smriti")
        heading.font = Theme.serif(32, .semibold)
        heading.textColor = Theme.ink
        let subtitle = NSTextField(labelWithString: "A local memory for your Mac.")
        subtitle.font = Theme.body(13)
        subtitle.textColor = Theme.inkSecondary

        let stack = NSStackView(views: [heading, subtitle,
                                        makeStatusCard(), makeStatsCard(), makeActionsRow()])
        stack.orientation = .vertical
        stack.alignment = .width  // stretch cards to full width
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(4, after: heading)
        stack.setCustomSpacing(26, after: subtitle)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 739, height: 620))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -40),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
        ])
        view = container
        refresh()
        return container
    }

    // MARK: Cards

    private func makeStatusCard() -> NSView {
        let card = Theme.makeCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 68).isActive = true

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        statusText.font = Theme.body(15, .semibold)
        statusText.textColor = Theme.ink
        statusCaption.font = Theme.body(12)
        statusCaption.textColor = Theme.inkSecondary
        let textCol = NSStackView(views: [statusText, statusCaption])
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 2
        textCol.translatesAutoresizingMaskIntoConstraints = false
        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(dot); card.addSubview(textCol); card.addSubview(pauseButton)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            dot.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            textCol.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 12),
            textCol.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            pauseButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            pauseButton.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }

    private func statCell(_ value: NSTextField, _ caption: String) -> NSView {
        value.font = Theme.serif(26, .semibold)
        value.textColor = Theme.ink
        let cap = NSTextField(labelWithString: "")
        cap.attributedStringValue = Theme.label(caption)
        let col = NSStackView(views: [value, cap])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3
        return col
    }

    private func makeStatsCard() -> NSView {
        let card = Theme.makeCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.heightAnchor.constraint(equalToConstant: 112).isActive = true

        let row = NSStackView(views: [statCell(todayValue, "Today"),
                                      statCell(totalValue, "Snapshots"),
                                      statCell(appsValue, "Apps")])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.alignment = .top
        spanLabel.font = Theme.body(11)
        spanLabel.textColor = Theme.inkTertiary
        let col = NSStackView(views: [row, spanLabel])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 12
        col.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            col.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
        ])
        return card
    }

    private func actionButton(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let b = ThemedButton(title: "", target: self, action: action)
        b.isBordered = false
        b.fillColor = Theme.card
        b.strokeColor = Theme.border
        b.corner = 12
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        b.imagePosition = .imageLeading
        b.contentTintColor = Theme.accent
        b.attributedTitle = NSAttributedString(string: "  " + title, attributes: [
            .font: Theme.body(13, .medium), .foregroundColor: Theme.ink])
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 46).isActive = true
        return b
    }

    private func makeActionsRow() -> NSView {
        let row = NSStackView(views: [
            actionButton("Write today's chronicle", "calendar", #selector(writeChronicle)),
            actionButton("Learn my writing tone", "sparkles", #selector(learnTone)),
        ])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 12
        return row
    }

    func willAppear() { refresh() }

    private func refresh() {
        let paused = owner?.isPaused() ?? false
        dot.effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = (paused ? Theme.statusOff : Theme.statusOn).cgColor
        }
        statusText.stringValue = paused ? "Paused" : "Capturing"
        statusCaption.stringValue = paused
            ? "Screen capture is paused."
            : "Smriti is quietly watching your screen."
        pauseButton.title = paused ? "Resume" : "Pause"
        if let s = try? store.stats() {
            let today = (try? store.countForDay(Chronicler.dayString())) ?? 0
            todayValue.stringValue = "\(today)"
            totalValue.stringValue = "\(s.snapshotCount)"
            appsValue.stringValue = "\(s.distinctApps)"
            spanLabel.stringValue = "\(s.oldest ?? "—")   →   \(s.newest ?? "—")"
        }
    }

    @objc private func togglePause() {
        owner?.setPaused(!(owner?.isPaused() ?? false))
        refresh()
    }

    @objc private func writeChronicle() { owner?.writeChronicleNow() }
    @objc private func learnTone() { owner?.learnToneNow() }
}

