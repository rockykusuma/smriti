import AppKit

/// A reusable view that renders a single `Store.Snapshot` as a compact card
/// with app icon, window title, content preview, and optional timestamp.
/// Used by TodaySection, SearchSection, and ChronicleTimelineSection.
final class SnapshotRowView: NSView {

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")

    init(snapshot: Store.Snapshot, showTimestamp: Bool = true) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.card
        layer?.cornerCurve = .continuous
        applyColors()

        iconView.image = appIcon(for: snapshot.bundleId)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.stringValue = snapshot.windowTitle
        titleLabel.font = Theme.body(13, .semibold)
        titleLabel.textColor = Theme.ink
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let preview = String(snapshot.content
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(120))
        previewLabel.stringValue = preview
        previewLabel.font = Theme.body(12)
        previewLabel.textColor = Theme.inkSecondary
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1
        previewLabel.translatesAutoresizingMaskIntoConstraints = false

        if showTimestamp {
            let ts = String(snapshot.lastSeenAt.prefix(16))
            metaLabel.stringValue = "\(ts)  ·  \(snapshot.app)"
        } else {
            metaLabel.stringValue = snapshot.app
        }
        metaLabel.font = Theme.body(10)
        metaLabel.textColor = Theme.inkTertiary
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        let textCol = NSStackView(views: [titleLabel, previewLabel, metaLabel])
        textCol.orientation = .vertical
        textCol.alignment = .leading
        textCol.spacing = 2
        textCol.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textCol)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            textCol.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textCol.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            textCol.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            textCol.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.backgroundColor = Theme.card.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = Theme.border.cgColor
        }
    }

    private func appIcon(for bundleId: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
