// Draws the JTag Provenance Studio icon (1024x1024 PNG): a white tag marked "J" on a navy-to-teal
// squircle, with a green check seal. build.sh turns it into AppIcon.icns.
//   swift make_icon.swift icon_1024.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Background squircle on Apple's icon grid (824pt body, drop shadow).
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35).cgColor)
color(0x1B2A6B).setFill()
squircle.fill()
ctx.restoreGState()
NSGradient(colors: [color(0x1B2A6B), color(0x1F5F9E), color(0x15A7A3)])!.draw(in: squircle, angle: 50)

// The tag, tilted: a rounded body with a pointed left end and a punched hole.
ctx.saveGState()
ctx.translateBy(x: 512, y: 520)
ctx.rotate(by: 20 * .pi / 180)
let w: CGFloat = 520, h: CGFloat = 300, point: CGFloat = 130
let tag = NSBezierPath()
tag.move(to: NSPoint(x: -w / 2, y: 0))
tag.line(to: NSPoint(x: -w / 2 + point, y: h / 2))
tag.appendArc(withCenter: NSPoint(x: w / 2 - 40, y: h / 2 - 40), radius: 40, startAngle: 90, endAngle: 0, clockwise: true)
tag.appendArc(withCenter: NSPoint(x: w / 2 - 40, y: -h / 2 + 40), radius: 40, startAngle: 0, endAngle: -90, clockwise: true)
tag.line(to: NSPoint(x: -w / 2 + point, y: -h / 2))
tag.close()
tag.lineJoinStyle = .round
tag.append(NSBezierPath(ovalIn: NSRect(x: -w / 2 + 62, y: -24, width: 48, height: 48)))
tag.windingRule = .evenOdd
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.30).cgColor)
NSColor.white.setFill()
tag.fill()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// "J" on the tag.
let font = NSFont.systemFont(ofSize: 250, weight: .black)
let letter = NSAttributedString(string: "J", attributes: [.font: font, .foregroundColor: color(0x1B2A6B)])
let ls = letter.size()
letter.draw(at: NSPoint(x: 60 - ls.width / 2, y: -ls.height / 2 + 8))
ctx.restoreGState()

// Check seal, bottom right.
let sealRect = NSRect(x: 640, y: 160, width: 230, height: 230)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0x000000, 0.35).cgColor)
color(0x22C55E).setFill()
NSBezierPath(ovalIn: sealRect).fill()
ctx.restoreGState()
NSColor.white.setStroke()
let ring = NSBezierPath(ovalIn: sealRect.insetBy(dx: 10, dy: 10))
ring.lineWidth = 12
ring.stroke()
let check = NSBezierPath()
check.move(to: NSPoint(x: sealRect.minX + 62, y: sealRect.midY + 2))
check.line(to: NSPoint(x: sealRect.minX + 100, y: sealRect.midY - 38))
check.line(to: NSPoint(x: sealRect.maxX - 56, y: sealRect.midY + 44))
check.lineWidth = 26
check.lineCapStyle = .round
check.lineJoinStyle = .round
check.stroke()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
