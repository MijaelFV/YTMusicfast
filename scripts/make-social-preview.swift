// Draws docs/social-preview.png, the 1280×640 card GitHub and X show for links to the repository
// (upload it in the repository's Settings → Social preview).
//
//   swift scripts/make-social-preview.swift . docs/social-preview.png

import AppKit

let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])
let W: CGFloat = 1280, H: CGFloat = 640

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background: near-black with a soft red glow behind the text.
NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()
let glow = NSGradient(colors: [NSColor(srgbRed: 0.94, green: 0.18, blue: 0.20, alpha: 0.30), .clear])!
glow.draw(fromCenter: NSPoint(x: 230, y: 420), radius: 0, toCenter: NSPoint(x: 230, y: 420), radius: 520, options: [])

// Screenshot on the right, running off the edge.
let shot = NSImage(contentsOf: root.appendingPathComponent("docs/screenshots/main-window.jpg"))!
let shotW: CGFloat = 800
let shotH = shotW * shot.size.height / shot.size.width
let shotRect = NSRect(x: 600, y: (H - shotH) / 2, width: shotW, height: shotH)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: NSColor.black.withAlphaComponent(0.7).cgColor)
NSColor.black.setFill()
NSBezierPath(roundedRect: shotRect, xRadius: 14, yRadius: 14).fill()
ctx.restoreGState()
ctx.saveGState()
NSBezierPath(roundedRect: shotRect, xRadius: 14, yRadius: 14).addClip()
shot.draw(in: shotRect)
ctx.restoreGState()
NSColor.white.withAlphaComponent(0.12).setStroke()
let border = NSBezierPath(roundedRect: shotRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
border.lineWidth = 1
border.stroke()

// Left column: icon, name, tagline, facts.
let icon = NSImage(contentsOf: root.appendingPathComponent("YTMusicfast/Resources/Assets.xcassets/AppIcon.appiconset/icon_256@2x.png"))!
icon.draw(in: NSRect(x: 72, y: 404, width: 132, height: 132))

func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, at p: NSPoint, kern: CGFloat = 0) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color, .kern: kern]
    NSAttributedString(string: s, attributes: attrs).draw(at: p)
}
text("YT Musicfast", 60, .bold, .white, at: NSPoint(x: 72, y: 318), kern: -1)
text("A fast, native Mac app", 30, .medium, NSColor(white: 0.85, alpha: 1), at: NSPoint(x: 74, y: 268))
text("for YouTube Music.", 30, .medium, NSColor(white: 0.85, alpha: 1), at: NSPoint(x: 74, y: 230))

let facts = ["8 MB download", "~150 MB of RAM", "0% CPU when idle"]
var y: CGFloat = 166
for f in facts {
    NSColor(srgbRed: 0.94, green: 0.32, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 76, y: y + 9, width: 8, height: 8)).fill()
    text(f, 22, .regular, NSColor(white: 0.70, alpha: 1), at: NSPoint(x: 96, y: y))
    y -= 34
}
text("Free and open source · macOS 15+", 18, .medium, NSColor(white: 0.50, alpha: 1), at: NSPoint(x: 74, y: 40))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote", out.path)
