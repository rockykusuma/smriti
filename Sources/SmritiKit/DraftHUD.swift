import AppKit

/// A compact "Smriti drafting…" pill shown right where text will appear,
/// so the feedback is at the cursor rather than off in a corner.
final class DraftHUD {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var dotsTimer: Timer?
    private var dotPhase = 0

    func show(anchor: CGRect?) {
        ensurePanel()
        positionHUD(anchor: anchor)
        dotPhase = 0
        updateLabel()
        panel?.orderFrontRegardless()
        dotsTimer?.invalidate()
        dotsTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.dotPhase = (self.dotPhase + 1) % 4
            self.updateLabel()
        }
    }

    func hide() {
        dotsTimer?.invalidate()
        dotsTimer = nil
        panel?.orderOut(nil)
    }

    private func updateLabel() {
        let dots = String(repeating: ".", count: dotPhase)
            + String(repeating: " ", count: 3 - dotPhase)
        label.stringValue = "🧠  Smriti drafting\(dots)  ⎋ esc"
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 196, height: 30),
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
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.frame = NSRect(x: 10, y: 6, width: 176, height: 18)
        effect.addSubview(label)
        p.contentView = effect
        panel = p
    }

    /// Place the pill just below the caret. AX gives a top-left-origin rect;
    /// flip it into Cocoa's bottom-left space, fall back to the mouse, and
    /// clamp onto the screen it lands on.
    private func positionHUD(anchor: CGRect?) {
        guard let panel else { return }
        let size = panel.frame.size
        var origin: NSPoint
        if let ax = anchor {
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let topEdgeCocoaY = primaryH - ax.origin.y
            origin = NSPoint(x: ax.origin.x, y: topEdgeCocoaY + 4)
        } else {
            let m = NSEvent.mouseLocation
            origin = NSPoint(x: m.x + 12, y: m.y + 10)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
            origin.y = min(max(origin.y, vf.minY + 4), vf.maxY - size.height - 4)
        }
        panel.setFrameOrigin(origin)
    }
}
