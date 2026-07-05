import AppKit

/// A live scrolling level meter: keeps a short rolling history of input levels
/// (0...1) and draws them as rounded vertical bars, newest on the right —
/// giving a "your voice is being heard" waveform while a voice note records.
final class LevelMeterView: NSView {

    private var samples: [CGFloat]
    private let capacity: Int
    var barColor: NSColor = .systemRed

    init(frame: NSRect, capacity: Int = 56) {
        self.capacity = capacity
        self.samples = Array(repeating: 0, count: capacity)
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Push a new level (0...1), dropping the oldest, and redraw.
    func push(_ level: CGFloat) {
        samples.removeFirst()
        samples.append(max(0, min(1, level)))
        needsDisplay = true
    }

    /// Clear the history back to flat.
    func reset() {
        samples = Array(repeating: 0, count: capacity)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0, capacity > 0 else { return }
        let gap: CGFloat = 3
        let barW = max(1, (w - CGFloat(capacity - 1) * gap) / CGFloat(capacity))
        let mid = h / 2
        barColor.setFill()
        for (i, sample) in samples.enumerated() {
            let x = CGFloat(i) * (barW + gap)
            let barH = max(3, sample * h)          // floor so silence still reads as a line
            let rect = NSRect(x: x, y: mid - barH / 2, width: barW, height: barH)
            NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}
