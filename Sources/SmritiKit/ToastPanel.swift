import AppKit

/// A borderless notification panel that appears below the menu bar
/// for background action feedback (e.g., "Chronicle written").
final class ToastPanel {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var dismissWork: DispatchWorkItem?

    /// Show a short-lived toast just below the menu bar. Safe from any thread.
    func show(_ message: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.show(message) }
            return
        }
        ensurePanel()
        guard let panel else { return }
        label.stringValue = message
        label.sizeToFit()
        let width = min(max(label.frame.width + 28, 140), 520)
        let height: CGFloat = 34
        panel.setContentSize(NSSize(width: width, height: height))
        label.frame = NSRect(x: 14, y: 8, width: width - 28, height: 18)
        if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.midX - width / 2, y: vf.maxY - height - 8))
        }
        panel.orderFrontRegardless()

        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 34),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: p.contentRect(forFrameRect: p.frame))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
        effect.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        effect.addSubview(label)
        p.contentView = effect
        panel = p
    }
}
