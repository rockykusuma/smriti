import AppKit

/// Smriti's visual design system — a calm "Sage" aesthetic (soft surfaces, a
/// natural forest-green accent) that follows the system light/dark setting.
/// Colors are dynamic NSColors; the ThemedView / ThemedButton helpers repaint
/// their layers when the effective appearance changes.
enum Theme {

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF)/255,
                green: CGFloat((hex >> 8) & 0xFF)/255,
                blue: CGFloat(hex & 0xFF)/255, alpha: 1)
    }

    /// A color that resolves to `light` or `dark` based on appearance.
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }

    // MARK: - Palette (light, dark)

    static let surface      = dyn(0xFBFBF7, 0x16181A)
    static let sidebar      = dyn(0xEDF1E9, 0x1E2124)
    static let card         = dyn(0xF3F6EE, 0x24282B)
    static let border       = dyn(0xDDE3D3, 0x343A3E)
    static let selection    = dyn(0xE0E7D8, 0x2C3134)

    static let ink          = dyn(0x1F2620, 0xE9EDE7)
    static let inkSecondary = dyn(0x5F6A5A, 0xA6AFA6)
    static let inkTertiary  = dyn(0x8A9384, 0x7C857C)

    static let accent       = dyn(0x3E7C55, 0x6DBF8E)
    static let statusOn     = dyn(0x3E7C55, 0x6DBF8E)
    static let statusOff     = dyn(0xB4791F, 0xE0A94A)

    // MARK: - Metrics

    enum Radius { static let card: CGFloat = 14; static let control: CGFloat = 9 }
    enum Space  { static let xs: CGFloat = 6; static let sm: CGFloat = 10; static let md: CGFloat = 16; static let lg: CGFloat = 24; static let xl: CGFloat = 40 }

    // MARK: - Type

    static func serif(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.serif) {
            return NSFont(descriptor: d, size: size) ?? base
        }
        return base
    }
    static func body(_ size: CGFloat = 14, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
    static func label(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: inkTertiary, .kern: 1.4,
        ])
    }

    // MARK: - Helpers

    static func makeCard(fill: NSColor = card, bordered: Bool = true,
                         radius: CGFloat = Radius.card) -> ThemedView {
        let v = ThemedView(frame: .zero)
        v.corner = radius
        v.fillColor = fill
        v.strokeColor = bordered ? border : nil
        return v
    }

    /// Follow the system appearance (no forced light/dark) with a themed bg.
    static func style(window: NSWindow, background: NSColor = surface) {
        window.backgroundColor = background
    }

    /// Force the whole app's appearance: "light", "dark", or "system" (follow
    /// macOS). Applied app-wide so every window and panel flips together.
    static func applyAppearance(_ mode: String) {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

/// A layer-backed view whose fill/border track dynamic colors across
/// light/dark appearance changes.
final class ThemedView: NSView {
    var fillColor: NSColor? { didSet { apply() } }
    var strokeColor: NSColor? { didSet { apply() } }
    var corner: CGFloat = 0 { didSet { apply() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); apply()
    }
    private func apply() {
        wantsLayer = true
        layer?.cornerRadius = corner
        layer?.borderWidth = strokeColor == nil ? 0 : 1
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.backgroundColor = fillColor?.cgColor
            layer?.borderColor = strokeColor?.cgColor
        }
    }
}

/// A button with a themed, dynamic fill/border (and optional circular shape).
final class ThemedButton: NSButton {
    var fillColor: NSColor? { didSet { apply() } }
    var strokeColor: NSColor? { didSet { apply() } }
    var corner: CGFloat = 0 { didSet { apply() } }
    var circular = false

    override func layout() {
        super.layout()
        if circular { corner = bounds.height / 2 }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); apply()
    }
    private func apply() {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = corner
        layer?.borderWidth = strokeColor == nil ? 0 : 1
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.backgroundColor = fillColor?.cgColor
            layer?.borderColor = strokeColor?.cgColor
        }
    }
}
