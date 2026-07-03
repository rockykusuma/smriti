import AppKit

/// A simple browser window for recorded meetings: list on the left,
/// summary + transcript on the right. Opened from the menu bar.
final class MeetingsBrowser: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private let store: Store
    private var window: NSWindow?
    private var meetings: [Store.Snapshot] = []
    private let table = NSTableView()
    private let text = NSTextView()

    init(store: Store) {
        self.store = store
        super.init()
    }

    func show() {
        meetings = (try? store.listMeetings(limit: 200)) ?? []
        if window == nil { build() }
        table.reloadData()
        if !meetings.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            text.string = "No recorded meetings yet.\n\nWhen a call starts, Smriti asks for permission to record. Approved calls are transcribed on-device and appear here."
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "Smriti — Meetings"
        win.isReleasedWhenClosed = false
        win.center()

        let split = NSSplitView(frame: win.contentLayoutRect)
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]

        // Left: meeting list
        let column = NSTableColumn(identifier: .init("meeting"))
        column.title = "Meetings"
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.rowHeight = 40
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.setFrameSize(NSSize(width: 260, height: 520))

        // Right: transcript
        text.isEditable = false
        text.font = .systemFont(ofSize: 13)
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.autoresizingMask = [.width]
        let textScroll = NSScrollView()
        textScroll.documentView = text
        textScroll.hasVerticalScroller = true

        split.addArrangedSubview(listScroll)
        split.addArrangedSubview(textScroll)
        split.setPosition(260, ofDividerAt: 0)
        win.contentView = split
        window = win
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { meetings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let meeting = meetings[row]
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: meeting.windowTitle)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, table.selectedRow < meetings.count else { return }
        let meeting = meetings[table.selectedRow]
        text.string = "\(meeting.windowTitle)\n\(String(repeating: "─", count: 40))\n\n\(meeting.content)"
        text.scrollToBeginningOfDocument(nil)
    }
}
