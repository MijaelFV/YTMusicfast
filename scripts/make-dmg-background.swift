import AppKit

// Draws the DMG window's background: light (Finder shows icon names in black over a custom
// background, whatever the appearance), with an arrow from the app to Applications.
//
//   swift scripts/make-dmg-background.swift scripts/dmg
//
// Writes background.png (660×400) and background@2x.png; release.sh combines them into one TIFF.
// The icon positions here must match scripts/dmg/settings.py.

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let W: CGFloat = 660, H: CGFloat = 400
let appX: CGFloat = 165, applicationsX: CGFloat = 495, iconY: CGFloat = 185   // icon centres, from the top

func render(scale: CGFloat, to name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    NSColor(srgbRed: 0.965, green: 0.965, blue: 0.97, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: W, height: H).fill()
    // A faint glow of the app's red behind the app icon.
    let glow = NSGradient(colors: [NSColor(srgbRed: 0.94, green: 0.20, blue: 0.18, alpha: 0.10), .clear])!
    glow.draw(fromCenter: NSPoint(x: appX, y: H - iconY), radius: 0,
              toCenter: NSPoint(x: appX, y: H - iconY), radius: 170, options: [])

    // The arrow, between the two icons.
    let red = NSColor(srgbRed: 0.90, green: 0.20, blue: 0.18, alpha: 1)
    let y = H - iconY
    let start = appX + 95, end = applicationsX - 95
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: start, y: y))
    shaft.line(to: NSPoint(x: end - 4, y: y))
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    red.setStroke()
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end - 16, y: y + 13))
    head.line(to: NSPoint(x: end, y: y))
    head.line(to: NSPoint(x: end - 16, y: y - 13))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // The instruction, under the icons and their names.
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let text = NSAttributedString(string: "Drag YT Musicfast into Applications to install it", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.43, green: 0.43, blue: 0.45, alpha: 1),
        .paragraphStyle: style,
    ])
    text.draw(in: NSRect(x: 0, y: 62, width: W, height: 24))

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
render(scale: 1, to: "background.png")
render(scale: 2, to: "background@2x.png")
print("wrote", out.path)
