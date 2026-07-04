import AppKit
import CoreGraphics
import Foundation

// Renders the Smriti app icon: a "neural spark" glyph on a premium gradient
// squircle, at 1024px. Pure CoreGraphics so it runs headless.

let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("ctx") }

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

let side = CGFloat(S)
let margin: CGFloat = 96
let rect = CGRect(x: margin, y: margin, width: side - 2*margin, height: side - 2*margin)
let radius = rect.width * 0.2247
let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Background gradient (indigo -> violet -> warm rose), diagonal.
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [
    color(67, 56, 202),    // indigo
    color(124, 58, 237),   // violet
    color(219, 39, 119),   // warm rose
] as CFArray, locations: [0.0, 0.55, 1.0])!
ctx.drawLinearGradient(bg,
    start: CGPoint(x: rect.minX, y: rect.maxY),
    end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
// Soft top-left sheen for depth.
let sheen = CGGradient(colorsSpace: cs, colors: [
    CGColor(gray: 1, alpha: 0.30), CGColor(gray: 1, alpha: 0.0),
] as CFArray, locations: [0, 1])!
let sc = CGPoint(x: rect.minX + rect.width*0.30, y: rect.maxY - rect.height*0.26)
ctx.drawRadialGradient(sheen, startCenter: sc, startRadius: 0,
    endCenter: sc, endRadius: rect.width*0.62, options: [])
ctx.restoreGState()

// Glyph: a firing neuron / memory spark — a bright core with organic curved
// dendrites fanning out to satellite nodes, a few of them forking.
let cx = rect.midX, cy = rect.midY
let R = rect.width
let core = CGPoint(x: cx, y: cy)
let coreR: CGFloat = 66

func dot(_ p: CGPoint, _ r: CGFloat, glow: CGFloat = 22) {
    ctx.setShadow(offset: .zero, blur: glow, color: CGColor(gray: 1, alpha: 0.5))
    ctx.setFillColor(CGColor.white)
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2*r, height: 2*r))
    ctx.setShadow(offset: .zero, blur: 0, color: CGColor(gray: 0, alpha: 0))
}

func polar(_ deg: CGFloat, _ frac: CGFloat) -> CGPoint {
    let a = deg * .pi / 180
    return CGPoint(x: cx + cos(a) * frac * R, y: cy + sin(a) * frac * R)
}

// Six dendrites: (angle°, length frac, node radius, fork?)
let dendrites: [(CGFloat, CGFloat, CGFloat, Bool)] = [
    (92,  0.315, 30, true),
    (150, 0.300, 27, false),
    (212, 0.320, 26, true),
    (270, 0.290, 31, false),
    (330, 0.305, 27, true),
    (33,  0.300, 26, false),
]

ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
ctx.setLineWidth(16)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

var tips: [(CGPoint, CGFloat, CGFloat, Bool)] = []  // point, radius, angle, fork
for (deg, frac, nr, fork) in dendrites {
    let tip = polar(deg, frac)
    let a = deg * .pi / 180
    // Curved dendrite: control point offset perpendicular for an organic bow.
    let mid = CGPoint(x: (core.x + tip.x)/2, y: (core.y + tip.y)/2)
    let perp = CGPoint(x: -sin(a), y: cos(a))
    let bow: CGFloat = 0.05 * R
    let ctrl = CGPoint(x: mid.x + perp.x*bow, y: mid.y + perp.y*bow)
    ctx.move(to: core)
    ctx.addQuadCurve(to: tip, control: ctrl)
    ctx.strokePath()
    tips.append((tip, nr, deg, fork))
}

// Terminal forks on some dendrites (little branch → tiny node).
ctx.setLineWidth(11)
var terminals: [(CGPoint, CGFloat)] = []
for (tip, _, deg, fork) in tips where fork {
    for off in [CGFloat(28), -28] {
        let end = CGPoint(
            x: tip.x + cos((deg+off) * .pi/180) * 0.085 * R,
            y: tip.y + sin((deg+off) * .pi/180) * 0.085 * R)
        ctx.move(to: tip); ctx.addLine(to: end); ctx.strokePath()
        terminals.append((end, 13))
    }
}

// Draw nodes on top of the connections.
for (t, r) in terminals { dot(t, r, glow: 14) }
for (tip, nr, _, _) in tips { dot(tip, nr) }
dot(core, coreR, glow: 54)

guard let image = ctx.makeImage() else { fatalError("image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
