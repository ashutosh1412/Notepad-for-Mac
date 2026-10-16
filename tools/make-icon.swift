// Draws the app icon (1024x1024 PNG): a notepad page with syntax-colored code
// lines and a "++" badge, on a macOS-style rounded square.
// Usage: swift tools/make-icon.swift AppIcon.png
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
  // Base: Apple's icon grid uses an 824pt rounded square centered in 1024.
  let base = NSRect(x: 100, y: 100, width: 824, height: 824)
  let baseShape = NSBezierPath(roundedRect: base, xRadius: 185, yRadius: 185)
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = color(0x000000, 0.28)
  shadow.shadowBlurRadius = 28
  shadow.shadowOffset = NSSize(width: 0, height: -12)
  shadow.set()
  color(0x2E8B57).setFill()
  baseShape.fill()
  NSGraphicsContext.restoreGraphicsState()
  NSGradient(colors: [color(0x6BD36A), color(0x2F9E5B), color(0x1E7A4C)],
             atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: baseShape, angle: 90)
  // Soft highlight across the top.
  NSGradient(colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)])!
    .draw(in: NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 380), xRadius: 185, yRadius: 185), angle: 90)

  // Page with a folded top-right corner.
  let page = NSRect(x: 262, y: 196, width: 470, height: 610)
  let fold: CGFloat = 112
  let pagePath = NSBezierPath()
  pagePath.move(to: NSPoint(x: page.minX + 34, y: page.minY))
  pagePath.line(to: NSPoint(x: page.maxX - fold, y: page.minY))
  pagePath.line(to: NSPoint(x: page.maxX, y: page.minY + fold))
  pagePath.line(to: NSPoint(x: page.maxX, y: page.maxY - 34))
  pagePath.curve(to: NSPoint(x: page.maxX - 34, y: page.maxY), controlPoint1: NSPoint(x: page.maxX, y: page.maxY - 15),
                 controlPoint2: NSPoint(x: page.maxX - 15, y: page.maxY))
  pagePath.line(to: NSPoint(x: page.minX + 34, y: page.maxY))
  pagePath.curve(to: NSPoint(x: page.minX, y: page.maxY - 34), controlPoint1: NSPoint(x: page.minX + 15, y: page.maxY),
                 controlPoint2: NSPoint(x: page.minX, y: page.maxY - 15))
  pagePath.line(to: NSPoint(x: page.minX, y: page.minY + 34))
  pagePath.curve(to: NSPoint(x: page.minX + 34, y: page.minY), controlPoint1: NSPoint(x: page.minX, y: page.minY + 15),
                 controlPoint2: NSPoint(x: page.minX + 15, y: page.minY))
  pagePath.close()
  NSGraphicsContext.saveGraphicsState()
  let pageShadow = NSShadow()
  pageShadow.shadowColor = color(0x0B3D24, 0.35)
  pageShadow.shadowBlurRadius = 22
  pageShadow.shadowOffset = NSSize(width: 0, height: -10)
  pageShadow.set()
  color(0xFFFFFF).setFill()
  pagePath.fill()
  NSGraphicsContext.restoreGraphicsState()
  NSGradient(colors: [color(0xFFFFFF), color(0xEEF3F0)])!.draw(in: pagePath, angle: 90)

  let foldPath = NSBezierPath()
  foldPath.move(to: NSPoint(x: page.maxX - fold, y: page.minY))
  foldPath.line(to: NSPoint(x: page.maxX - fold, y: page.minY + fold - 18))
  foldPath.curve(to: NSPoint(x: page.maxX - fold + 18, y: page.minY + fold),
                 controlPoint1: NSPoint(x: page.maxX - fold, y: page.minY + fold - 6),
                 controlPoint2: NSPoint(x: page.maxX - fold + 6, y: page.minY + fold))
  foldPath.line(to: NSPoint(x: page.maxX, y: page.minY + fold))
  foldPath.close()
  color(0xC9D6CE).setFill()
  foldPath.fill()

  // Gutter with line numbers and syntax-colored "code".
  color(0xE4ECE7).setFill()
  NSBezierPath(rect: NSRect(x: page.minX + 26, y: page.minY + 150, width: 46, height: 410)).fill()
  let keyword = color(0x2F6FD0), string = color(0xE8862A), comment = color(0x3C9E4E), plain = color(0x5B6670), purple = color(0x8A4FD0)
  let lines: [[(CGFloat, NSColor)]] = [
    [(80, keyword), (150, plain)],
    [(40, plain), (90, purple), (110, string)],
    [(40, plain), (70, keyword), (130, plain)],
    [(40, plain), (40, plain), (160, string)],
    [(40, plain), (100, plain)],
    [(220, comment)],
    [(80, keyword), (60, plain), (90, purple)],
    [(40, plain), (180, plain)],
  ]
  for (index, segments) in lines.enumerated() {
    let y = page.minY + 168 + CGFloat(index) * 50
    color(0x9AA8A0).setFill()
    NSBezierPath(roundedRect: NSRect(x: page.minX + 36, y: y, width: 26, height: 18), xRadius: 6, yRadius: 6).fill()
    var x = page.minX + 96
    for (width, segmentColor) in segments {
      segmentColor.setFill()
      NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: 20), xRadius: 10, yRadius: 10).fill()
      x += width + 16
    }
  }

  // "++" badge in Notepad++'s active-tab orange.
  let badge = NSRect(x: 600, y: 620, width: 250, height: 250)
  NSGraphicsContext.saveGraphicsState()
  let badgeShadow = NSShadow()
  badgeShadow.shadowColor = color(0x000000, 0.3)
  badgeShadow.shadowBlurRadius = 20
  badgeShadow.shadowOffset = NSSize(width: 0, height: -8)
  badgeShadow.set()
  color(0xF39A2B).setFill()
  NSBezierPath(ovalIn: badge).fill()
  NSGraphicsContext.restoreGraphicsState()
  NSGradient(colors: [color(0xFFC062), color(0xF08C1C)])!.draw(in: NSBezierPath(ovalIn: badge), angle: 90)
  color(0xFFFFFF).setStroke()
  let ring = NSBezierPath(ovalIn: badge.insetBy(dx: 9, dy: 9))
  ring.lineWidth = 12
  ring.stroke()
  // Two plus signs drawn as bars, so they stay crisp at every size.
  color(0xFFFFFF).setFill()
  for centerX in [badge.midX - 50, badge.midX + 50] {
    NSBezierPath(roundedRect: NSRect(x: centerX - 38, y: badge.midY - 12, width: 76, height: 24), xRadius: 12, yRadius: 12).fill()
    NSBezierPath(roundedRect: NSRect(x: centerX - 12, y: badge.midY - 38, width: 24, height: 76), xRadius: 12, yRadius: 12).fill()
  }
  return true
}

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
  fatalError("Could not render icon")
}
try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
