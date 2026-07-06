import AppKit

/// The Meetings pane: a "Meetings | Action items" segmented control that
/// swaps between the recordings master-detail list and the action-items hub.
/// Wraps the existing MasterDetailSection untouched.
final class MeetingsSection: NSObject, MainSection {

    let title = "Meetings"
    let symbol = "waveform"

    private let store: Store
    /// The recordings list (record controls + detail provider live on it).
    let list: MasterDetailSection
    /// Maps a snapshot id to its current list row (owned by MainWindow,
    /// which holds the snapshot cache).
    private let rowForSnapshot: (Int64) -> Int?

    private lazy var hub = ActionItemsView(
        store: store,
        jumpToMeeting: { [weak self] id in self?.showMeetings(selecting: id) },
        onCountChanged: { [weak self] in self?.reloadBadge() })

    private let segment = NSSegmentedControl(
        labels: ["Meetings", "Action items"], trackingMode: .selectOne,
        target: nil, action: nil)
    private var view: NSView?
    private let container = NSView()
    private var didBackfill = false
    private static let headerHeight: CGFloat = 44

    init(store: Store, list: MasterDetailSection,
         rowForSnapshot: @escaping (Int64) -> Int?) {
        self.store = store
        self.list = list
        self.rowForSnapshot = rowForSnapshot
    }

    func makeView() -> NSView {
        if let view { return view }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 739, height: 620))

        segment.target = self
        segment.action = #selector(segmentChanged)
        segment.selectedSegment = 0
        segment.sizeToFit()
        segment.frame.origin = NSPoint(x: 12, y: 620 - MeetingsSection.headerHeight + 8)
        segment.autoresizingMask = [.minYMargin]
        root.addSubview(segment)

        container.frame = NSRect(x: 0, y: 0, width: 739,
                                 height: 620 - MeetingsSection.headerHeight)
        container.autoresizingMask = [.width, .height]
        root.addSubview(container)

        setContent(list.makeView())
        view = root
        return root
    }

    func willAppear() {
        if segment.selectedSegment == 1 { hub.refresh() } else { list.willAppear() }
        backfillOnce()
        reloadBadge()
    }

    /// Re-read both the list and (when visible) the hub — the owner calls
    /// this after a voice note finishes transcribing.
    func reloadRows() {
        list.reloadRows()
        if segment.selectedSegment == 1 { hub.refresh() }
        reloadBadge()
    }

    /// Refresh the open-item count on the segment label.
    func reloadBadge() {
        let n = (try? store.openActionItemCount()) ?? 0
        segment.setLabel(n > 0 ? "Action items · \(n)" : "Action items",
                         forSegment: 1)
        segment.sizeToFit()
    }

    /// Jump from the hub to a specific meeting's detail.
    func showMeetings(selecting snapshotId: Int64) {
        segment.selectedSegment = 0
        setContent(list.makeView())
        list.reloadRows()
        if let row = rowForSnapshot(snapshotId) { list.selectRow(row) }
    }

    @objc private func segmentChanged() {
        if segment.selectedSegment == 1 {
            setContent(hub)
            hub.refresh()
        } else {
            setContent(list.makeView())
            list.reloadRows()
        }
        reloadBadge()
    }

    private func setContent(_ v: NSView) {
        guard v.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)
    }

    /// Parse action items out of meetings recorded before extraction
    /// existed. One pass, off the main thread, badge refreshed after.
    private func backfillOnce() {
        guard !didBackfill else { return }
        didBackfill = true
        DispatchQueue.global(qos: .utility).async { [store] in
            ActionItems.backfill(store: store)
            DispatchQueue.main.async { [weak self] in
                self?.reloadBadge()
                if self?.segment.selectedSegment == 1 { self?.hub.refresh() }
            }
        }
    }
}
