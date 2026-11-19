// Renders the app icon: an abstract driven trail ending in an arrowhead on a deep blue gradient.
// Usage: swift scripts/make-icon.swift [output.png]
// Writes Spur/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png by default.
import AppKit
import CoreGraphics
import Foundation

let size = 1024
let defaultOut = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Spur/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
let out = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : defaultOut

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("no context") }

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let s = CGFloat(size)

// Background: deep blue, diagonal, darker at the bottom left.
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x0B1A33), rgb(0x0E3A78), rgb(0x1C69D4)] as CFArray,
                    locations: [0, 0.6, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: s, y: s), options: [])

// Faint concentric rings: a calm instrument feel.
ctx.setLineWidth(2)
for (i, r) in [0.30, 0.42, 0.54].enumerated() {
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.05 - CGFloat(i) * 0.012))
    ctx.strokeEllipse(in: CGRect(x: s / 2 - s * r, y: s / 2 - s * r, width: s * r * 2, height: s * r * 2))
}

// The trail: a smooth S curve from bottom left to upper right (CG origin is bottom left).
let trail = CGMutablePath()
let p0 = CGPoint(x: s * 0.18, y: s * 0.20)
trail.move(to: p0)
trail.addCurve(to: CGPoint(x: s * 0.50, y: s * 0.46),
               control1: CGPoint(x: s * 0.40, y: s * 0.16),
               control2: CGPoint(x: s * 0.34, y: s * 0.44))
let tip = CGPoint(x: s * 0.74, y: s * 0.74)
let c2 = CGPoint(x: s * 0.62, y: s * 0.52)
trail.addCurve(to: tip, control1: CGPoint(x: s * 0.62, y: s * 0.48), control2: c2)

ctx.setLineCap(.round)
ctx.setLineJoin(.round)
// Underglow.
ctx.addPath(trail)
ctx.setStrokeColor(rgb(0x6FA8FF, 0.28))
ctx.setLineWidth(s * 0.085)
ctx.strokePath()
// Core line.
ctx.addPath(trail)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.96))
ctx.setLineWidth(s * 0.042)
ctx.strokePath()

// Arrowhead along the final tangent (from c2 to tip).
let angle = atan2(tip.y - c2.y, tip.x - c2.x)
let len = s * 0.17
let half = s * 0.11
func rot(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: tip.x + x * cos(angle) - y * sin(angle), y: tip.y + x * sin(angle) + y * cos(angle))
}
let head = CGMutablePath()
head.move(to: rot(len * 0.55, 0))
head.addLine(to: rot(-len * 0.45, half))
head.addLine(to: rot(-len * 0.22, 0))
head.addLine(to: rot(-len * 0.45, -half))
head.closeSubpath()
ctx.addPath(head)
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillPath()

// Start dot.
ctx.setFillColor(rgb(0xFFFFFF, 0.9))
ctx.fillEllipse(in: CGRect(x: p0.x - s * 0.035, y: p0.y - s * 0.035, width: s * 0.07, height: s * 0.07))

guard let image = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: out)
print("ok: icon written to \(out.path)")
