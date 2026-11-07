// Owner: QA track. Draws Bubble's app icon (a white bubble with a red record dot on a blue squircle)
// and writes the PNG set iconutil wants. Usage: swift scripts/make-icon.swift <out.iconset>
// scripts/make-icon.sh turns it into Resources/AppIcon.icns. No Xcode needed.
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Squircle-ish background with the macOS icon grid margin (~10%).
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.addPath(bg); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(srgbRed: 0.33, green: 0.47, blue: 1.0, alpha: 1), CGColor(srgbRed: 0.16, green: 0.24, blue: 0.75, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()
    // The bubble: a white ring with a soft shadow.
    let r = rect.width * 0.30
    let c = CGPoint(x: rect.midX - rect.width * 0.06, y: rect.midY - rect.width * 0.04)
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.89, blue: 1.0, alpha: 1))
    let ri = r * 0.86
    ctx.fillEllipse(in: CGRect(x: c.x - ri, y: c.y - ri, width: 2 * ri, height: 2 * ri))
    // The record dot, top-right of the bubble.
    let d = rect.width * 0.11
    let dc = CGPoint(x: c.x + r * 0.95, y: c.y + r * 0.95)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: dc.x - d * 1.25, y: dc.y - d * 1.25, width: d * 2.5, height: d * 2.5))
    ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.23, blue: 0.2, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: dc.x - d, y: dc.y - d, width: d * 2, height: d * 2))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print(out.path)
