import AppKit
import Foundation

/// The main Smriti window: a sidebar (Ask, Today, Search, Chronicles,
/// Meetings, Overview, Settings) that swaps a content view.
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
    var voiceNoteLevel: () -> Float = { 0 }

    private var window: NSWindow?
    private let sidebar = NSTableView()
    private let contentContainer = ThemedView(frame: .zero)
    private var currentView: NSView?

    /// Snapshot cache backing the Meetings list — keeps the detail provider
    /// index-aligned with the loader's (title, body) rows.
    private var meetingSnapshots: [Store.Snapshot] = []
    private lazy var meetingDetailView = MeetingDetailView(
        store: store,
        onItemsChanged: { [weak self] in self?.meetingsSection.reloadBadge() })

    private lazy var meetingsList = MasterDetailSection(
        title: "Meetings", symbol: "waveform",
        empty: "No recordings yet. Click “Record voice note” above to capture and transcribe one, or Smriti will ask before recording a call.",
        loader: { [weak self, store] in
            let snaps = (try? store.listMeetings(limit: 200)) ?? []
            self?.meetingSnapshots = snaps
            return snaps.map { ($0.windowTitle, $0.content) }
        })

    private lazy var meetingsSection = MeetingsSection(
        store: store, list: meetingsList,
        rowForSnapshot: { [weak self] id in
            self?.meetingSnapshots.firstIndex { $0.id == id }
        })

    private lazy var todaySection = TodaySection(store: store)

    private lazy var sections: [MainSection] = [
        AskSection(store: store),
        todaySection,
        SearchSection(store: store),
        ChronicleTimelineSection(store: store),
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
        todaySection.writeChronicleNow = { [weak self] in self?.writeChronicleNow() }
        meetingsList.recordControls = MasterDetailSection.RecordControls(
            enabled: MeetingWatcher.voiceNotesEnabled,
            isActive: { [weak self] in self?.isRecordingVoiceNote() ?? false },
            toggle: { [weak self] in
                guard let self else { return }
                if self.isRecordingVoiceNote() { self.stopVoiceNote() } else { self.startVoiceNote() }
            },
            level: { [weak self] in self?.voiceNoteLevel() ?? 0 })
        meetingsList.detailProvider = { [weak self] index in
            guard let self, index >= 0, index < self.meetingSnapshots.count
            else { return nil }
            self.meetingDetailView.show(snapshot: self.meetingSnapshots[index])
            return self.meetingDetailView
        }
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
        meetingDetailView.stopPlayback() // leaving/re-entering a pane

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

