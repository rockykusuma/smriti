import AppKit

/// The main Smriti window: a sidebar (Home, Meetings, Search, Chronicles,
/// Settings) that swaps a content view. Replaces the old standalone Meetings
/// and Settings windows.
public final class MainWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private let store: Store
    private var config: Config

    // Hooks supplied by MenuBarApp (the daemon/actions live there).
    var isPaused: () -> Bool = { false }
    var setPaused: (Bool) -> Void = { _ in }
    var writeChronicleNow: () -> Void = {}
    var learnToneNow: () -> Void = {}
    var onConfigChange: (Config) -> Void = { _ in }
    var startVoiceNote: () -> Void = {}
    var stopVoiceNote: () -> Void = {}
    var isRecordingVoiceNote: () -> Bool = { false }

    private var window: NSWindow?
    private let sidebar = NSTableView()
    private let contentContainer = ThemedView(frame: .zero)
    private var currentView: NSView?

    private lazy var meetingsSection = MasterDetailSection(
        title: "Meetings", symbol: "waveform",
        empty: "No recordings yet. Click “Record voice note” above to capture and transcribe one, or Smriti will ask before recording a call.",
        loader: { [store] in
            (try? store.listMeetings(limit: 200))?.map {
                ($0.windowTitle, $0.content)
            } ?? []
        })

    private lazy var sections: [MainSection] = [
        AskSection(store: store),
        MasterDetailSection(title: "Chronicles", symbol: "calendar",
                            empty: "No chronicles yet. Write one from Overview or the menu bar.",
                            loader: { [store] in
                                (try? store.listChronicles(limit: 200))?.map {
                                    ($0.day, $0.summary)
                                } ?? []
                            }),
        meetingsSection,
        HomeSection(store: store, owner: self),
        SettingsSection(config: config, onChange: { [weak self] c in
            self?.config = c
            self?.onConfigChange(c)
        }),
    ]

    /// Re-read the meetings list (after a voice note finishes transcribing).
    func reloadMeetings() { meetingsSection.reloadRows() }

    public init(store: Store, config: Config) {
        self.store = store
        self.config = config
        super.init()
        meetingsSection.recordControls = MasterDetailSection.RecordControls(
            enabled: MeetingWatcher.voiceNotesEnabled,
            isActive: { [weak self] in self?.isRecordingVoiceNote() ?? false },
            toggle: { [weak self] in
                guard let self else { return }
                if self.isRecordingVoiceNote() { self.stopVoiceNote() } else { self.startVoiceNote() }
            })
    }

    /// Open the window on a given section (0 = Home).
    public func show(section index: Int = 0) {
        if window == nil { build() }
        let i = max(0, min(index, sections.count - 1))
        sidebar.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        selectSection(i)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func sectionIndex(titled title: String) -> Int {
        sections.firstIndex { $0.title == title } ?? 0
    }

    private func build() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "Smriti"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 720, height: 460)
        win.center()
        // Warm, editorial light appearance across the app.
        Theme.style(window: win, background: Theme.sidebar)
        win.titlebarAppearsTransparent = true

        let root = ThemedView(frame: NSRect(x: 0, y: 0, width: 940, height: 620))
        root.fillColor = Theme.sidebar

        // Sidebar
        sidebar.style = .sourceList
        sidebar.rowSizeStyle = .medium
        sidebar.headerView = nil
        let sideCol = NSTableColumn(identifier: .init("section"))
        sideCol.width = 184
        sideCol.resizingMask = .autoresizingMask
        sidebar.addTableColumn(sideCol)
        sidebar.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.backgroundColor = Theme.sidebar
        sidebar.intercellSpacing = NSSize(width: 0, height: 3)
        let sideScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 620 - 64))
        sideScroll.documentView = sidebar
        sideScroll.hasVerticalScroller = true
        sideScroll.drawsBackground = false
        sideScroll.autoresizingMask = [.height]

        // Sidebar header: app mark + wordmark.
        let header = NSView(frame: NSRect(x: 0, y: 620 - 64, width: 200, height: 64))
        header.autoresizingMask = [.minYMargin]
        let mark = NSImageView(frame: NSRect(x: 16, y: 20, width: 22, height: 22))
        mark.image = NSApp.applicationIconImage
        mark.imageScaling = .scaleProportionallyUpOrDown
        let wordmark = NSTextField(labelWithString: "Smriti")
        wordmark.font = Theme.serif(17, .semibold)
        wordmark.textColor = Theme.ink
        wordmark.frame = NSRect(x: 46, y: 21, width: 120, height: 22)
        header.addSubview(mark)
        header.addSubview(wordmark)

        // Content
        contentContainer.frame = NSRect(x: 201, y: 0, width: 739, height: 620)
        contentContainer.autoresizingMask = [.width, .height]
        contentContainer.fillColor = Theme.surface

        let divider = NSBox(frame: NSRect(x: 200, y: 0, width: 1, height: 620))
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = Theme.border
        divider.autoresizingMask = [.height]

        root.addSubview(sideScroll)
        root.addSubview(header)
        root.addSubview(divider)
        root.addSubview(contentContainer)
        win.contentView = root
        window = win
    }

    private func selectSection(_ index: Int) {
        guard index >= 0, index < sections.count else { return }
        currentView?.removeFromSuperview()
        let section = sections[index]
        let view = section.makeView()
        view.frame = contentContainer.bounds
        view.autoresizingMask = [.width, .height]
        contentContainer.addSubview(view)
        currentView = view
        section.willAppear()
    }

    // MARK: - Sidebar table

    public func numberOfRows(in tableView: NSTableView) -> Int { sections.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let section = sections[row]
        // Plain NSView (not NSTableCellView) so the system doesn't recolor our
        // label on selection — we control colors via a custom row view.
        let cell = NSView()
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
        image.contentTintColor = Theme.inkSecondary
        image.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: section.title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = Theme.ink
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 17),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SidebarRowView()
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard sidebar.selectedRow >= 0 else { return }
        selectSection(sidebar.selectedRow)
    }
}

/// Sidebar rows with a soft, neutral rounded selection (not the system blue).
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let r = bounds.insetBy(dx: 8, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        Theme.selection.setFill()
        path.fill()
    }
}

// MARK: - Section protocol

protocol MainSection: AnyObject {
    var title: String { get }
    var symbol: String { get }
    func makeView() -> NSView
    func willAppear()
}

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

    /// Optional record bar shown above the list (used by Meetings for manual
    /// voice notes). `isActive`/`toggle` drive a single Start/Stop button.
    struct RecordControls {
        let enabled: Bool
        let isActive: () -> Bool
        let toggle: () -> Void
    }
    var recordControls: RecordControls?
    private let recordButton = NSButton()
    private let recordStatus = NSTextField(labelWithString: "")
    private var elapsedTimer: Timer?
    private var recordStartedAt: Date?
    private static let headerHeight: CGFloat = 48

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

        let textScroll = MasterDetailSection.makeTextScroll(text,
            frame: NSRect(x: 261, y: 0, width: 478, height: 620))
        textScroll.autoresizingMask = [.width, .height]

        split.addSubview(listScroll)
        split.addSubview(textScroll)
        container.addSubview(split)
        split.setPosition(260, ofDividerAt: 0)
        view = container
        return container
    }

    func willAppear() {
        reloadRows()
    }

    /// Reload the list from the loader and refresh the record button. Public so
    /// the owner can call it after an async voice note finishes transcribing.
    func reloadRows() {
        rows = loader()
        table.reloadData()
        if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            text.string = emptyMessage
        }
        updateRecordUI()
    }

    @objc private func toggleRecord() {
        guard let rc = recordControls else { return }
        if !rc.isActive() { recordStartedAt = Date() }
        rc.toggle()
        updateRecordUI()
    }

    private func updateRecordUI() {
        guard let rc = recordControls else { return }
        recordButton.isEnabled = rc.enabled
        if rc.isActive() {
            recordButton.title = "◼ Stop & save"
            recordStartedAt = recordStartedAt ?? Date()
            recordStatus.stringValue = elapsedLabel()
            if elapsedTimer == nil {
                elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.recordStatus.stringValue = self?.elapsedLabel() ?? ""
                }
            }
        } else {
            recordButton.title = "● Record voice note"
            elapsedTimer?.invalidate()
            elapsedTimer = nil
            recordStartedAt = nil
            recordStatus.stringValue = rc.enabled
                ? "Talk, then Stop — transcribed on-device and saved below."
                : "Available in the installed app (needs Microphone + Speech Recognition)."
        }
    }

    private func elapsedLabel() -> String {
        let secs = Int(Date().timeIntervalSince(recordStartedAt ?? Date()))
        return String(format: "Recording… %d:%02d — speak now, then click Stop to transcribe & save.",
                      secs / 60, secs % 60)
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
        let row = rows[table.selectedRow]
        let doc = NSMutableAttributedString()
        doc.append(MarkdownRenderer.caption(row.title))
        doc.append(MarkdownRenderer.attributed(row.body))
        text.textStorage?.setAttributedString(doc)
        text.scrollToBeginningOfDocument(nil)
    }
}

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

// MARK: - Settings

final class SettingsSection: NSObject, MainSection {
    let title = "Settings"
    let symbol = "gearshape"
    private var config: Config
    private let onChange: (Config) -> Void
    private var view: NSView?

    private let backendPopup = NSPopUpButton()
    private let providerPopup = NSPopUpButton()
    private let providerLabel = NSTextField(labelWithString: "Cloud provider")
    private let modelLabel = NSTextField(labelWithString: "Model")
    private let modelPopup = NSPopUpButton()
    private let apiKeyLabel = NSTextField(labelWithString: "API key")
    private let apiKeyField = NSSecureTextField()
    private let apiKeySaveButton = NSButton()
    private let apiKeyStatusLabel = NSTextField(labelWithString: "")
    private var apiKeyRow: NSStackView?
    private let redactCheckbox = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let loginStatusLabel = NSTextField(labelWithString: "")
    private let loginButton = NSButton()
    private let appearanceControl = NSSegmentedControl(
        labels: ["System", "Light", "Dark"], trackingMode: .selectOne, target: nil, action: nil)

    init(config: Config, onChange: @escaping (Config) -> Void) {
        self.config = config
        self.onChange = onChange
    }

    func makeView() -> NSView {
        if let view { return view }
        let heading = NSTextField(labelWithString: "Settings")
        heading.font = Theme.serif(26, .semibold)
        heading.textColor = Theme.ink

        let appearanceLabel = NSTextField(labelWithString: "Appearance")
        appearanceLabel.font = .systemFont(ofSize: 13, weight: .medium)
        appearanceLabel.textColor = Theme.ink
        appearanceControl.selectedSegment = ["system", "light", "dark"].firstIndex(of: config.appearanceMode) ?? 0
        appearanceControl.target = self
        appearanceControl.action = #selector(changedAppearance)

        let backendLabel = NSTextField(labelWithString: "Reply drafts by")
        backendLabel.font = .systemFont(ofSize: 13, weight: .medium)
        backendPopup.addItems(withTitles: [
            "Auto — best available",
            "Cloud (Groq, OpenRouter…)",
            "Ollama (local only)",
            "Claude (subscription)",
        ])
        backendPopup.target = self
        backendPopup.action = #selector(changed)

        providerLabel.font = .systemFont(ofSize: 13, weight: .medium)
        providerPopup.target = self
        providerPopup.action = #selector(changedProvider)

        modelLabel.font = .systemFont(ofSize: 13, weight: .medium)
        modelPopup.target = self
        modelPopup.action = #selector(changed)

        // API key entry — store the active provider's key in the login
        // Keychain without leaving the app.
        apiKeyLabel.font = .systemFont(ofSize: 13, weight: .medium)
        apiKeyField.placeholderString = "Paste API key (e.g. gsk_… for Groq)"
        apiKeyField.target = self
        apiKeyField.action = #selector(saveKey) // Return in the field saves
        apiKeySaveButton.title = "Save key"
        apiKeySaveButton.bezelStyle = .rounded
        apiKeySaveButton.target = self
        apiKeySaveButton.action = #selector(saveKey)
        let apiKeyRemoveButton = NSButton(
            title: "Remove", target: self, action: #selector(removeKey))
        apiKeyRemoveButton.bezelStyle = .rounded
        let keyRow = NSStackView(views: [apiKeyField, apiKeySaveButton, apiKeyRemoveButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8
        apiKeyRow = keyRow
        apiKeyStatusLabel.font = .systemFont(ofSize: 11)
        apiKeyStatusLabel.textColor = .secondaryLabelColor
        apiKeyStatusLabel.maximumNumberOfLines = 2
        apiKeyStatusLabel.preferredMaxLayoutWidth = 520

        // Privacy: redact secrets/PII before anything leaves the machine.
        let privacyHeading = NSTextField(labelWithString: "Privacy")
        privacyHeading.font = .systemFont(ofSize: 13, weight: .medium)
        privacyHeading.textColor = Theme.ink
        redactCheckbox.setButtonType(.switch)
        redactCheckbox.title = "Redact secrets & personal info before sending to any remote model"
        redactCheckbox.target = self
        redactCheckbox.action = #selector(toggledRedaction)
        redactCheckbox.state = config.redactRemoteEgress ? .on : .off
        let redactNote = NSTextField(wrappingLabelWithString:
            "Applies to cloud providers and Claude. API keys, tokens, private keys, "
            + "emails, card numbers and the like become [REDACTED_…] placeholders. "
            + "A local Ollama always receives the full text.")
        redactNote.font = .systemFont(ofSize: 11)
        redactNote.textColor = .tertiaryLabelColor
        redactNote.preferredMaxLayoutWidth = 520

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.preferredMaxLayoutWidth = 520

        let note = NSTextField(wrappingLabelWithString:
            "Chronicles, tone learning, and meeting summaries always use Claude. Memory Q&A lives in Claude Desktop via MCP.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.preferredMaxLayoutWidth = 520

        // Claude account: the CLI must be logged in for drafts/chronicles/tone.
        let cliHeading = NSTextField(labelWithString: "Claude account")
        cliHeading.font = .systemFont(ofSize: 13, weight: .medium)
        loginStatusLabel.font = .systemFont(ofSize: 11)
        loginStatusLabel.textColor = .secondaryLabelColor
        loginStatusLabel.maximumNumberOfLines = 2
        loginStatusLabel.preferredMaxLayoutWidth = 520
        loginButton.title = "Log in to Claude CLI…"
        loginButton.bezelStyle = .rounded
        loginButton.target = self
        loginButton.action = #selector(login)
        let checkButton = NSButton(title: "Check status", target: self, action: #selector(checkLogin))
        checkButton.bezelStyle = .rounded
        let loginRow = NSStackView(views: [loginButton, checkButton])
        loginRow.orientation = .horizontal
        loginRow.spacing = 8

        let stack = NSStackView(views: [
            heading,
            appearanceLabel, appearanceControl,
            backendLabel, backendPopup,
            providerLabel, providerPopup,
            apiKeyLabel, keyRow, apiKeyStatusLabel,
            modelLabel, modelPopup,
            statusLabel, note,
            privacyHeading, redactCheckbox, redactNote,
            cliHeading, loginStatusLabel, loginRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(20, after: heading)
        stack.setCustomSpacing(20, after: appearanceControl)
        stack.setCustomSpacing(16, after: backendPopup)
        stack.setCustomSpacing(12, after: apiKeyStatusLabel)
        stack.setCustomSpacing(20, after: modelPopup)
        stack.setCustomSpacing(24, after: note)
        stack.setCustomSpacing(8, after: privacyHeading)
        stack.setCustomSpacing(24, after: redactNote)
        stack.setCustomSpacing(8, after: cliHeading)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 739, height: 620))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -40),
            backendPopup.widthAnchor.constraint(equalToConstant: 300),
            providerPopup.widthAnchor.constraint(equalToConstant: 300),
            modelPopup.widthAnchor.constraint(equalToConstant: 300),
            apiKeyField.widthAnchor.constraint(equalToConstant: 220),
        ])
        view = container
        return container
    }

    func willAppear() {
        refresh()
        if ClaudeCLI.path() == nil {
            loginStatusLabel.stringValue = "⚠︎ Claude CLI not found. Install Claude Code, then log in."
            loginButton.isEnabled = false
        } else {
            loginButton.isEnabled = true
            checkLogin() // cheap (claude auth status), so run it on open
        }
    }

    @objc private func login() {
        loginStatusLabel.stringValue = "Opening Terminal — complete the login there, then click “Check status”."
        ClaudeCLI.openLoginInTerminal()
    }

    @objc private func changedAppearance() {
        config.appearanceMode = ["system", "light", "dark"][max(0, appearanceControl.selectedSegment)]
        try? config.save()
        Theme.applyAppearance(config.appearanceMode)
        onChange(config)
    }

    @objc private func checkLogin() {
        loginStatusLabel.stringValue = "Checking Claude login…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = ClaudeCLI.isLoggedIn()
            DispatchQueue.main.async {
                self?.loginStatusLabel.stringValue = ok
                    ? "✓ Claude CLI is logged in — drafting is ready."
                    : "⚠︎ Not logged in. Click “Log in to Claude CLI…”, finish in Terminal, then re-check."
            }
        }
    }

    private static let backendKeys = ["auto", "cloud", "ollama", "claude"]

    /// The cloud picker is shown for "auto" and "cloud"; the model popup
    /// switches between local (Ollama) and cloud models to match.
    private var showsCloudModels: Bool {
        config.assistBackend == "cloud"
            || (config.assistBackend == "auto"
                && CloudKeyStore.hasKey(provider: config.cloudProvider))
    }

    /// What the model popup currently lists — decided at refresh time, so a
    /// backend switch doesn't save an Ollama title into a cloud provider.
    private var modelPopupListsCloud = false

    private func refresh() {
        backendPopup.selectItem(
            at: SettingsSection.backendKeys.firstIndex(of: config.assistBackend) ?? 0)
        redactCheckbox.state = config.redactRemoteEgress ? .on : .off

        let cloudVisible = config.assistBackend == "cloud" || config.assistBackend == "auto"
        providerLabel.isHidden = !cloudVisible
        providerPopup.isHidden = !cloudVisible
        providerPopup.removeAllItems()
        providerPopup.addItems(withTitles: config.cloudProviders.keys.sorted())
        providerPopup.selectItem(withTitle: config.cloudProvider)

        // API key entry follows the provider; hidden unless a cloud lane is in
        // play and the provider actually needs a key (localhost endpoints don't).
        let provider = config.cloudProviders[config.cloudProvider]
        let needsKey = cloudVisible && !(provider?.isLocal ?? false)
        apiKeyLabel.isHidden = !needsKey
        apiKeyRow?.isHidden = !needsKey
        apiKeyStatusLabel.isHidden = !needsKey
        if needsKey {
            apiKeyLabel.stringValue = "API key for \(config.cloudProvider)"
            if let source = CloudKeyStore.source(provider: config.cloudProvider) {
                apiKeyStatusLabel.stringValue = "✓ Key in place (from \(source)). Paste a new one and Save to replace it."
            } else {
                apiKeyStatusLabel.stringValue = "No key yet — free Groq keys at console.groq.com. Paste above and Save."
            }
        }

        if showsCloudModels {
            refreshCloudModels()
        } else {
            refreshOllamaModels()
        }
    }

    private func refreshOllamaModels() {
        modelPopupListsCloud = false
        modelLabel.stringValue = "Local model"
        let models = OllamaClient.listModels()
        modelPopup.removeAllItems()
        if models.isEmpty {
            modelPopup.addItem(withTitle: config.ollamaModel)
            modelPopup.isEnabled = false
            statusLabel.stringValue = "Ollama isn't running — start the Ollama app to use local models. Falling back to Claude."
        } else {
            modelPopup.addItems(withTitles: models)
            if !models.contains(config.ollamaModel) { modelPopup.addItem(withTitle: config.ollamaModel) }
            modelPopup.selectItem(withTitle: config.ollamaModel)
            modelPopup.isEnabled = config.assistBackend != "claude"
            statusLabel.stringValue = "Ollama running with \(models.count) model(s). Drafts stay on this Mac when a local model is used."
        }
    }

    private func refreshCloudModels() {
        let providerName = config.cloudProvider
        guard let provider = config.cloudProviders[providerName] else { return }
        modelPopupListsCloud = true
        modelLabel.stringValue = "Cloud model"
        modelPopup.removeAllItems()
        modelPopup.addItem(withTitle: provider.model)
        modelPopup.isEnabled = true

        guard CloudKeyStore.hasKey(provider: providerName) || provider.isLocal else {
            statusLabel.stringValue = "No API key for \(providerName) yet. Paste one in the “API key” field above and click Save."
            return
        }
        statusLabel.stringValue = "\(providerName) key found. Drafts use \(provider.model); only the window text of the moment is sent, exclusions always apply."
        // Model list comes from the provider's /models endpoint — network, so
        // fetch off the main thread and fill in when it lands.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let key = CloudKeyStore.get(provider: providerName)
            let models = CloudLLMClient.listModels(config: provider, apiKey: key)
            DispatchQueue.main.async {
                guard let self, self.showsCloudModels,
                      self.config.cloudProvider == providerName, !models.isEmpty
                else { return }
                let current = self.config.cloudProviders[providerName]?.model ?? provider.model
                self.modelPopup.removeAllItems()
                self.modelPopup.addItems(withTitles: models)
                if !models.contains(current) { self.modelPopup.addItem(withTitle: current) }
                self.modelPopup.selectItem(withTitle: current)
            }
        }
    }

    @objc private func changedProvider() {
        if let title = providerPopup.titleOfSelectedItem { config.cloudProvider = title }
        try? config.save()
        refresh()
        onChange(config)
    }

    @objc private func changed() {
        config.assistBackend =
            SettingsSection.backendKeys[max(0, backendPopup.indexOfSelectedItem)]
        if let title = modelPopup.titleOfSelectedItem {
            if modelPopupListsCloud {
                config.cloudProviders[config.cloudProvider]?.model = title
            } else {
                config.ollamaModel = title
            }
        }
        try? config.save()
        refresh()
        onChange(config)
    }

    @objc private func saveKey() {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            apiKeyStatusLabel.stringValue = "Paste a key first, then Save."
            return
        }
        let providerName = config.cloudProvider
        if CloudKeyStore.set(key, provider: providerName) {
            apiKeyField.stringValue = "" // never keep the secret on screen
            apiKeyStatusLabel.stringValue = "✓ Saved \(providerName) key to the login Keychain."
            refresh()      // re-list models now that the key exists
            onChange(config) // re-wire backends so the cloud lane goes live
        } else {
            apiKeyStatusLabel.stringValue = "⚠︎ Couldn't save to the Keychain — try again."
        }
    }

    @objc private func removeKey() {
        let providerName = config.cloudProvider
        CloudKeyStore.remove(provider: providerName)
        apiKeyField.stringValue = ""
        // A key can also live in an env var or .env; the Keychain copy is gone
        // but note if another source still supplies one.
        if let source = CloudKeyStore.source(provider: providerName) {
            apiKeyStatusLabel.stringValue = "Removed the Keychain key. A key is still provided by \(source)."
        } else {
            apiKeyStatusLabel.stringValue = "Removed the \(providerName) key."
        }
        refresh()
        onChange(config)
    }

    @objc private func toggledRedaction() {
        config.redactRemoteEgress = (redactCheckbox.state == .on)
        try? config.save()
        onChange(config)
    }
}
