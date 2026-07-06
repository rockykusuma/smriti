import AppKit

// MARK: - Reusable master/detail (list on the left, text on the right)

/// A list + detail-text section driven by a loader closure returning
/// (title, body) rows. Used for Meetings and Chronicles.
final class MasterDetailSection: NSObject, MainSection, NSTableViewDataSource, NSTableViewDelegate {
    let title: String
    let symbol: String
    private let emptyMessage: String
    private let loader: () -> [(String, String)]

    private let table = NSTableView()
    private let text = NSTextView()
    private var rows: [(title: String, body: String)] = []
    private var view: NSView?

    /// When set, a row can supply its own detail view (used by Meetings for
    /// the structured meeting detail). Return nil to fall back to the default
    /// title + markdown text rendering.
    var detailProvider: ((Int) -> NSView?)?
    private let detailContainer = NSView()
    private var textScroll: NSScrollView?

    /// Optional record bar shown above the list (used by Meetings for manual
    /// voice notes). `isActive`/`toggle` drive a single Start/Stop button.
    struct RecordControls {
        let enabled: Bool
        let isActive: () -> Bool
        let toggle: () -> Void
        /// Current mic input level (0...1) for the live meter.
        let level: () -> Float
    }
    var recordControls: RecordControls?
    private let recordButton = NSButton()
    private let recordStatus = NSTextField(labelWithString: "")
    private var recordStartedAt: Date?
    private static let headerHeight: CGFloat = 48

    // Recording visualizer (Meetings only), shown over the list while a voice
    // note records or transcribes.
    private enum RecState { case idle, recording, transcribing }
    private var recState: RecState = .idle
    private var recordingPanel: NSView?
    private let levelMeter = LevelMeterView(frame: NSRect(x: 0, y: 0, width: 440, height: 90))
    private let recDot = NSView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
    private let recTitle = NSTextField(labelWithString: "Recording")
    private let recElapsed = NSTextField(labelWithString: "0:00")
    private let recHint = NSTextField(labelWithString: "Speak now. Click Stop & save when you're done.")
    private let transcribeSpinner = NSProgressIndicator()
    private let transcribeLabel = NSTextField(labelWithString: "Transcribing your note on-device...")
    private var titleRow: NSStackView?
    private var transRow: NSStackView?
    private var levelTimer: Timer?

    init(title: String, symbol: String, empty: String, loader: @escaping () -> [(String, String)]) {
        self.title = title
        self.symbol = symbol
        self.emptyMessage = empty
        self.loader = loader
    }

    func makeView() -> NSView {
        if let view { return view }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 739, height: 620))

        let hasHeader = recordControls != nil
        if hasHeader {
            let h = MasterDetailSection.headerHeight
            recordButton.bezelStyle = .rounded
            recordButton.controlSize = .large
            recordButton.target = self
            recordButton.action = #selector(toggleRecord)
            recordButton.frame = NSRect(x: 12, y: 620 - h + 10, width: 190, height: 28)
            recordButton.autoresizingMask = [.minYMargin]
            recordStatus.font = .systemFont(ofSize: 11)
            recordStatus.textColor = .secondaryLabelColor
            recordStatus.lineBreakMode = .byTruncatingTail
            recordStatus.frame = NSRect(x: 212, y: 620 - h + 15, width: 515, height: 18)
            recordStatus.autoresizingMask = [.minYMargin, .width]
            container.addSubview(recordButton)
            container.addSubview(recordStatus)
        }
        let splitHeight: CGFloat = hasHeader ? 620 - MasterDetailSection.headerHeight : 620

        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 739, height: splitHeight))
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]

        let column = NSTableColumn(identifier: .init("row"))
        column.width = 240
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.style = .inset
        let listScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 620))
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.autoresizingMask = [.height]

        let scroll = MasterDetailSection.makeTextScroll(text,
            frame: NSRect(x: 261, y: 0, width: 478, height: 620))
        scroll.autoresizingMask = [.width, .height]
        textScroll = scroll
        detailContainer.frame = scroll.frame
        detailContainer.autoresizingMask = [.width, .height]
        setDetail(scroll)

        split.addSubview(listScroll)
        split.addSubview(detailContainer)
        container.addSubview(split)
        split.setPosition(260, ofDividerAt: 0)

        if hasHeader {
            let panel = ThemedView(frame: NSRect(x: 0, y: 0, width: 739, height: splitHeight))
            panel.fillColor = Theme.surface
            panel.autoresizingMask = [.width, .height]
            panel.isHidden = true

            recDot.wantsLayer = true
            recDot.layer?.backgroundColor = NSColor.systemRed.cgColor
            recDot.layer?.cornerRadius = 6
            recDot.translatesAutoresizingMaskIntoConstraints = false
            recDot.widthAnchor.constraint(equalToConstant: 12).isActive = true
            recDot.heightAnchor.constraint(equalToConstant: 12).isActive = true

            recTitle.font = .systemFont(ofSize: 15, weight: .semibold)
            recTitle.textColor = Theme.ink
            let tRow = NSStackView(views: [recDot, recTitle])
            tRow.orientation = .horizontal
            tRow.spacing = 8
            tRow.alignment = .centerY
            titleRow = tRow

            recElapsed.font = .monospacedDigitSystemFont(ofSize: 44, weight: .thin)
            recElapsed.textColor = Theme.ink
            recElapsed.alignment = .center

            levelMeter.barColor = .systemRed
            levelMeter.translatesAutoresizingMaskIntoConstraints = false
            levelMeter.widthAnchor.constraint(equalToConstant: 440).isActive = true
            levelMeter.heightAnchor.constraint(equalToConstant: 90).isActive = true

            recHint.font = .systemFont(ofSize: 12)
            recHint.textColor = .secondaryLabelColor
            recHint.alignment = .center

            transcribeSpinner.style = .spinning
            transcribeSpinner.controlSize = .small
            transcribeSpinner.isDisplayedWhenStopped = false
            transcribeLabel.font = .systemFont(ofSize: 13)
            transcribeLabel.textColor = Theme.ink
            let trRow = NSStackView(views: [transcribeSpinner, transcribeLabel])
            trRow.orientation = .horizontal
            trRow.spacing = 10
            trRow.alignment = .centerY
            transRow = trRow

            let vstack = NSStackView(views: [tRow, recElapsed, levelMeter, recHint, trRow])
            vstack.orientation = .vertical
            vstack.alignment = .centerX
            vstack.spacing = 18
            vstack.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(vstack)
            NSLayoutConstraint.activate([
                vstack.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
                vstack.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
                vstack.leadingAnchor.constraint(greaterThanOrEqualTo: panel.leadingAnchor, constant: 24),
            ])
            container.addSubview(panel) // sits above the split; shown while recording
            recordingPanel = panel
        }

        view = container
        return container
    }

    func willAppear() {
        reloadRows()
    }

    /// Swap the right-hand detail area's content.
    private func setDetail(_ v: NSView) {
        guard v.superview !== detailContainer else { return }
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        v.frame = detailContainer.bounds
        v.autoresizingMask = [.width, .height]
        detailContainer.addSubview(v)
    }

    /// Select a list row programmatically (used by jump-to-meeting).
    func selectRow(_ index: Int) {
        guard index >= 0, index < rows.count else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    /// Reload the list from the loader and refresh the record button. Public so
    /// the owner can call it after an async voice note finishes transcribing.
    func reloadRows() {
        rows = loader()
        table.reloadData()
        if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            if let textScroll { setDetail(textScroll) }
            text.string = emptyMessage
        }
        // A finished transcription (store -> reloadMeetings) ends the
        // transcribing state; an active recording keeps its state.
        if recState == .transcribing { recState = .idle }
        if recordControls?.isActive() == true { recState = .recording }
        applyRecState()
    }

    @objc private func toggleRecord() {
        guard let rc = recordControls, rc.enabled else { return }
        if rc.isActive() {
            rc.toggle()                 // stop -> async transcribe + store
            recState = .transcribing
        } else {
            recordStartedAt = Date()
            rc.toggle()                 // start
            recState = rc.isActive() ? .recording : .idle
        }
        applyRecState()
    }

    private func applyRecState() {
        guard let rc = recordControls else { return }
        switch recState {
        case .idle:
            recordButton.isEnabled = rc.enabled
            recordButton.title = "● Record voice note"
            recordStatus.stringValue = rc.enabled
                ? "Talk, then Stop — transcribed on-device and saved below."
                : "Available in the installed app (needs Microphone + Speech Recognition)."
            recordingPanel?.isHidden = true
            stopLevelTimer()
        case .recording:
            recordButton.isEnabled = true
            recordButton.title = "◼ Stop & save"
            recordStatus.stringValue = "Recording…"
            titleRow?.isHidden = false
            recElapsed.isHidden = false
            levelMeter.isHidden = false
            recHint.isHidden = false
            transRow?.isHidden = true
            transcribeSpinner.stopAnimation(nil)
            recordingPanel?.isHidden = false
            startLevelTimer()
        case .transcribing:
            recordButton.isEnabled = false
            recordButton.title = "● Record voice note"
            recordStatus.stringValue = "Transcribing…"
            titleRow?.isHidden = true
            recElapsed.isHidden = true
            levelMeter.isHidden = true
            recHint.isHidden = true
            transRow?.isHidden = false
            transcribeSpinner.startAnimation(nil)
            recordingPanel?.isHidden = false
            stopLevelTimer()
        }
    }

    private func startLevelTimer() {
        stopLevelTimer()
        levelMeter.reset()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let rc = self.recordControls else { return }
            let lvl = Double(rc.level())
            // Map linear amplitude to 0...1 across ~ -60...0 dBFS, so a normal
            // speaking voice fills a good part of the meter.
            let norm = lvl > 0 ? max(0, min(1, (20 * log10(lvl) + 60) / 60)) : 0
            self.levelMeter.push(CGFloat(norm))
            let secs = Int(Date().timeIntervalSince(self.recordStartedAt ?? Date()))
            self.recElapsed.stringValue = String(format: "%d:%02d", secs / 60, secs % 60)
            // Gentle pulse on the record dot.
            let phase = abs(sin(Date().timeIntervalSinceReferenceDate * 3))
            self.recDot.alphaValue = 0.4 + 0.6 * CGFloat(phase)
        }
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        recDot.alphaValue = 1
    }

    static func makeTextScroll(_ text: NSTextView, frame: NSRect) -> NSScrollView {
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        text.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
        text.isEditable = false
        text.isRichText = true
        text.font = .systemFont(ofSize: 13)
        text.drawsBackground = false
        text.textColor = Theme.ink
        scroll.drawsBackground = false
        text.textContainerInset = NSSize(width: 24, height: 22)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        return scroll
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: rows[row].title)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        if let provider = detailProvider, let custom = provider(table.selectedRow) {
            setDetail(custom)
            return
        }
        if let textScroll { setDetail(textScroll) }
        let row = rows[table.selectedRow]
        let doc = NSMutableAttributedString()
        doc.append(MarkdownRenderer.caption(row.title))
        doc.append(MarkdownRenderer.attributed(row.body))
        text.textStorage?.setAttributedString(doc)
        text.scrollToBeginningOfDocument(nil)
    }
}
