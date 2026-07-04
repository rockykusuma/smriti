import AppKit

/// Smriti's visual design system — a calm, warm, editorial aesthetic:
/// ivory surfaces, warm near-black ink, tracked-out gray labels, a serif
/// display face for headlines, and a single violet brand accent (tied to the
/// app icon). Modeled on the restraint of well-designed memory apps.
enum Theme {

    // MARK: - Color

    static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
    }

    /// Main content background — warm off-white.
    static let surface     = rgb(252, 251, 247)
    /// Sidebar / secondary surface — warm light gray.
    static let sidebar     = rgb(244, 242, 236)
    /// Cards, composer, message bubbles — soft cream.
    static let card        = rgb(247, 244, 237)
    /// Hairline borders.
    static let border      = rgb(230, 226, 216)
    /// Selected/hover fill.
    static let selection   = rgb(236, 233, 224)

    static let ink         = rgb(30, 28, 24)     // primary text
    static let inkSecondary = rgb(110, 106, 96)  // secondary text
    static let inkTertiary = rgb(154, 150, 139)  // labels, captions

    static let accent      = rgb(109, 40, 217)   // violet — primary actions, links
    static let accentSoft  = rgb(124, 58, 237)
    static let statusOn    = rgb(79, 169, 127)   // capturing
    static let statusOff   = rgb(214, 137, 46)   // paused

    // MARK: - Metrics

    enum Radius { static let card: CGFloat = 14; static let control: CGFloat = 9; static let pill: CGFloat = 999 }
    enum Space  { static let xs: CGFloat = 6; static let sm: CGFloat = 10; static let md: CGFloat = 16; static let lg: CGFloat = 24; static let xl: CGFloat = 40 }

    // MARK: - Type

    /// Serif display face (New York), used for headlines/empty-state prompts.
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

    /// A tracked-out, uppercase gray section label (e.g. "CAPTURING", "TODAY").
    static func label(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: inkTertiary,
            .kern: 1.4,
        ])
    }

    // MARK: - Helpers

    /// A rounded, filled card view with a hairline border.
    static func makeCard(fill: NSColor = card, bordered: Bool = true,
                         radius: CGFloat = Radius.card) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = fill.cgColor
        v.layer?.cornerRadius = radius
        v.layer?.cornerCurve = .continuous
        if bordered {
            v.layer?.borderWidth = 1
            v.layer?.borderColor = border.cgColor
        }
        return v
    }

    /// Apply the warm light appearance + surface background to a window.
    static func style(window: NSWindow, background: NSColor = surface) {
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = background
    }
}
