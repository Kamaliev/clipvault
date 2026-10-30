// Draws the app icon and writes app/Resources/AppIcon.icns.
//   swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("app/Resources/AppIcon.icns")

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// Draws on a 1024-point canvas (origin bottom-left) scaled to `size` pixels.
func render(_ size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    // macOS icon grid: 824 pt tile, 100 pt margin, ~185 pt corner radius.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x1E2A78))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    linear(ctx, [rgb(0x5B6CFF), rgb(0x2A1C8F)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    // Soft top highlight, like light on glass.
    linear(ctx, [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 600))
    ctx.restoreGState()

    // Clipboard board.
    let board = CGRect(x: 292, y: 210, width: 440, height: 560)
    let boardPath = CGPath(roundedRect: board, cornerWidth: 64, cornerHeight: 64, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x0B0640, 0.45))
    ctx.addPath(boardPath)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(boardPath)
    ctx.clip()
    linear(ctx, [rgb(0xFFFFFF), rgb(0xE4E8FF)], from: CGPoint(x: 512, y: 770), to: CGPoint(x: 512, y: 210))
    ctx.restoreGState()

    // Clip at the top.
    let clip = CGRect(x: 402, y: 718, width: 220, height: 108)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: rgb(0x0B0640, 0.35))
    ctx.addPath(CGPath(roundedRect: clip, cornerWidth: 40, cornerHeight: 40, transform: nil))
    ctx.setFillColor(rgb(0x2B2F45))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 472, y: 778, width: 80, height: 24),
                       cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.setFillColor(rgb(0x5B6CFF))
    ctx.fillPath()

    // Text lines.
    ctx.setFillColor(rgb(0xB8C0EE))
    for (y, width) in [(640.0, 300.0), (586.0, 240.0)] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: 362, y: y, width: width, height: 26),
                           cornerWidth: 13, cornerHeight: 13, transform: nil))
        ctx.fillPath()
    }

    // Padlock: the history is encrypted.
    let shackle = CGMutablePath()
    shackle.addArc(center: CGPoint(x: 512, y: 432), radius: 58, startAngle: 0, endAngle: .pi, clockwise: false)
    shackle.move(to: CGPoint(x: 454, y: 432))
    shackle.addLine(to: CGPoint(x: 454, y: 392))
    shackle.move(to: CGPoint(x: 570, y: 432))
    shackle.addLine(to: CGPoint(x: 570, y: 392))
    ctx.addPath(shackle)
    ctx.setStrokeColor(rgb(0x2B2F45))
    ctx.setLineWidth(30)
    ctx.setLineCap(.round)
    ctx.strokePath()

    let body = CGRect(x: 412, y: 268, width: 200, height: 150)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 34, cornerHeight: 34, transform: nil))
    ctx.clip()
    linear(ctx, [rgb(0x6F7CFF), rgb(0x3A2BB5)], from: CGPoint(x: 512, y: 418), to: CGPoint(x: 512, y: 268))
    ctx.restoreGState()

    // Keyhole.
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillEllipse(in: CGRect(x: 491, y: 342, width: 42, height: 42))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 501, y: 300, width: 22, height: 56),
                       cornerWidth: 11, cornerHeight: 11, transform: nil))
    ctx.fillPath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { exit(1) }
print("wrote \(output.path)")
