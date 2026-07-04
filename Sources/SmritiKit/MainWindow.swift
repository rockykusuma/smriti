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

    private var window: NSWindow?
    private let sidebar = NSTableView()
    private let contentContainer = NSView()
    private var currentView: NSView?

    private lazy var sections: [MainSection] = [
        HomeSection(store: store, owner: self),
        AskSection(store: store),
        MasterDetailSection(title: "Meetings", symbol: "waveform",
                            empty: "No recorded meetings yet. When a call starts, Smriti asks before recording.",
                            loader: { [store] in
                                (try? store.listMeetings(limit: 200))?.map {
                                    ($0.windowTitle, $0.content)
                                } ?? []
                            }),
        MasterDetailSection(title: "Chronicles", symbol: "calendar",
                            empty: "No chronicles yet. Write one from Home or the menu bar.",
                            loader: { [store] in
                                (try? store.listChronicles(limit: 200))?.map {
                                    ($0.day, $0.summary)
                                } ?? []
                            }),
        SettingsSection(config: config, onChange: { [weak self] c in
            self?.config = c
            self?.onConfigChange(c)
        }),
    ]

    public init(store: Store, config: Config) {
        self.store = store
        self.config = config
        super.init()
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

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 940, height: 620))

        // Sidebar
        sidebar.style = .sourceList
        sidebar.rowSizeStyle = .medium
        sidebar.headerView = nil
        sidebar.addTableColumn(NSTableColumn(identifier: .init("section")))
        sidebar.dataSource = self
        sidebar.delegate = self
        // .style = .sourceList already provides the source-list selection look;
        // the old selectionHighlightStyle = .sourceList is deprecated.
        let sideScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 620))
        sideScroll.documentView = sidebar
        sideScroll.hasVerticalScroller = true
        sideScroll.drawsBackground = false
        sideScroll.autoresizingMask = [.height]

        // Content
        contentContainer.frame = NSRect(x: 201, y: 0, width: 739, height: 620)
        contentContainer.autoresizingMask = [.width, .height]

        let divider = NSBox(frame: NSRect(x: 200, y: 0, width: 1, height: 620))
        divider.boxType = .separator
        divider.autoresizingMask = [.height]

        root.addSubview(sideScroll)
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
        let cell = NSTableCellView()
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
        image.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: section.title)
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard sidebar.selectedRow >= 0 else { return }
        selectSection(sidebar.selectedRow)
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

    init(title: String, symbol: String, empty: String, loader: @escaping () -> [(String, String)]) {
        self.title = title
        self.symbol = symbol
        self.emptyMessage = empty
        self.loader = loader
    }

    func makeView() -> NSView {
        if let view { return view }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 739, height: 620))

        let split = NSSplitView(frame: container.bounds)
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
        let listScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 620))
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
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
        rows = loader()
        table.reloadData()
        if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            text.string = emptyMessage
        }
    }

    static func makeTextScroll(_ text: NSTextView, frame: NSRect) -> NSScrollView {
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        text.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
        text.isEditable = false
        text.isRichText = true
        text.font = .systemFont(ofSize: 13)
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
    let title = "Home"
    let symbol = "house"
    private let store: Store
    private weak var owner: MainWindow?
    private var view: NSView?

    private let statusLabel = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()

    init(store: Store, owner: MainWindow) {
        self.store = store
        self.owner = owner
    }

    func makeView() -> NSView {
        if let view { return view }
        let heading = NSTextField(labelWithString: "Smriti")
        heading.font = .systemFont(ofSize: 30, weight: .bold)
        let subtitle = NSTextField(labelWithString: "A local memory for your Mac.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        statsLabel.font = .systemFont(ofSize: 13)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.maximumNumberOfLines = 5
        statsLabel.lineBreakMode = .byWordWrapping
        statsLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        pauseButton.bezelStyle = .rounded
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        let chronicleBtn = NSButton(title: "Write today's chronicle", target: self, action: #selector(writeChronicle))
        chronicleBtn.bezelStyle = .rounded
        let toneBtn = NSButton(title: "Learn my writing tone", target: self, action: #selector(learnTone))
        toneBtn.bezelStyle = .rounded

        let buttons = NSStackView(views: [pauseButton, chronicleBtn, toneBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [heading, subtitle, statusLabel, statsLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(24, after: statsLabel)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 739, height: 620))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -40),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
        ])
        view = container
        return container
    }

    func willAppear() { refresh() }

    private func refresh() {
        let paused = owner?.isPaused() ?? false
        statusLabel.stringValue = paused ? "● Paused" : "● Capturing"
        statusLabel.textColor = paused ? .systemOrange : .systemGreen
        pauseButton.title = paused ? "Resume capture" : "Pause capture"
        if let s = try? store.stats() {
            let today = (try? store.countForDay(Chronicler.dayString())) ?? 0
            statsLabel.stringValue = """
            Today: \(today) snapshots
            Total: \(s.snapshotCount) snapshots across \(s.distinctApps) apps
            Oldest: \(s.oldest ?? "—")
            Newest: \(s.newest ?? "—")
            """
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
    private let modelPopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let loginStatusLabel = NSTextField(labelWithString: "")
    private let loginButton = NSButton()

    init(config: Config, onChange: @escaping (Config) -> Void) {
        self.config = config
        self.onChange = onChange
    }

    func makeView() -> NSView {
        if let view { return view }
        let heading = NSTextField(labelWithString: "Settings")
        heading.font = .systemFont(ofSize: 24, weight: .bold)

        let backendLabel = NSTextField(labelWithString: "Reply drafts by")
        backendLabel.font = .systemFont(ofSize: 13, weight: .medium)
        backendPopup.addItems(withTitles: [
            "Auto — local when available", "Ollama (local only)", "Claude (subscription)",
        ])
        backendPopup.target = self
        backendPopup.action = #selector(changed)

        let modelLabel = NSTextField(labelWithString: "Local model")
        modelLabel.font = .systemFont(ofSize: 13, weight: .medium)
        modelPopup.target = self
        modelPopup.action = #selector(changed)

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
            backendLabel, backendPopup,
            modelLabel, modelPopup,
            statusLabel, note,
            cliHeading, loginStatusLabel, loginRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(20, after: heading)
        stack.setCustomSpacing(16, after: backendPopup)
        stack.setCustomSpacing(20, after: modelPopup)
        stack.setCustomSpacing(24, after: note)
        stack.setCustomSpacing(8, after: cliHeading)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 739, height: 620))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 40),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -40),
            backendPopup.widthAnchor.constraint(equalToConstant: 300),
            modelPopup.widthAnchor.constraint(equalToConstant: 300),
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

    private func refresh() {
        switch config.assistBackend {
        case "ollama": backendPopup.selectItem(at: 1)
        case "claude": backendPopup.selectItem(at: 2)
        default: backendPopup.selectItem(at: 0)
        }
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

    @objc private func changed() {
        config.assistBackend = ["auto", "ollama", "claude"][max(0, backendPopup.indexOfSelectedItem)]
        if let title = modelPopup.titleOfSelectedItem { config.ollamaModel = title }
        try? config.save()
        refresh()
        onChange(config)
    }
}
