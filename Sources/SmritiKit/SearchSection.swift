import AppKit

/// A click gesture recognizer that carries an index into the results array.
private class SearchResultClick: NSClickGestureRecognizer {
    let index: Int
    init(target: AnyObject?, action: Selector?, index: Int) {
        self.index = index
        super.init(target: target, action: action)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// "Search" sidebar section: a search field at the top with live FTS5 results
/// displayed below. Each result is a clickable `SnapshotRowView`.
final class SearchSection: NSObject, MainSection, NSSearchFieldDelegate {
    let title = "Search"
    let symbol = "magnifyingglass"

    private let store: Store
    private var view: NSView?
    private let searchField = NSSearchField()
    private let resultsStack = NSStackView()
    private let resultCountLabel = NSTextField(labelWithString: "")
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let noResultsLabel = NSTextField(labelWithString: "")
    private var snapshotPanel: NSPanel?
    private let snapshotText = NSTextView()
    private var debounceTimer: Timer?
    private var currentResults: [Store.Snapshot] = []

    init(store: Store) {
        self.store = store
        super.init()
    }

    func makeView() -> NSView {
        if let view { return view }
        let W: CGFloat = 739, H: CGFloat = 620
        let container = ThemedView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        container.fillColor = Theme.surface

        let heading = NSTextField(labelWithString: "Search your memory")
        heading.font = Theme.serif(24, .semibold)
        heading.textColor = Theme.ink

        searchField.placeholderString = "Search across all captured snapshots…"
        searchField.font = Theme.body(14)
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.heightAnchor.constraint(equalToConstant: 36).isActive = true

        resultCountLabel.font = Theme.body(12)
        resultCountLabel.textColor = Theme.inkSecondary
        resultCountLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyStateLabel.stringValue = "Type to search across all your captured snapshots."
        emptyStateLabel.font = Theme.body(14)
        emptyStateLabel.textColor = Theme.inkSecondary
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        noResultsLabel.font = Theme.body(14)
        noResultsLabel.textColor = Theme.inkSecondary
        noResultsLabel.alignment = .center
        noResultsLabel.translatesAutoresizingMaskIntoConstraints = false
        noResultsLabel.isHidden = true

        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = Theme.Space.xs
        resultsStack.translatesAutoresizingMaskIntoConstraints = false

        let resultsScroll = NSScrollView(frame: .zero)
        resultsScroll.drawsBackground = false
        resultsScroll.hasVerticalScroller = true
        resultsScroll.documentView = resultsStack
        resultsScroll.autoresizingMask = [.width, .height]
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false
        resultsScroll.borderType = .noBorder

        let mainStack = NSStackView(views: [
            heading, searchField, resultCountLabel, emptyStateLabel, noResultsLabel, resultsScroll
        ])
        mainStack.orientation = .vertical
        mainStack.alignment = .width
        mainStack.spacing = Theme.Space.sm
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.setCustomSpacing(Theme.Space.md, after: heading)
        mainStack.setCustomSpacing(Theme.Space.sm, after: searchField)

        container.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Space.xl),
            mainStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Space.xl),
            mainStack.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Space.lg),
        ])

        view = container
        return container
    }

    func willAppear() {
        DispatchQueue.main.async { [weak self] in
            self?.searchField.window?.makeFirstResponder(self?.searchField)
        }
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.executeSearch()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            debounceTimer?.invalidate()
            executeSearch()
            return true
        }
        return false
    }

    // MARK: - Search

    private func executeSearch() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        resultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if query.isEmpty {
            emptyStateLabel.isHidden = false
            noResultsLabel.isHidden = true
            resultCountLabel.stringValue = ""
            currentResults = []
            return
        }

        emptyStateLabel.isHidden = true
        let results = (try? store.search(query, limit: 50)) ?? []
        currentResults = results

        if results.isEmpty {
            noResultsLabel.stringValue = "No results for \"\(query)\". Try different terms."
            noResultsLabel.isHidden = false
            resultCountLabel.stringValue = ""
            return
        }

        noResultsLabel.isHidden = true
        resultCountLabel.stringValue = "\(results.count) result\(results.count == 1 ? "" : "s") for \"\(query)\""

        for (index, snap) in results.enumerated() {
            let row = SnapshotRowView(snapshot: snap, showTimestamp: true)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.wantsLayer = true
            row.layer?.cornerRadius = Theme.Radius.card
            let click = SearchResultClick(target: self, action: #selector(resultClicked(_:)), index: index)
            row.addGestureRecognizer(click)
            resultsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 680).isActive = true
        }
    }

    // MARK: - Snapshot viewer

    @objc private func resultClicked(_ sender: SearchResultClick) {
        guard sender.index < currentResults.count else { return }
        openSnapshot(currentResults[sender.index])
    }

    private func openSnapshot(_ snap: Store.Snapshot) {
        let urlLine = snap.url.isEmpty ? "" : "\(snap.url)\n"
        let body = "\(snap.app) — \(snap.windowTitle)\n\(snap.lastSeenAt)\n\(urlLine)\(String(repeating: "─", count: 40))\n\n\(snap.content)"

        let panel = snapshotPanel ?? makeSnapshotPanel()
        snapshotPanel = panel
        snapshotText.string = body
        snapshotText.scrollToBeginningOfDocument(nil)
        panel.title = "Snapshot #\(snap.id)"
        panel.makeKeyAndOrderFront(nil)
        panel.center()
    }

    private func makeSnapshotPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        Theme.style(window: panel, background: Theme.surface)
        let scroll = MasterDetailSection.makeTextScroll(
            snapshotText, frame: NSRect(x: 0, y: 0, width: 560, height: 460))
        scroll.autoresizingMask = [.width, .height]
        snapshotText.isEditable = false
        snapshotText.drawsBackground = false
        snapshotText.textColor = Theme.ink
        panel.contentView = scroll
        return panel
    }
}
